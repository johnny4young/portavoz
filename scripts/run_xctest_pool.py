#!/usr/bin/env python3
"""Run every listed XCTest class in a bounded pool of xctest processes.

Classes share a process in batches balanced by duration, which avoids one launch
per class. Each class still accounts for itself: its suite must finish with
exactly its listed cases. A crash or hang fails the class that was running, and
the classes it never reached continue in a new process.
"""

from __future__ import annotations

import argparse
import collections
import concurrent.futures
from dataclasses import dataclass
import json
import random
import re
import subprocess
import sys
import threading
import time
from pathlib import Path
from typing import Iterable, Sequence

SUITE = re.compile(r"Test Suite '([^']+)' (started|passed|failed) at ")
EXECUTED = re.compile(
    r"Executed (\d+) tests?, with (?:(\d+) tests? skipped and )?(\d+) failures? \((\d+) unexpected\)"
    r"(?: in [\d.]+ \(([\d.]+)\) seconds)?"
)
DURATIONS = Path(__file__).with_name("xctest_class_seconds.json")
NIGHTLY_ONLY = Path(__file__).with_name("xctest_nightly_only.txt")
TARGET_BATCH_SECONDS = 15.0
# Classes under the table's one-second floor average this per case on the hosted runner.
ESTIMATED_CASE_SECONDS = 0.02
CLASS_TIMEOUT_SECONDS = 300.0
TERMINATION_GRACE_SECONDS = 5.0


@dataclass
class ClassResult:
    executed: int = 0
    skipped: int = 0
    failure: str | None = None


def xctest_cases(listing: str, deferred: frozenset[str] = frozenset()) -> list[str]:
    # Swift Testing identifiers end in an argument list; XCTest methods never do.
    names = (line.strip() for line in listing.splitlines())
    return [name for name in names if name and "(" not in name and name.split(".", 1)[-1] not in deferred]


def class_counts(cases: Iterable[str]) -> collections.Counter[str]:
    return collections.Counter(case.split("/", 1)[0] for case in cases)


def selectors(listed: Sequence[str], kept: Sequence[str]) -> dict[str, str]:
    """How xctest selects each class: whole, or by case when some cases are deferred."""
    whole, running = class_counts(listed), class_counts(kept)
    return {name: name if count == whole[name] else ",".join(case for case in kept if case.startswith(f"{name}/"))
            for name, count in running.items()}


def nightly_only(path: Path) -> frozenset[str]:
    lines = (line.strip() for line in path.read_text(encoding="utf-8").splitlines())
    return frozenset(line for line in lines if line and not line.startswith("#"))


def bundle_for(name: str, products: Path) -> Path | None:
    """SwiftBuild gives each test target its own bundle; the native build system joins them in one."""
    own = products / f"{name.split('.', 1)[0]}.xctest"
    if own.is_dir():
        return own
    joined = sorted(products.glob("*PackageTests.xctest"))
    return joined[0] if len(joined) == 1 else None


def bare(name: str) -> str:
    # xctest names a class's suite without its module.
    return name.rsplit(".", 1)[-1]


def estimated_seconds(classes: collections.Counter[str], whole: collections.Counter[str],
                      recorded: dict[str, float]) -> dict[str, float]:
    # A recorded duration covers the whole class, so it says nothing once cases are deferred.
    return {name: recorded[bare(name)] if bare(name) in recorded and cases == whole[name]
            else cases * ESTIMATED_CASE_SECONDS
            for name, cases in classes.items()}


def partition(seconds: dict[str, float], target: float = TARGET_BATCH_SECONDS,
              seed: str | None = None) -> list[list[str]]:
    """First-fit decreasing, longest batch first. A seed varies which classes share a process."""
    order = sorted(seconds, key=lambda name: (-seconds[name], name))
    if seed is not None:
        random.Random(seed).shuffle(order)
    batches: list[list[str]] = []
    loads: list[float] = []
    for name in order:
        index = next((i for i, load in enumerate(loads) if load + seconds[name] <= target), None)
        if index is None:
            batches.append([])
            loads.append(0.0)
            index = len(batches) - 1
        batches[index].append(name)
        loads[index] += seconds[name]
    ranked = sorted(range(len(batches)), key=lambda i: -loads[i])
    return [batches[i] for i in ranked]


