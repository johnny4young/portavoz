#!/usr/bin/env python3
"""Refuse to start macOS XCUITest while the shared host is contaminated.

The check is deliberately read-only. It samples process identity plus
CoreGraphics owner/layer metadata twice, never reads window titles or dialog
content, and never dismisses a prompt or terminates another process.
"""

from __future__ import annotations

import json
import re
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Protocol, TextIO


SETTLE_SECONDS = 1.0
PROCESS_PROBE_TIMEOUT_SECONDS = 3.0
WINDOW_PROBE_TIMEOUT_SECONDS = 10.0
WINDOW_INVENTORY_KEYS = frozenset({"notificationCenter", "securityAgent"})
WINDOW_PROBE = Path(__file__).with_name("ui-test-window-probe.swift")


class ProbeFailure(RuntimeError):
    """The host could not be classified without guessing."""


@dataclass(frozen=True)
class ProcessRecord:
    pid: int
    executable_name: str
    command: str


@dataclass(frozen=True)
class HostSnapshot:
    processes: tuple[ProcessRecord, ...] = ()
    notification_center_windows: int = 0
    security_agent_windows: int = 0


class HostProbe(Protocol):
    def snapshot(self) -> HostSnapshot: ...


@dataclass(frozen=True)
class HostBlockers:
    notification_center: bool
    security_agent: bool
    xcode_test_process_count: int
    ui_test_runner_count: int

    @property
    def is_empty(self) -> bool:
        return not any(
            (
                self.notification_center,
                self.security_agent,
                self.xcode_test_process_count,
                self.ui_test_runner_count,
            )
        )


class SystemHostProbe:
    def snapshot(self) -> HostSnapshot:
        return HostSnapshot(
            processes=self._processes(),
            **self._blocking_window_counts(),
        )

    @staticmethod
    def _processes() -> tuple[ProcessRecord, ...]:
        try:
            result = subprocess.run(
                ["/bin/ps", "-axo", "pid=,ucomm=,command="],
                check=False,
                capture_output=True,
                text=True,
                timeout=PROCESS_PROBE_TIMEOUT_SECONDS,
            )
        except (OSError, subprocess.TimeoutExpired, UnicodeError) as error:
            raise ProbeFailure("process inventory unavailable") from error
        if result.returncode != 0:
            raise ProbeFailure("process inventory unavailable")
        return parse_process_inventory(result.stdout)

    @staticmethod
    def _blocking_window_counts() -> dict[str, int]:
        try:
            result = subprocess.run(
                [
                    "/usr/bin/xcrun",
                    "swift",
                    "-warnings-as-errors",
                    str(WINDOW_PROBE),
                ],
                check=False,
                capture_output=True,
                text=True,
                timeout=WINDOW_PROBE_TIMEOUT_SECONDS,
            )
        except (OSError, subprocess.TimeoutExpired, UnicodeError) as error:
            raise ProbeFailure("blocking-window inventory unavailable") from error
        if result.returncode != 0:
            raise ProbeFailure("blocking-window inventory unavailable")
        try:
            notification_center, security_agent = parse_window_inventory(result.stdout)
        except (json.JSONDecodeError, TypeError, ValueError) as error:
            raise ProbeFailure("blocking-window inventory malformed") from error
        return {
            "notification_center_windows": notification_center,
            "security_agent_windows": security_agent,
        }


def parse_window_inventory(output: str) -> tuple[int, int]:
    payload = json.loads(output)
    if not isinstance(payload, dict) or set(payload) != WINDOW_INVENTORY_KEYS:
        raise TypeError("window inventory has an unexpected shape")
    return (
        exact_nonnegative_int(payload, "notificationCenter"),
        exact_nonnegative_int(payload, "securityAgent"),
    )


def exact_nonnegative_int(payload: object, key: str) -> int:
    if not isinstance(payload, dict):
        raise TypeError("window inventory must be an object")
    value = payload.get(key)
    if type(value) is not int or value < 0:
        raise ValueError(f"{key} must be a nonnegative integer")
    return value


