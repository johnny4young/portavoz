#!/usr/bin/env python3
"""Assemble strict, content-free graph-query product timing receipts."""

from __future__ import annotations

import argparse
import json
import math
import os
import re
import sys
import uuid
from pathlib import Path
from typing import Any


JOBS = [
    "commitmentBlockers",
    "topicFirstDiscussion",
    "personCommitments",
    "decisionConflicts",
    "changeSince",
    "decisionHistory",
]
FRAGMENT_KEYS = {
    "schemaVersion",
    "run",
    "fixtureGeneration",
    "iterationsPerJob",
    "host",
    "jobs",
}
HOST_KEYS = {
    "architecture",
    "hardwareModel",
    "operatingSystem",
    "operatingSystemBuild",
    "physicalMemoryBytes",
    "powerSource",
    "thermalState",
    "lowPowerModeEnabled",
}
JOB_KEYS = {"job", "outcome", "sampleCount", "wall", "cpu"}
SUMMARY_KEYS = {"p50Milliseconds", "p95Milliseconds", "maximumMilliseconds"}
COMMIT_PATTERN = re.compile(r"[0-9a-f]{40}")
VERSION_PATTERN = re.compile(r"[0-9]+(?:\.[0-9]+){1,3}")
BUILD_PATTERN = re.compile(r"[0-9]{1,18}")


class GraphQueryReceiptError(ValueError):
    """The fragments cannot form a trustworthy product-path receipt."""


def reject_duplicate_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise GraphQueryReceiptError(f"duplicate key: {key}")
        result[key] = value
    return result


def exact_object(value: Any, keys: set[str], label: str) -> dict[str, Any]:
    if not isinstance(value, dict) or set(value) != keys:
        raise GraphQueryReceiptError(f"{label} does not match its schema")
    return value


def integer(value: Any, label: str, minimum: int, maximum: int) -> int:
    if isinstance(value, bool) or not isinstance(value, int):
        raise GraphQueryReceiptError(f"{label} must be an integer")
    if not minimum <= value <= maximum:
        raise GraphQueryReceiptError(f"{label} is outside its bounds")
    return value


