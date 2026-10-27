#!/usr/bin/env python3
"""Run every listed XCTest class in a bounded pool of xctest processes.

One process per class keeps each class's cases serial in one process, as the
serial runner did, while classes run side by side. The executed total must
equal the listed total, so a discovery or launch failure cannot pass quietly.
"""

from __future__ import annotations

import argparse
import collections
import concurrent.futures
import re
import subprocess
import sys
from pathlib import Path
from typing import Sequence

EXECUTED = re.compile(
    r"Executed (\d+) tests?, with (?:(\d+) tests? skipped and )?(\d+) failures? \((\d+) unexpected\)"
)


def xctest_classes(listing: str) -> collections.Counter[str]:
    # Swift Testing identifiers end in an argument list; XCTest methods never do.
    names = (line.strip() for line in listing.splitlines())
    return collections.Counter(name.split("/", 1)[0] for name in names if name and "(" not in name)


def summary(output: str) -> tuple[int, int, int] | None:
    # The last line is the selected-tests total for this invocation.
    matches = EXECUTED.findall(output)
    if not matches:
        return None
    executed, skipped, failures, unexpected = matches[-1]
    return int(executed), int(skipped or 0), int(failures) + int(unexpected)


def run_class(bundle: Path, name: str) -> tuple[str, int, str]:
    result = subprocess.run(
        ["xcrun", "xctest", "-XCTest", name, str(bundle)],
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, check=False)
    return name, result.returncode, result.stdout


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bundle", type=Path, required=True)
    parser.add_argument("--listing", type=Path, required=True)
    parser.add_argument("--workers", type=int, required=True)
    arguments = parser.parse_args(argv)
    if not arguments.bundle.is_dir():
        print(f"XCTest bundle not found: {arguments.bundle}", file=sys.stderr)
        return 2
    classes = xctest_classes(arguments.listing.read_text(encoding="utf-8"))
    if not classes:
        print("No XCTest classes were listed.", file=sys.stderr)
        return 2
    # Largest classes first, so a long class never starts last.
    order = [name for name, _ in classes.most_common()]
    expected = sum(classes.values())
    executed = skipped = 0
    failed: list[str] = []
    with concurrent.futures.ThreadPoolExecutor(arguments.workers) as pool:
        futures = [pool.submit(run_class, arguments.bundle, name) for name in order]
        for future in concurrent.futures.as_completed(futures):
            name, status, output = future.result()
            print(output, end="" if output.endswith("\n") else "\n", flush=True)
            counts = summary(output)
            if counts is None:
                failed.append(f"{name} (no XCTest summary, exit {status})")
                continue
            executed += counts[0]
            skipped += counts[1]
            if status != 0 or counts[2]:
                failed.append(name)
    print(f"XCTest classes: {len(order)}; cases: {executed} of {expected} listed "
          f"({skipped} skipped); failed classes: {len(failed)}")
    for name in sorted(failed):
        print(f"FAILED XCTest class: {name}")
    if executed != expected:
        print(f"XCTest executed {executed} cases but {expected} were listed.", file=sys.stderr)
        return 1
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