class SuiteTracker:
    """Follows one xctest process's output and records each class's own suite."""

    def __init__(self, names: Iterable[str]):
        self.by_suite = {bare(name): name for name in names}
        self.finished: dict[str, tuple[bool, tuple[int, int, int] | None]] = {}
        self.started: set[str] = set()
        self.last_finished: str | None = None
        self.last_boundary = time.monotonic()
        self.awaiting_summary: str | None = None
        self.lock = threading.Lock()

    def feed(self, line: str) -> None:
        with self.lock:
            suite = SUITE.search(line)
            if suite:
                self.awaiting_summary = None
                name = self.by_suite.get(suite.group(1))
                if name is None:
                    return
                self.last_boundary = time.monotonic()
                if suite.group(2) == "started":
                    self.started.add(name)
                    return
                self.finished[name] = (suite.group(2) == "passed", None)
                self.last_finished = name
                self.awaiting_summary = name
                return
            counts = EXECUTED.search(line)
            if counts and self.awaiting_summary:
                name = self.awaiting_summary
                failures = int(counts.group(3)) + int(counts.group(4))
                self.finished[name] = (self.finished[name][0],
                                       (int(counts.group(1)), int(counts.group(2) or 0), failures))
                self.awaiting_summary = None

    def timed_out(self, limit: float) -> bool:
        with self.lock:
            return time.monotonic() - self.last_boundary > limit


def run_process(bundle: Path, names: Sequence[str], selected: dict[str, str],
                timeout: float) -> tuple[SuiteTracker, int, bool, str]:
    tracker = SuiteTracker(names)
    transcript: list[str] = []
    process = subprocess.Popen(
        ["xcrun", "xctest", "-XCTest", ",".join(selected[name] for name in names), str(bundle)],
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, errors="replace")

    def read() -> None:
        assert process.stdout is not None
        for line in process.stdout:
            transcript.append(line)
            tracker.feed(line)

    reader = threading.Thread(target=read, daemon=True)
    reader.start()
    hung = False
    while True:
        try:
            status = process.wait(timeout=0.2)
            break
        except subprocess.TimeoutExpired:
            if tracker.timed_out(timeout):
                hung = True
                process.terminate()
                try:
                    status = process.wait(timeout=TERMINATION_GRACE_SECONDS)
                except subprocess.TimeoutExpired:
                    process.kill()
                    status = process.wait()
                break
    # A helper a test left running can hold the pipe open; never wait on it for long.
    reader.join(TERMINATION_GRACE_SECONDS)
    return tracker, status, hung, "".join(transcript)


def run_batch(bundle: Path, names: Sequence[str], listed: collections.Counter[str], selected: dict[str, str],
              timeout: float) -> tuple[dict[str, ClassResult], str]:
    results: dict[str, ClassResult] = {}
    transcripts: list[str] = []
    pending = list(names)
    while pending:
        tracker, status, hung, transcript = run_process(bundle, pending, selected, timeout)
        transcripts.append(transcript)
        cause = f"no summary after {timeout:.0f} s" if hung else f"no summary, exit {status}"
        if not tracker.started:
            results.update({name: ClassResult(failure=f"never started, {cause}") for name in pending})
            break
        attributed = False
        for name in pending:
            if name not in tracker.started:
                continue
            passed, counts = tracker.finished.get(name, (False, None))
            if counts is None:
                results[name] = ClassResult(failure=cause)
                attributed = True
                continue
            result = results[name] = ClassResult(executed=counts[0], skipped=counts[1])
            if counts[2] or not passed:
                result.failure = f"{counts[2]} failures"
                attributed = True
            elif counts[0] != listed[name]:
                result.failure = f"executed {counts[0]} of {listed[name]} listed cases"
                attributed = True
        # A process that failed after its suites finished still fails; the last class ran closest to it.
        if status != 0 and not attributed and tracker.last_finished in results:
            results[tracker.last_finished].failure = f"process exited {status} after this suite"
        pending = [name for name in pending if name not in tracker.started]
    return results, "".join(transcripts)


