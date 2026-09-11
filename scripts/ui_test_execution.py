#!/usr/bin/env python3
"""Write a content-free classification of one hosted XCUITest invocation."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys
import tempfile
from pathlib import Path
from typing import Any, Sequence


SCHEMA_VERSION = 1
SUPPORTED_LOCALES = frozenset({"default", "en", "es"})
MAXIMUM_LOG_BYTES = 64 * 1024 * 1024
HOST_INFRASTRUCTURE_SIGNATURES = {
    "automation-mode-timeout": b"Timed out while enabling automation mode",
}


class ExecutionError(ValueError):
    """The invocation evidence cannot be classified safely."""


def exact_integer(value: str, label: str, *, minimum: int, maximum: int) -> int:
    try:
        parsed = int(value)
    except ValueError as error:
        raise ExecutionError(f"{label} must be an integer") from error
    if parsed < minimum or parsed > maximum:
        raise ExecutionError(f"{label} must be within {minimum}...{maximum}")
    return parsed


def runtime_case_count(path: Path) -> int | None:
    if not path.is_file():
        return None
    try:
        document = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError):
        return None
    if not isinstance(document, dict):
        return None
    count = document.get("caseCount")
    cases = document.get("tests")
    if (
        isinstance(count, bool)
        or not isinstance(count, int)
        or count < 0
        or not isinstance(cases, list)
        or len(cases) != count
    ):
        return None
    return count


def read_log(path: Path) -> bytes:
    try:
        size = path.stat().st_size
    except OSError as error:
        raise ExecutionError("XCUITest log is unreadable") from error
    if size > MAXIMUM_LOG_BYTES:
        raise ExecutionError("XCUITest log exceeds the size limit")
    try:
        return path.read_bytes()
    except OSError as error:
        raise ExecutionError("XCUITest log is unreadable") from error


def classify(
    *,
    exit_status: int,
    result_bundle_present: bool,
    runtime_receipt_present: bool,
    runtime_cases: int | None,
    log: bytes,
) -> tuple[str, str | None]:
    if exit_status == 0:
        if result_bundle_present and runtime_receipt_present and runtime_cases is not None:
            return "completed", None
        return "evidence-failure", None
    if runtime_cases is not None and runtime_cases > 0:
        return "test-failure", None
    matching = [
        code
        for code, signature in HOST_INFRASTRUCTURE_SIGNATURES.items()
        if signature in log
    ]
    if len(matching) == 1:
        return "known-host-infrastructure", matching[0]
    return "unclassified-failure", None


def write_new_atomic(path: Path, document: dict[str, Any]) -> None:
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    payload = json.dumps(
        document,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8") + b"\n"
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{path.name}.",
        dir=path.parent,
    )
    temporary = Path(temporary_name)
    try:
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, "wb") as output:
            output.write(payload)
            output.flush()
            os.fsync(output.fileno())
        if path.exists():
            raise ExecutionError("execution receipt already exists")
        os.link(temporary, path)
        os.chmod(path, 0o600)
    finally:
        temporary.unlink(missing_ok=True)


def parser() -> argparse.ArgumentParser:
    value = argparse.ArgumentParser(description=__doc__)
    value.add_argument("--locale", required=True)
    value.add_argument("--selector-count", required=True)
    value.add_argument("--exit-status", required=True)
    value.add_argument("--log", type=Path, required=True)
    value.add_argument("--result", type=Path, required=True)
    value.add_argument("--runtime-receipt", type=Path, required=True)
    value.add_argument("--output", type=Path, required=True)
    return value


def main(argv: Sequence[str] | None = None) -> int:
    arguments = parser().parse_args(argv)
    if arguments.locale not in SUPPORTED_LOCALES:
        print("unsupported XCUITest locale", file=sys.stderr)
        return 2
    try:
        selector_count = exact_integer(
            arguments.selector_count,
            "selector count",
            minimum=0,
            maximum=10_000,
        )
        exit_status = exact_integer(
            arguments.exit_status,
            "exit status",
            minimum=0,
            maximum=255,
        )
        log = read_log(arguments.log)
        result_present = arguments.result.is_dir()
        runtime_present = arguments.runtime_receipt.is_file()
        cases = runtime_case_count(arguments.runtime_receipt)
        classification, signature = classify(
            exit_status=exit_status,
            result_bundle_present=result_present,
            runtime_receipt_present=runtime_present,
            runtime_cases=cases,
            log=log,
        )
        document = {
            "classification": classification,
            "failureSignature": signature,
            "locale": arguments.locale,
            "logSHA256": hashlib.sha256(log).hexdigest(),
            "resultBundlePresent": result_present,
            "runtimeReceiptPresent": runtime_present,
            "schemaVersion": SCHEMA_VERSION,
            "selectorCount": selector_count,
            "xcodebuildExitStatus": exit_status,
        }
        write_new_atomic(arguments.output, document)
    except ExecutionError as error:
        print(f"UI execution classification failed: {error}", file=sys.stderr)
        return 2
    print(
        f"XCUITest execution: {arguments.locale} {classification} "
        f"(exit {exit_status})."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
