#!/usr/bin/env python3
"""Fail-closed validation for accelerated long-capture evidence."""

from __future__ import annotations

import argparse
import datetime as dt
import json
import math
import re
from pathlib import Path
from typing import Any


COMMIT = re.compile(r"^[0-9a-f]{40}$")
TOP_LEVEL_KEYS = {
    "schemaVersion",
    "generatedAt",
    "buildConfiguration",
    "sourceCommit",
    "contentSource",
    "host",
    "configuration",
    "channels",
    "result",
}
HOST_KEYS = {
    "operatingSystem",
    "architecture",
    "physicalMemoryBytes",
}
CONFIGURATION_KEYS = {
    "requestedDurationSeconds",
    "sampleRate",
    "chunkFrames",
    "expectedFramesPerChannel",
    "logicalChunksPerChannel",
    "canonicalThreeHourRun",
}
CHANNEL_KEYS = {
    "id",
    "expectedFrames",
    "acceptedFrames",
    "publishedFrames",
    "durationSeconds",
    "byteCount",
    "healthStatus",
}
RESULT_KEYS = {
    "passed",
    "driftFrames",
    "captureWallDurationMilliseconds",
    "stopWallDurationMilliseconds",
    "baselineHeapBytesInUse",
    "peakHeapBytesInUse",
    "incrementalPeakHeapBytesInUse",
    "maximumIncrementalHeapBytesInUse",
    "endingHeapBytesInUse",
}


class EvidenceError(ValueError):
    """The report cannot prove the canonical long-capture contract."""


def _exact_keys(value: Any, expected: set[str], label: str) -> dict[str, Any]:
    if not isinstance(value, dict) or set(value) != expected:
        raise EvidenceError(f"{label} must have the exact schema")
    return value


def _integer(value: Any, label: str, minimum: int = 0) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value < minimum:
        raise EvidenceError(f"{label} must be an integer >= {minimum}")
    return value


def _finite(value: Any, label: str, minimum: float = 0) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise EvidenceError(f"{label} must be numeric")
    number = float(value)
    if not math.isfinite(number) or number < minimum:
        raise EvidenceError(f"{label} must be finite and >= {minimum}")
    return number


def _bounded_string(value: Any, label: str, maximum: int = 256) -> str:
    if not isinstance(value, str) or not value or len(value) > maximum:
        raise EvidenceError(f"{label} must be a nonempty bounded string")
    return value


