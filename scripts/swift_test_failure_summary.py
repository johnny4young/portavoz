#!/usr/bin/env python3
"""Emit content-free XCTest identifiers from one private Swift test log."""

from __future__ import annotations

import re
import sys
from pathlib import Path
from typing import Sequence


MAXIMUM_LOG_BYTES = 16 * 1024 * 1024
FAILURE_PATTERN = re.compile(
    r"Test Case '(-\[[^']+\])' failed|error: (-\[[^\]]+\])"
)
IDENTIFIER_PATTERN = re.compile(
    r"-\[([A-Za-z0-9_.]+) ([A-Za-z0-9_]+)\]"
)


class FailureSummaryError(ValueError):
    """A malformed or unavailable private diagnostic log."""


def normalize_identifier(raw: str) -> str | None:
    match = IDENTIFIER_PATTERN.fullmatch(raw)
    if match is None:
        return None
    return f"{match.group(1)}/{match.group(2)}"


def failed_test_identifiers(text: str) -> tuple[str, ...]:
    ordered: list[str] = []
    seen: set[str] = set()
    for match in FAILURE_PATTERN.finditer(text):
        raw = match.group(1) or match.group(2)
        identifier = normalize_identifier(raw)
        if identifier is not None and identifier not in seen:
            seen.add(identifier)
            ordered.append(identifier)
    return tuple(ordered)


def load_private_log(path: Path) -> str:
    if not path.is_file():
        raise FailureSummaryError("Swift test diagnostic log is unavailable")
    try:
        with path.open("rb") as source:
            payload = source.read(MAXIMUM_LOG_BYTES + 1)
    except OSError as error:
        raise FailureSummaryError(
            "Swift test diagnostic log could not be read"
        ) from error
    if not payload or len(payload) > MAXIMUM_LOG_BYTES:
        raise FailureSummaryError("Swift test diagnostic log is outside its bound")
    return payload.decode("utf-8", errors="replace")


def main(argv: Sequence[str] | None = None) -> int:
    arguments = tuple(sys.argv[1:] if argv is None else argv)
    if len(arguments) != 1:
        print("usage: swift_test_failure_summary.py <private-log>", file=sys.stderr)
        return 64
    try:
        identifiers = failed_test_identifiers(load_private_log(Path(arguments[0])))
    except FailureSummaryError as error:
        print(f"Swift package failure summary unavailable: {error}", file=sys.stderr)
        return 2

    print("Swift package failure summary (content-free):", file=sys.stderr)
    if identifiers:
        for identifier in identifiers:
            print(f"failed_test={identifier}", file=sys.stderr)
    else:
        print("failed_test=unavailable", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