def text(value: Any, label: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise GraphQueryReceiptError(f"{label} must be non-empty text")
    return value


def duration_summary(value: Any, label: str) -> dict[str, float]:
    raw = exact_object(value, SUMMARY_KEYS, label)
    numbers: dict[str, float] = {}
    for key in SUMMARY_KEYS:
        number = raw[key]
        if isinstance(number, bool) or not isinstance(number, (int, float)):
            raise GraphQueryReceiptError(f"{label}.{key} must be numeric")
        number = float(number)
        if not math.isfinite(number) or number < 0:
            raise GraphQueryReceiptError(f"{label}.{key} must be finite and non-negative")
        numbers[key] = number
    if not (
        numbers["p50Milliseconds"]
        <= numbers["p95Milliseconds"]
        <= numbers["maximumMilliseconds"]
    ):
        raise GraphQueryReceiptError(f"{label} percentiles are not monotonic")
    return numbers


def read_fragment(path: Path) -> dict[str, Any]:
    try:
        raw = json.loads(
            path.read_text(encoding="utf-8"),
            object_pairs_hook=reject_duplicate_keys,
            parse_constant=lambda value: (_ for _ in ()).throw(
                GraphQueryReceiptError(f"non-finite JSON constant: {value}")
            ),
        )
    except OSError as error:
        raise GraphQueryReceiptError(f"cannot read fragment: {path}") from error
    except json.JSONDecodeError as error:
        raise GraphQueryReceiptError(f"fragment is not valid JSON: {path}") from error
    return validate_fragment(raw, path.name)


def validate_fragment(value: Any, label: str) -> dict[str, Any]:
    fragment = exact_object(value, FRAGMENT_KEYS, label)
    if integer(fragment["schemaVersion"], f"{label}.schemaVersion", 1, 1) != 1:
        raise AssertionError("unreachable")
    run = integer(fragment["run"], f"{label}.run", 1, 100)
    iterations = integer(
        fragment["iterationsPerJob"],
        f"{label}.iterationsPerJob",
        5,
        1_000,
    )
    if fragment["fixtureGeneration"] != "public-synthetic-graph-product-v1":
        raise GraphQueryReceiptError(f"{label} uses an unsupported fixture")

    host = exact_object(fragment["host"], HOST_KEYS, f"{label}.host")
    if host["architecture"] != "arm64":
        raise GraphQueryReceiptError(f"{label} host architecture is unsupported")
    for key in ("hardwareModel", "operatingSystem", "operatingSystemBuild"):
        text(host[key], f"{label}.host.{key}")
    integer(
        host["physicalMemoryBytes"],
        f"{label}.host.physicalMemoryBytes",
        1,
        2**63 - 1,
    )
    if host["powerSource"] != "ac" or host["thermalState"] != "nominal":
        raise GraphQueryReceiptError(f"{label} host was not measurement-ready")
    if host["lowPowerModeEnabled"] is not False:
        raise GraphQueryReceiptError(f"{label} used Low Power Mode")

    jobs = fragment["jobs"]
    if not isinstance(jobs, list) or len(jobs) != len(JOBS):
        raise GraphQueryReceiptError(f"{label} has an invalid job matrix")
    validated_jobs = []
    for expected, value in zip(JOBS, jobs):
        job = exact_object(value, JOB_KEYS, f"{label}.{expected}")
        if job["job"] != expected or job["outcome"] != "facts":
            raise GraphQueryReceiptError(f"{label}.{expected} is not a factful exact job")
        if integer(job["sampleCount"], f"{label}.{expected}.sampleCount", 5, 1_000) != iterations:
            raise GraphQueryReceiptError(f"{label}.{expected} sample count is inconsistent")
        validated_jobs.append({
            "job": expected,
            "outcome": "facts",
            "sampleCount": iterations,
            "wall": duration_summary(job["wall"], f"{label}.{expected}.wall"),
            "cpu": duration_summary(job["cpu"], f"{label}.{expected}.cpu"),
        })

    return {
        "run": run,
        "iterationsPerJob": iterations,
        "host": host,
        "jobs": validated_jobs,
    }


def assemble(
    fragment_paths: list[Path],
    version: str,
    build: str,
    commit: str,
) -> dict[str, Any]:
    if not 3 <= len(fragment_paths) <= 100:
        raise GraphQueryReceiptError("three to one hundred fragments are required")
    if VERSION_PATTERN.fullmatch(version) is None:
        raise GraphQueryReceiptError("version must be a numeric dotted app version")
    if BUILD_PATTERN.fullmatch(build) is None:
        raise GraphQueryReceiptError("build must be a numeric app build")
    if COMMIT_PATTERN.fullmatch(commit) is None:
        raise GraphQueryReceiptError("commit must be one lowercase 40-character SHA")

    runs = sorted((read_fragment(path) for path in fragment_paths), key=lambda item: item["run"])
    if [item["run"] for item in runs] != list(range(1, len(runs) + 1)):
        raise GraphQueryReceiptError("fragment runs must be unique and contiguous from one")
    first = runs[0]
    if any(item["host"] != first["host"] for item in runs[1:]):
        raise GraphQueryReceiptError("fragment hosts are inconsistent")
    if any(item["iterationsPerJob"] != first["iterationsPerJob"] for item in runs[1:]):
        raise GraphQueryReceiptError("fragment iteration counts are inconsistent")

    return {
        "schemaVersion": 1,
        "kind": "meeting-memory-graph-query-product-timing",
        "fixtureGeneration": "public-synthetic-graph-product-v1",
        "build": {"version": version, "number": build, "commit": commit},
        "host": first["host"],
        "iterationsPerJob": first["iterationsPerJob"],
        "runs": [{"run": item["run"], "jobs": item["jobs"]} for item in runs],
    }


def write_private_json(output: Path, document: dict[str, Any]) -> None:
    output.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    if output.exists():
        raise GraphQueryReceiptError(f"output already exists: {output}")
    temporary = output.parent / f".{output.name}.{uuid.uuid4().hex}.tmp"
    data = (json.dumps(document, indent=2, sort_keys=True) + "\n").encode()
    descriptor = os.open(temporary, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    try:
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        try:
            os.link(temporary, output)
        except FileExistsError as error:
            raise GraphQueryReceiptError(f"output already exists: {output}") from error
    finally:
        temporary.unlink(missing_ok=True)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fragment", action="append", type=Path, required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--build", required=True)
    parser.add_argument("--commit", required=True)
    parser.add_argument("--output", type=Path, required=True)
    arguments = parser.parse_args(argv)
    try:
        receipt = assemble(
            arguments.fragment,
            arguments.version,
            arguments.build,
            arguments.commit,
        )
        write_private_json(arguments.output, receipt)
    except GraphQueryReceiptError as error:
        print(f"graph query receipt error: {error}", file=sys.stderr)
        return 64
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