def validate_report(document: Any, expected_commit: str) -> None:
    if not COMMIT.fullmatch(expected_commit):
        raise EvidenceError("expected commit must be a lowercase 40-character SHA")
    report = _exact_keys(document, TOP_LEVEL_KEYS, "report")
    if report["schemaVersion"] != 1:
        raise EvidenceError("unexpected schemaVersion")
    if report["buildConfiguration"] != "release":
        raise EvidenceError("evidence must come from a Release build")
    if report["sourceCommit"] != expected_commit:
        raise EvidenceError("report is not bound to the requested source commit")
    if report["contentSource"] != "synthetic-only":
        raise EvidenceError("contentSource must be synthetic-only")

    generated_at = _bounded_string(report["generatedAt"], "generatedAt", 64)
    try:
        timestamp = dt.datetime.fromisoformat(generated_at.replace("Z", "+00:00"))
    except ValueError as error:
        raise EvidenceError("generatedAt must be ISO-8601") from error
    if timestamp.tzinfo is None:
        raise EvidenceError("generatedAt must include an offset")

    host = _exact_keys(report["host"], HOST_KEYS, "host")
    _bounded_string(host["operatingSystem"], "host.operatingSystem")
    _bounded_string(host["architecture"], "host.architecture", 64)
    _integer(host["physicalMemoryBytes"], "host.physicalMemoryBytes", 1)

    configuration = _exact_keys(
        report["configuration"], CONFIGURATION_KEYS, "configuration"
    )
    if configuration["requestedDurationSeconds"] != 10_800:
        raise EvidenceError("canonical evidence must simulate exactly three hours")
    if configuration["sampleRate"] != 16_000:
        raise EvidenceError("canonical evidence must use 16 kHz PCM")
    chunk_frames = _integer(configuration["chunkFrames"], "chunkFrames", 1)
    if chunk_frames > 16_000:
        raise EvidenceError("chunkFrames exceeds one second")
    expected_frames = 10_800 * 16_000
    if configuration["expectedFramesPerChannel"] != expected_frames:
        raise EvidenceError("expectedFramesPerChannel is inconsistent")
    expected_chunks = (expected_frames + chunk_frames - 1) // chunk_frames
    if configuration["logicalChunksPerChannel"] != expected_chunks:
        raise EvidenceError("logicalChunksPerChannel is inconsistent")
    if configuration["canonicalThreeHourRun"] is not True:
        raise EvidenceError("canonicalThreeHourRun must be true")

    channels = report["channels"]
    if not isinstance(channels, list) or len(channels) != 2:
        raise EvidenceError("exactly two channel rows are required")
    identifiers: list[str] = []
    for index, raw_channel in enumerate(channels):
        channel = _exact_keys(raw_channel, CHANNEL_KEYS, f"channels[{index}]")
        identifier = channel["id"]
        if identifier not in {"microphone", "system"}:
            raise EvidenceError("channel id is outside the closed contract")
        identifiers.append(identifier)
        for key in ("expectedFrames", "acceptedFrames", "publishedFrames"):
            if channel[key] != expected_frames:
                raise EvidenceError(f"{identifier}.{key} does not conserve frames")
        if _finite(channel["durationSeconds"], f"{identifier}.durationSeconds") != 10_800:
            raise EvidenceError(f"{identifier} duration is not three hours")
        if _integer(channel["byteCount"], f"{identifier}.byteCount", 1) <= expected_frames * 2:
            raise EvidenceError(f"{identifier} file is smaller than its PCM payload")
        if channel["healthStatus"] != "healthy":
            raise EvidenceError(f"{identifier} publication is not healthy")
    if identifiers != ["microphone", "system"]:
        raise EvidenceError("channels must be unique and canonical-order")

    result = _exact_keys(report["result"], RESULT_KEYS, "result")
    if result["passed"] is not True or result["driftFrames"] != 0:
        raise EvidenceError("capture did not pass with zero frame drift")
    _finite(result["captureWallDurationMilliseconds"], "capture wall time")
    _finite(result["stopWallDurationMilliseconds"], "Stop wall time")
    baseline = _integer(
        result["baselineHeapBytesInUse"], "baseline heap", 1
    )
    peak = _integer(result["peakHeapBytesInUse"], "peak heap", 1)
    incremental = _integer(
        result["incrementalPeakHeapBytesInUse"],
        "incremental peak heap",
    )
    maximum_incremental = _integer(
        result["maximumIncrementalHeapBytesInUse"],
        "maximum incremental heap",
        1,
    )
    ending = _integer(result["endingHeapBytesInUse"], "ending heap", 1)
    if peak < baseline or incremental != peak - baseline:
        raise EvidenceError("heap evidence is inconsistent")
    if ending > peak:
        raise EvidenceError("ending heap exceeds the observed peak")
    if maximum_incremental != 16 * 1024**2 or incremental > maximum_incremental:
        raise EvidenceError("duration-invariant heap bound was exceeded")


def main_from_args(arguments: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--report", type=Path, required=True)
    parser.add_argument("--commit", required=True)
    options = parser.parse_args(arguments)
    try:
        document = json.loads(options.report.read_text(encoding="utf-8"))
        validate_report(document, options.commit)
    except (EvidenceError, OSError, json.JSONDecodeError) as error:
        parser.error(str(error))
    print(f"Long-capture evidence verified: {options.report}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main_from_args())