def plan_batches(seconds: dict[str, float], products: Path, seed: str | None) -> list[tuple[Path, list[str]]] | None:
    """Batches for each bundle, longest first across all of them. None when a class has no bundle."""
    by_bundle: dict[Path, dict[str, float]] = collections.defaultdict(dict)
    for name, estimate in seconds.items():
        bundle = bundle_for(name, products)
        if bundle is None:
            print(f"No XCTest bundle for {name} in {products}", file=sys.stderr)
            return None
        by_bundle[bundle][name] = estimate
    batches = [(bundle, batch) for bundle, group in by_bundle.items() for batch in partition(group, seed=seed)]
    return sorted(batches, key=lambda item: -sum(seconds[name] for name in item[1]))


def recorded_seconds(log: str) -> dict[str, float]:
    """Each class's duration from an xctest log, at the table's one-second floor."""
    seconds: dict[str, float] = {}
    suite: str | None = None
    for line in log.splitlines():
        match = SUITE.search(line)
        if match:
            suite = match.group(1) if match.group(2) != "started" else None
            continue
        counts = EXECUTED.search(line)
        if counts and suite and counts.group(5):
            if not suite.endswith(".xctest") and suite != "Selected tests" and float(counts.group(5)) >= 1:
                seconds[suite] = round(float(counts.group(5)), 1)
            suite = None
    return dict(sorted(seconds.items()))


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--products", type=Path, help="the build's products directory")
    parser.add_argument("--listing", type=Path)
    parser.add_argument("--workers", type=int)
    parser.add_argument("--durations", type=Path, default=DURATIONS)
    parser.add_argument("--nightly-only", type=Path, default=NIGHTLY_ONLY)
    parser.add_argument("--include-nightly-only", action="store_true")
    parser.add_argument("--class-timeout", type=float, default=CLASS_TIMEOUT_SECONDS)
    parser.add_argument("--batch-seed", default=None, help="vary which classes share a process")
    parser.add_argument("--record-from", type=Path, help="print the duration table from an xctest log and exit")
    arguments = parser.parse_args(argv)
    if arguments.record_from:
        log = arguments.record_from.read_text(encoding="utf-8", errors="replace")
        print(json.dumps(recorded_seconds(log), indent=2))
        return 0
    if not arguments.products or not arguments.listing or not arguments.workers:
        parser.error("--products, --listing and --workers are required")
    listing = arguments.listing.read_text(encoding="utf-8")
    deferred = frozenset() if arguments.include_nightly_only else nightly_only(arguments.nightly_only)
    listed, kept = xctest_cases(listing), xctest_cases(listing, deferred)
    classes = class_counts(kept)
    if not classes:
        print("No XCTest classes were listed.", file=sys.stderr)
        return 2
    ambiguous = [name for name, count in collections.Counter(map(bare, classes)).items() if count > 1]
    if ambiguous:
        print(f"XCTest suites cannot be told apart across modules: {sorted(ambiguous)}", file=sys.stderr)
        return 2
    recorded = json.loads(arguments.durations.read_text(encoding="utf-8")) if arguments.durations.is_file() else {}
    seconds = estimated_seconds(classes, class_counts(listed), recorded)
    batches = plan_batches(seconds, arguments.products, arguments.batch_seed)
    if batches is None:
        return 2
    selected = selectors(listed, kept)
    expected = sum(classes.values())
    results: dict[str, ClassResult] = {}
    with concurrent.futures.ThreadPoolExecutor(arguments.workers) as pool:
        futures = [pool.submit(run_batch, bundle, batch, classes, selected, arguments.class_timeout)
                   for bundle, batch in batches]
        for future in concurrent.futures.as_completed(futures):
            finished, output = future.result()
            print(output, end="" if output.endswith("\n") or not output else "\n", flush=True)
            results.update(finished)
    executed = sum(result.executed for result in results.values())
    skipped = sum(result.skipped for result in results.values())
    failed = sorted(name for name, result in results.items() if result.failure)
    seed = f", seed {arguments.batch_seed}" if arguments.batch_seed is not None else ""
    print(f"XCTest batches: {len(batches)}{seed}; deferred to the nightly run: {len(listed) - len(kept)} cases")
    print(f"XCTest classes: {len(classes)}; cases: {executed} of {expected} listed "
          f"({skipped} skipped); failed classes: {len(failed)}")
    for name in failed:
        print(f"FAILED XCTest class: {name} ({results[name].failure})")
    if executed != expected:
        print(f"XCTest executed {executed} cases but {expected} were listed.", file=sys.stderr)
        return 1
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