def parse_process_inventory(output: str) -> tuple[ProcessRecord, ...]:
    records: list[ProcessRecord] = []
    for line in output.splitlines():
        fields = line.strip().split(maxsplit=2)
        if len(fields) != 3:
            continue
        try:
            pid = int(fields[0])
        except ValueError:
            continue
        if pid > 0 and fields[1] and fields[2]:
            records.append(
                ProcessRecord(
                    pid=pid,
                    executable_name=fields[1],
                    command=fields[2],
                )
            )
    return tuple(records)


_XCODE_TEST_ACTION = re.compile(
    r"(?:^|\s)(?:test|test-without-building)(?:\s|$)", re.IGNORECASE
)
_UI_TEST_RUNNER = re.compile(
    r"(?:^|[/\s])(?:[^/\s]*UITests-Runner|XCTRunner)(?:[/\s]|$)",
    re.IGNORECASE,
)
_XCTEST_UI_BUNDLE = re.compile(
    r"(?:^|[/\s])xctest(?:\s|$).*?(?:^|[/\s])[^/\s]*UITests\.xctest(?:[/\s]|$)",
    re.IGNORECASE,
)


def process_kind(process: ProcessRecord) -> str | None:
    executable_name = process.executable_name.casefold()
    command = process.command
    if executable_name == "xcodebuild" and _XCODE_TEST_ACTION.search(command):
        return "xcode-test"
    if (
        executable_name == "xctrunner"
        or "uitests" in executable_name
        or _UI_TEST_RUNNER.search(command)
        or (executable_name == "xctest" and _XCTEST_UI_BUNDLE.search(command))
    ):
        return "ui-test-runner"
    return None


def classify(snapshot: HostSnapshot) -> HostBlockers:
    kinds = tuple(
        kind
        for process in snapshot.processes
        if (kind := process_kind(process)) is not None
    )
    return HostBlockers(
        notification_center=snapshot.notification_center_windows > 0,
        security_agent=snapshot.security_agent_windows > 0,
        xcode_test_process_count=kinds.count("xcode-test"),
        ui_test_runner_count=kinds.count("ui-test-runner"),
    )


def explain(blockers: HostBlockers, output: TextIO) -> None:
    print("⛔️ XCUITest host is not idle.", file=output)
    if blockers.security_agent:
        print(
            "   A SecurityAgent authentication window is visible; resolve it manually.",
            file=output,
        )
    if blockers.notification_center:
        print(
            "   A Notification Center alert is visible; answer or dismiss it manually.",
            file=output,
        )
    if blockers.xcode_test_process_count:
        print(
            "   Another xcodebuild test command is active; let it finish first.",
            file=output,
        )
    if blockers.ui_test_runner_count:
        print(
            "   Another XCUITest runner is active; let it finish first.",
            file=output,
        )
    print("   No prompt was read or dismissed and no process was terminated.", file=output)


def run_preflight(
    probe: HostProbe,
    *,
    output: TextIO,
    sleeper: Callable[[float], None] = time.sleep,
) -> int:
    try:
        first = classify(probe.snapshot())
        if not first.is_empty:
            explain(first, output)
            return 1
        sleeper(SETTLE_SECONDS)
        second = classify(probe.snapshot())
    except ProbeFailure as error:
        print(f"⛔️ XCUITest host preflight failed: {error}.", file=output)
        print(
            "   No UI test was started; no prompt or process was changed.",
            file=output,
        )
        return 2
    if not second.is_empty:
        explain(second, output)
        return 1
    print(
        "UI-test host preflight passed: the host stayed clear for one second.",
        file=output,
    )
    return 0


def main() -> int:
    return run_preflight(SystemHostProbe(), output=sys.stdout)


if __name__ == "__main__":
    raise SystemExit(main())
