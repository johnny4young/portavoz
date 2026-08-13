#!/usr/bin/env python3
"""Build, compare, and retain content-free semantic-scale Release evidence."""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import math
import os
import re
import stat
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any, Callable, Sequence


SCHEMA_VERSION = 2
MANIFEST_KIND = "semantic-scale-run-manifest"
COMPARISON_KIND = "semantic-scale-comparison"
CONTROL_BASELINE_KIND = "semantic-scale-control-baseline"
CANONICAL_SCALES = (1_000, 10_000, 50_000, 100_000)
CONTROL_OBSERVATION_COUNT = 3
MAXIMUM_TIMING_RATIO = 1.25
HUNDRED_THOUSAND_BUDGET_MILLISECONDS = 100.0
CANONICAL_CONFIGURATION = {
    "measurementRuns": 20,
    "warmupRuns": 2,
    "embeddingDimension": 512,
    "resultLimit": 12,
    "segmentsPerMeeting": 200,
    "queryVariants": 1,
}
HEX_40 = re.compile(r"^[0-9a-f]{40}$")
HEX_64 = re.compile(r"^[0-9a-f]{64}$")
EMPTY_SHA256 = hashlib.sha256(b"").hexdigest()
TIMESTAMP = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z$")
OS_DESCRIPTION = re.compile(
    r"^Version (?P<version>\d+\.\d+(?:\.\d+)?) "
    r"\(Build (?P<build>[0-9A-Za-z]+)\)$"
)

REPORT_KEYS = {
    "schemaVersion",
    "generatedAt",
    "buildConfiguration",
    "host",
    "configuration",
    "semanticProfile",
    "semanticAssets",
    "fixture",
    "queryPack",
    "checkpoint",
}
HOST_KEYS = {
    "operatingSystem",
    "architecture",
    "processorCount",
    "physicalMemoryBytes",
}
SNAPSHOT_HOST_KEYS = HOST_KEYS | {"hardwareModel", "operatingSystemBuild"}
CONFIGURATION_KEYS = set(CANONICAL_CONFIGURATION)
PROFILE_KEYS = {
    "modelIdentifier",
    "modelRevision",
    "vectorDimension",
    "pipelineIdentifier",
    "pipelineRevision",
    "vectorSchemaVersion",
    "fingerprint",
}
ASSET_KEYS = {
    "provider",
    "script",
    "availability",
    "downloadPolicy",
    "usedByMeasuredVectors",
}
FIXTURE_KEYS = {
    "version",
    "contentSource",
    "userLibraryAccess",
    "vectorGenerator",
    "transcriptGenerator",
    "ephemeralIdentityPolicy",
}
REPORT_QUERY_PACK_KEYS = {"version", "selectionPolicy", "firstQueryIndex"}
MANIFEST_QUERY_PACK_KEYS = {
    "version",
    "selectionPolicy",
    "queryVariants",
    "resultLimit",
}
CHECKPOINT_KEYS = {
    "totalSegments",
    "meetingCount",
    "seedMilliseconds",
    "databaseBytes",
    "rawEmbeddingBytes",
    "resultCount",
    "stageTimings",
    "wallTime",
    "processCPUTime",
    "baselinePhysicalFootprint",
    "peakPhysicalFootprint",
    "incrementalPeakPhysicalFootprint",
    "endingPhysicalFootprint",
}
MANIFEST_CHECKPOINT_KEYS = CHECKPOINT_KEYS | {"firstQueryIndex"}
STAGE_TIMINGS_KEYS = {
    "storeOpen",
    "corpusSeed",
    "warmupQueries",
    "measuredQueries",
}
STAGE_KEYS = {"wallTime", "processCPUTime"}
MILLISECOND_DISTRIBUTION_KEYS = {
    "sampleCount",
    "p50Milliseconds",
    "p95Milliseconds",
    "maximumMilliseconds",
}
BYTE_DISTRIBUTION_KEYS = {
    "sampleCount",
    "p50Bytes",
    "p95Bytes",
    "maximumBytes",
}
SNAPSHOT_KEYS = {
    "schemaVersion",
    "source",
    "binary",
    "toolchain",
    "host",
    "releaseBuild",
}
SOURCE_KEYS = {"commit", "worktreeClean", "worktreeStateSHA256"}
BINARY_KEYS = {"sha256", "sizeBytes"}
TOOLCHAIN_KEYS = {"swift", "target", "xcode", "xcodeBuild"}
RELEASE_BUILD_KEYS = {"wallMilliseconds"}
STAGE_POLICY_KEYS = {"version", "wallClock", "processCPU", "percentile"}
COMPARABILITY_KEYS = {
    "identitySHA256",
    "measurementScope",
    "retentionEligible",
    "reasons",
}
MANIFEST_KEYS = {
    "schemaVersion",
    "kind",
    "generatedAt",
    "source",
    "binary",
    "toolchain",
    "host",
    "releaseBuild",
    "buildConfiguration",
    "configuration",
    "semanticProfile",
    "semanticAssets",
    "fixture",
    "queryPack",
    "stagePolicy",
    "comparability",
    "checkpoints",
}
OBSERVATION_SUMMARY_KEYS = {"sampleCount", "p50", "p95", "minimum", "maximum"}
TIMING_AGGREGATE_KEYS = {
    "sampleCountPerObservation",
    "observations",
    "p50Milliseconds",
    "p95Milliseconds",
    "maximumMilliseconds",
    "p95ToP50Ratio",
    "acrossObservationP95MaximumToMinimumRatio",
}
BYTE_AGGREGATE_KEYS = {
    "sampleCountPerObservation",
    "observations",
    "p50Bytes",
    "p95Bytes",
    "maximumBytes",
}
CONTROL_CHECKPOINT_KEYS = {
    "totalSegments",
    "meetingCount",
    "rawEmbeddingBytes",
    "resultCount",
    "firstQueryIndex",
    "databaseBytes",
    "stageTimings",
    "footprint",
    "measuredQueryStability",
    "budget",
}
CONTROL_BASELINE_KEYS = {
    "schemaVersion",
    "kind",
    "generatedAt",
    "identity",
    "collection",
    "scope",
    "policy",
    "authority",
    "checkpoints",
    "outcome",
    "reasons",
    "receiptSHA256",
}


class ManifestError(ValueError):
    """Input cannot support a trustworthy semantic benchmark manifest."""


def reject_duplicate_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise ManifestError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def read_json(path: Path, label: str) -> Any:
    try:
        return json.loads(
            path.read_text(encoding="utf-8"),
            object_pairs_hook=reject_duplicate_keys,
            parse_constant=lambda value: (_ for _ in ()).throw(
                ManifestError(f"{label} contains non-finite JSON: {value}")
            ),
        )
    except OSError as error:
        raise ManifestError(f"cannot read {label}") from error
    except json.JSONDecodeError as error:
        raise ManifestError(f"{label} is not valid JSON") from error


def exact_object(value: Any, keys: set[str], label: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise ManifestError(f"{label} must be an object")
    actual = set(value)
    if actual != keys:
        details: list[str] = []
        if missing := sorted(keys - actual):
            details.append("missing " + ", ".join(missing))
        if extra := sorted(actual - keys):
            details.append("forbidden " + ", ".join(extra))
        raise ManifestError(f"{label} has an invalid shape: {'; '.join(details)}")
    return value


def exact_int(value: Any, label: str, *, minimum: int = 0) -> int:
    if type(value) is not int or value < minimum:
        raise ManifestError(f"{label} must be an integer >= {minimum}")
    return value


def finite_number(value: Any, label: str, *, minimum: float = 0) -> float:
    if type(value) not in (int, float):
        raise ManifestError(f"{label} must be a finite number")
    number = float(value)
    if not math.isfinite(number) or number < minimum:
        raise ManifestError(f"{label} must be a finite number >= {minimum}")
    return number


def bounded_string(
    value: Any,
    label: str,
    *,
    pattern: re.Pattern[str] | None = None,
    maximum: int = 200,
) -> str:
    if not isinstance(value, str) or not value or len(value) > maximum:
        raise ManifestError(f"{label} must be a non-empty bounded string")
    if pattern is not None and pattern.fullmatch(value) is None:
        raise ManifestError(f"{label} has an invalid format")
    return value


def exact_bool(value: Any, label: str) -> bool:
    if type(value) is not bool:
        raise ManifestError(f"{label} must be a boolean")
    return value


def validate_timestamp(value: Any, label: str) -> str:
    text = bounded_string(value, label, pattern=TIMESTAMP, maximum=40)
    try:
        dt.datetime.fromisoformat(text.removesuffix("Z") + "+00:00")
    except ValueError as error:
        raise ManifestError(f"{label} is not a valid UTC timestamp") from error
    return text


def validate_distribution(
    value: Any,
    label: str,
    *,
    expected_count: int,
    byte_distribution: bool = False,
) -> dict[str, Any]:
    keys = BYTE_DISTRIBUTION_KEYS if byte_distribution else MILLISECOND_DISTRIBUTION_KEYS
    distribution = exact_object(value, keys, label)
    count = exact_int(distribution["sampleCount"], f"{label}.sampleCount", minimum=1)
    if count != expected_count:
        raise ManifestError(
            f"{label}.sampleCount {count} does not match {expected_count}"
        )
    suffix = "Bytes" if byte_distribution else "Milliseconds"
    parser: Callable[[Any, str], float | int]
    if byte_distribution:
        parser = lambda item, item_label: exact_int(item, item_label)
    else:
        parser = lambda item, item_label: finite_number(item, item_label)
    p50 = parser(distribution[f"p50{suffix}"], f"{label}.p50{suffix}")
    p95 = parser(distribution[f"p95{suffix}"], f"{label}.p95{suffix}")
    maximum = parser(distribution[f"maximum{suffix}"], f"{label}.maximum{suffix}")
    if not p50 <= p95 <= maximum:
        raise ManifestError(f"{label} percentiles are not monotonic")
    return distribution


def validate_host(value: Any, label: str, *, snapshot: bool = False) -> dict[str, Any]:
    keys = SNAPSHOT_HOST_KEYS if snapshot else HOST_KEYS
    host = exact_object(value, keys, label)
    bounded_string(host["operatingSystem"], f"{label}.operatingSystem")
    bounded_string(
        host["architecture"],
        f"{label}.architecture",
        pattern=re.compile(r"^[A-Za-z0-9_-]+$"),
        maximum=32,
    )
    exact_int(host["processorCount"], f"{label}.processorCount", minimum=1)
    exact_int(
        host["physicalMemoryBytes"], f"{label}.physicalMemoryBytes", minimum=1
    )
    if snapshot:
        bounded_string(
            host["hardwareModel"],
            f"{label}.hardwareModel",
            pattern=re.compile(r"^[A-Za-z0-9,._-]+$"),
            maximum=80,
        )
        bounded_string(
            host["operatingSystemBuild"],
            f"{label}.operatingSystemBuild",
            pattern=re.compile(r"^[0-9A-Za-z]+$"),
            maximum=32,
        )
        match = OS_DESCRIPTION.fullmatch(host["operatingSystem"])
        if match is None or match.group("build") != host["operatingSystemBuild"]:
            raise ManifestError(f"{label} operating-system identity is inconsistent")
    return host


def validate_configuration(value: Any, label: str) -> dict[str, Any]:
    configuration = exact_object(value, CONFIGURATION_KEYS, label)
    for key in CONFIGURATION_KEYS:
        exact_int(configuration[key], f"{label}.{key}", minimum=1)
    if not 1 <= configuration["queryVariants"] <= 8:
        raise ManifestError(f"{label}.queryVariants is outside 1...8")
    return configuration


def operation_fingerprint(version: str, components: Sequence[str]) -> str:
    canonical = "|".join(
        f"{len(component.encode('utf-8'))}:{component}"
        for component in (version, *components)
    )
    return hashlib.sha256(canonical.encode("utf-8")).hexdigest()


def semantic_profile_fingerprint(profile: dict[str, Any]) -> str:
    return operation_fingerprint(
        "semantic-embedding-profile-v1",
        (
            profile["modelIdentifier"],
            str(profile["modelRevision"]),
            str(profile["vectorDimension"]),
            profile["pipelineIdentifier"],
            str(profile["pipelineRevision"]),
            str(profile["vectorSchemaVersion"]),
        ),
    )


def validate_profile(value: Any, label: str) -> dict[str, Any]:
    profile = exact_object(value, PROFILE_KEYS, label)
    model_identifier = bounded_string(
        profile["modelIdentifier"], f"{label}.modelIdentifier"
    )
    if not model_identifier.strip():
        raise ManifestError(f"{label}.modelIdentifier must not be blank")
    exact_int(profile["modelRevision"], f"{label}.modelRevision")
    exact_int(profile["vectorDimension"], f"{label}.vectorDimension", minimum=1)
    pipeline_identifier = bounded_string(
        profile["pipelineIdentifier"], f"{label}.pipelineIdentifier"
    )
    if not pipeline_identifier.strip():
        raise ManifestError(f"{label}.pipelineIdentifier must not be blank")
    exact_int(profile["pipelineRevision"], f"{label}.pipelineRevision", minimum=1)
    exact_int(
        profile["vectorSchemaVersion"],
        f"{label}.vectorSchemaVersion",
        minimum=1,
    )
    fingerprint = bounded_string(
        profile["fingerprint"], f"{label}.fingerprint", pattern=HEX_64, maximum=64
    )
    if fingerprint != semantic_profile_fingerprint(profile):
        raise ManifestError(f"{label}.fingerprint is inconsistent")
    return profile


def validate_assets(value: Any, label: str) -> dict[str, Any]:
    assets = exact_object(value, ASSET_KEYS, label)
    if assets["provider"] != "apple-natural-language":
        raise ManifestError(f"{label}.provider is not canonical")
    if assets["script"] != "latin":
        raise ManifestError(f"{label}.script is not canonical")
    if assets["availability"] not in {"installed", "missing"}:
        raise ManifestError(f"{label}.availability is invalid")
    if assets["downloadPolicy"] != "never":
        raise ManifestError(f"{label}.downloadPolicy must be never")
    if exact_bool(
        assets["usedByMeasuredVectors"], f"{label}.usedByMeasuredVectors"
    ):
        raise ManifestError(f"{label} must disclose synthetic measured vectors")
    return assets


def validate_fixture(value: Any, label: str) -> dict[str, Any]:
    fixture = exact_object(value, FIXTURE_KEYS, label)
    expected = {
        "version": "semantic-scale-synthetic-v1",
        "contentSource": "synthetic-only",
        "userLibraryAccess": "none",
        "vectorGenerator": "lcg-normalized-float32-v1",
        "transcriptGenerator": "ordinal-placeholder-v1",
        "ephemeralIdentityPolicy": "excluded-from-comparison-v1",
    }
    if fixture != expected:
        raise ManifestError(f"{label} is not the canonical public fixture")
    return fixture


def validate_stage(
    value: Any, label: str, *, expected_count: int
) -> dict[str, Any]:
    stage = exact_object(value, STAGE_KEYS, label)
    validate_distribution(
        stage["wallTime"], f"{label}.wallTime", expected_count=expected_count
    )
    validate_distribution(
        stage["processCPUTime"],
        f"{label}.processCPUTime",
        expected_count=expected_count,
    )
    return stage


def validate_checkpoint(
    value: Any,
    configuration: dict[str, Any],
    *,
    label: str,
    manifest_shape: bool = False,
) -> dict[str, Any]:
    keys = MANIFEST_CHECKPOINT_KEYS if manifest_shape else CHECKPOINT_KEYS
    checkpoint = exact_object(value, keys, label)
    total_segments = exact_int(
        checkpoint["totalSegments"], f"{label}.totalSegments", minimum=1
    )
    expected_meetings = math.ceil(
        total_segments / configuration["segmentsPerMeeting"]
    )
    meeting_count = exact_int(
        checkpoint["meetingCount"], f"{label}.meetingCount", minimum=1
    )
    if meeting_count != expected_meetings:
        raise ManifestError(f"{label}.meetingCount is inconsistent")
    finite_number(checkpoint["seedMilliseconds"], f"{label}.seedMilliseconds")
    exact_int(checkpoint["databaseBytes"], f"{label}.databaseBytes", minimum=1)
    expected_raw_bytes = (
        total_segments * configuration["embeddingDimension"] * 4
    )
    raw_embedding_bytes = exact_int(
        checkpoint["rawEmbeddingBytes"], f"{label}.rawEmbeddingBytes", minimum=1
    )
    if raw_embedding_bytes != expected_raw_bytes:
        raise ManifestError(f"{label}.rawEmbeddingBytes is inconsistent")
    expected_results = min(total_segments, configuration["resultLimit"])
    result_count = exact_int(
        checkpoint["resultCount"], f"{label}.resultCount", minimum=1
    )
    if result_count != expected_results:
        raise ManifestError(f"{label}.resultCount is incomplete")
    if manifest_shape:
        expected_index = total_segments // 2
        first_query_index = exact_int(
            checkpoint["firstQueryIndex"], f"{label}.firstQueryIndex"
        )
        if first_query_index != expected_index:
            raise ManifestError(f"{label}.firstQueryIndex is inconsistent")

    stages = exact_object(
        checkpoint["stageTimings"], STAGE_TIMINGS_KEYS, f"{label}.stageTimings"
    )
    validate_stage(stages["storeOpen"], f"{label}.stageTimings.storeOpen", expected_count=1)
    seed = validate_stage(
        stages["corpusSeed"], f"{label}.stageTimings.corpusSeed", expected_count=1
    )
    validate_stage(
        stages["warmupQueries"],
        f"{label}.stageTimings.warmupQueries",
        expected_count=configuration["warmupRuns"],
    )
    measured = validate_stage(
        stages["measuredQueries"],
        f"{label}.stageTimings.measuredQueries",
        expected_count=configuration["measurementRuns"],
    )
    if checkpoint["seedMilliseconds"] != seed["wallTime"]["p50Milliseconds"]:
        raise ManifestError(f"{label}.seedMilliseconds disagrees with corpusSeed")

    wall = validate_distribution(
        checkpoint["wallTime"],
        f"{label}.wallTime",
        expected_count=configuration["measurementRuns"],
    )
    cpu = validate_distribution(
        checkpoint["processCPUTime"],
        f"{label}.processCPUTime",
        expected_count=configuration["measurementRuns"],
    )
    if wall != measured["wallTime"] or cpu != measured["processCPUTime"]:
        raise ManifestError(f"{label} measured-query timing disagrees")
    for key in (
        "baselinePhysicalFootprint",
        "peakPhysicalFootprint",
        "incrementalPeakPhysicalFootprint",
        "endingPhysicalFootprint",
    ):
        validate_distribution(
            checkpoint[key],
            f"{label}.{key}",
            expected_count=configuration["measurementRuns"],
            byte_distribution=True,
        )
    return checkpoint


def validate_report(value: Any, label: str) -> dict[str, Any]:
    report = exact_object(value, REPORT_KEYS, label)
    schema_version = exact_int(
        report["schemaVersion"], f"{label}.schemaVersion", minimum=1
    )
    if schema_version != SCHEMA_VERSION:
        raise ManifestError(f"{label}.schemaVersion is not {SCHEMA_VERSION}")
    validate_timestamp(report["generatedAt"], f"{label}.generatedAt")
    if report["buildConfiguration"] != "release":
        raise ManifestError(f"{label} did not come from a Release binary")
    validate_host(report["host"], f"{label}.host")
    configuration = validate_configuration(
        report["configuration"], f"{label}.configuration"
    )
    profile = validate_profile(report["semanticProfile"], f"{label}.semanticProfile")
    if profile["vectorDimension"] != configuration["embeddingDimension"]:
        raise ManifestError(f"{label} profile and configuration dimensions differ")
    validate_assets(report["semanticAssets"], f"{label}.semanticAssets")
    validate_fixture(report["fixture"], f"{label}.fixture")
    query_pack = exact_object(
        report["queryPack"], REPORT_QUERY_PACK_KEYS, f"{label}.queryPack"
    )
    if query_pack["version"] != "semantic-present-vector-queries-v1":
        raise ManifestError(f"{label}.queryPack.version is not canonical")
    if query_pack["selectionPolicy"] != "midpoint-consecutive-wrap-v1":
        raise ManifestError(f"{label}.queryPack.selectionPolicy is not canonical")
    checkpoint = validate_checkpoint(
        report["checkpoint"], configuration, label=f"{label}.checkpoint"
    )
    if query_pack["firstQueryIndex"] != checkpoint["totalSegments"] // 2:
        raise ManifestError(f"{label}.queryPack.firstQueryIndex is inconsistent")
    return report


def run_command(arguments: Sequence[str], label: str, *, cwd: Path) -> bytes:
    try:
        result = subprocess.run(
            list(arguments),
            cwd=cwd,
            check=False,
            capture_output=True,
            timeout=10,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise ManifestError(f"cannot inspect {label}") from error
    if result.returncode != 0:
        raise ManifestError(f"cannot inspect {label}")
    return result.stdout


def one_line(arguments: Sequence[str], label: str, *, cwd: Path) -> str:
    output = run_command(arguments, label, cwd=cwd)
    try:
        lines = output.decode("utf-8").splitlines()
    except UnicodeError as error:
        raise ManifestError(f"{label} is not UTF-8") from error
    if len(lines) != 1 or not lines[0].strip():
        raise ManifestError(f"{label} is not one non-empty line")
    return lines[0].strip()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    try:
        with path.open("rb") as stream:
            while chunk := stream.read(1024 * 1024):
                digest.update(chunk)
    except OSError as error:
        raise ManifestError("cannot read Release benchmark binary") from error
    return digest.hexdigest()


def update_digest_record(digest: Any, label: bytes, payload: bytes) -> None:
    """Append one unambiguous length-prefixed record to a SHA-256 digest."""
    digest.update(len(label).to_bytes(8, "big"))
    digest.update(label)
    digest.update(len(payload).to_bytes(8, "big"))
    digest.update(payload)


def update_untracked_file_digest(digest: Any, root: Path, relative: bytes) -> None:
    if not relative or relative.startswith(b"/") or b".." in relative.split(b"/"):
        raise ManifestError("worktree contains an invalid untracked path")
    path = os.path.join(os.fsencode(root), relative)
    try:
        metadata = os.lstat(path)
    except OSError as error:
        raise ManifestError("cannot inspect untracked worktree content") from error

    mode = metadata.st_mode
    update_digest_record(digest, b"untracked-path", relative)
    update_digest_record(digest, b"untracked-mode", f"{mode:o}".encode("ascii"))
    if stat.S_ISLNK(mode):
        try:
            target = os.readlink(path)
        except OSError as error:
            raise ManifestError("cannot inspect untracked symlink") from error
        update_digest_record(digest, b"untracked-symlink", os.fsencode(target))
        return
    if not stat.S_ISREG(mode):
        raise ManifestError("worktree contains an unsupported untracked file type")

    update_digest_record(digest, b"untracked-size", str(metadata.st_size).encode("ascii"))
    try:
        with open(path, "rb") as stream:
            content_digest = hashlib.sha256()
            while chunk := stream.read(1024 * 1024):
                content_digest.update(chunk)
            final_metadata = os.fstat(stream.fileno())
    except OSError as error:
        raise ManifestError("cannot read untracked worktree content") from error
    stable_fields = ("st_dev", "st_ino", "st_mode", "st_size", "st_mtime_ns")
    if any(
        getattr(metadata, field) != getattr(final_metadata, field)
        for field in stable_fields
    ):
        raise ManifestError("untracked worktree content changed during inspection")
    update_digest_record(digest, b"untracked-content-sha256", content_digest.digest())


def collect_worktree_state(root: Path) -> tuple[bytes, str]:
    status = run_command(
        [
            "/usr/bin/git",
            "status",
            "--porcelain=v1",
            "-z",
            "--untracked-files=all",
        ],
        "worktree state",
        cwd=root,
    )
    if not status:
        return status, EMPTY_SHA256

    tracked = run_command(
        [
            "/usr/bin/git",
            "diff",
            "--binary",
            "--full-index",
            "--no-ext-diff",
            "HEAD",
            "--",
        ],
        "tracked worktree content",
        cwd=root,
    )
    untracked = run_command(
        ["/usr/bin/git", "ls-files", "--others", "--exclude-standard", "-z"],
        "untracked worktree paths",
        cwd=root,
    )
    paths = untracked.split(b"\0")
    if paths[-1:] != [b""]:
        raise ManifestError("untracked worktree paths are not NUL-terminated")

    digest = hashlib.sha256()
    update_digest_record(digest, b"git-status-v1", status)
    update_digest_record(digest, b"git-diff-head-v1", tracked)
    for relative in paths[:-1]:
        update_untracked_file_digest(digest, root, relative)
    return status, digest.hexdigest()


def collect_source(root: Path) -> dict[str, Any]:
    root = root.resolve()
    commit = one_line(["/usr/bin/git", "rev-parse", "HEAD"], "source commit", cwd=root)
    bounded_string(commit, "source commit", pattern=HEX_40, maximum=40)
    status, state_digest = collect_worktree_state(root)
    repeated_status, repeated_digest = collect_worktree_state(root)
    if (status, state_digest) != (repeated_status, repeated_digest):
        raise ManifestError("worktree changed during source inspection")
    source = {
        "commit": commit,
        "worktreeClean": not status,
        "worktreeStateSHA256": state_digest,
    }
    validate_source(source, "collected source")
    return source


def validate_source(value: Any, label: str) -> dict[str, Any]:
    source = exact_object(value, SOURCE_KEYS, label)
    bounded_string(source["commit"], f"{label}.commit", pattern=HEX_40, maximum=40)
    clean = exact_bool(source["worktreeClean"], f"{label}.worktreeClean")
    state_digest = bounded_string(
        source["worktreeStateSHA256"],
        f"{label}.worktreeStateSHA256",
        pattern=HEX_64,
        maximum=64,
    )
    if clean != (state_digest == EMPTY_SHA256):
        raise ManifestError(f"{label} clean state and digest are inconsistent")
    return source


def collect_snapshot(
    root: Path,
    binary: Path,
    build_wall_ms: float,
    *,
    expected_source: dict[str, Any] | None = None,
) -> dict[str, Any]:
    root = root.resolve()
    binary = binary.resolve()
    source = collect_source(root)
    if expected_source is not None:
        validate_source(expected_source, "expected source")
        if source != expected_source:
            raise ManifestError("source checkout changed during Release build")
    try:
        binary_size = binary.stat().st_size
    except OSError as error:
        raise ManifestError("cannot stat Release benchmark binary") from error
    if binary_size < 1:
        raise ManifestError("Release benchmark binary is empty")

    swift_lines = run_command(["/usr/bin/swift", "--version"], "Swift toolchain", cwd=root)
    try:
        decoded_swift = swift_lines.decode("utf-8").splitlines()
    except UnicodeError as error:
        raise ManifestError("Swift toolchain output is not UTF-8") from error
    if len(decoded_swift) < 2 or not decoded_swift[0].startswith("Apple Swift version "):
        raise ManifestError("Swift toolchain identity is incomplete")
    target_lines = [
        line.removeprefix("Target:").strip()
        for line in decoded_swift
        if line.startswith("Target:")
    ]
    if len(target_lines) != 1 or not target_lines[0]:
        raise ManifestError("Swift target identity is incomplete")

    xcode_lines = run_command(["/usr/bin/xcodebuild", "-version"], "Xcode toolchain", cwd=root)
    try:
        decoded_xcode = xcode_lines.decode("utf-8").splitlines()
    except UnicodeError as error:
        raise ManifestError("Xcode toolchain output is not UTF-8") from error
    if len(decoded_xcode) != 2 or not decoded_xcode[1].startswith("Build version "):
        raise ManifestError("Xcode toolchain identity is incomplete")

    operating_system_version = one_line(
        ["/usr/bin/sw_vers", "-productVersion"], "operating system version", cwd=root
    )
    operating_system_build = one_line(
        ["/usr/bin/sw_vers", "-buildVersion"], "operating system build", cwd=root
    )
    architecture = one_line(["/usr/bin/uname", "-m"], "architecture", cwd=root)
    hardware_model = one_line(
        ["/usr/sbin/sysctl", "-n", "hw.model"], "hardware model", cwd=root
    )
    try:
        processor_count = int(
            one_line(
                ["/usr/sbin/sysctl", "-n", "hw.ncpu"], "processor count", cwd=root
            )
        )
        physical_memory = int(
            one_line(
                ["/usr/sbin/sysctl", "-n", "hw.memsize"], "physical memory", cwd=root
            )
        )
    except ValueError as error:
        raise ManifestError("host numeric identity is invalid") from error

    snapshot = {
        "schemaVersion": 1,
        "source": source,
        "binary": {
            "sha256": sha256_file(binary),
            "sizeBytes": binary_size,
        },
        "toolchain": {
            "swift": decoded_swift[0].removeprefix("Apple Swift version ").strip(),
            "target": target_lines[0],
            "xcode": decoded_xcode[0].strip(),
            "xcodeBuild": decoded_xcode[1].removeprefix("Build version ").strip(),
        },
        "host": {
            "operatingSystem": (
                f"Version {operating_system_version} (Build {operating_system_build})"
            ),
            "operatingSystemBuild": operating_system_build,
            "architecture": architecture,
            "hardwareModel": hardware_model,
            "processorCount": processor_count,
            "physicalMemoryBytes": physical_memory,
        },
        "releaseBuild": {"wallMilliseconds": build_wall_ms},
    }
    validate_snapshot(snapshot, "collected snapshot")
    return snapshot


def validate_snapshot(value: Any, label: str) -> dict[str, Any]:
    snapshot = exact_object(value, SNAPSHOT_KEYS, label)
    if exact_int(snapshot["schemaVersion"], f"{label}.schemaVersion", minimum=1) != 1:
        raise ManifestError(f"{label}.schemaVersion is not 1")
    validate_source(snapshot["source"], f"{label}.source")
    binary = exact_object(snapshot["binary"], BINARY_KEYS, f"{label}.binary")
    bounded_string(binary["sha256"], f"{label}.binary.sha256", pattern=HEX_64, maximum=64)
    exact_int(binary["sizeBytes"], f"{label}.binary.sizeBytes", minimum=1)
    toolchain = exact_object(snapshot["toolchain"], TOOLCHAIN_KEYS, f"{label}.toolchain")
    for key in TOOLCHAIN_KEYS:
        bounded_string(toolchain[key], f"{label}.toolchain.{key}")
    validate_host(snapshot["host"], f"{label}.host", snapshot=True)
    build = exact_object(snapshot["releaseBuild"], RELEASE_BUILD_KEYS, f"{label}.releaseBuild")
    finite_number(build["wallMilliseconds"], f"{label}.releaseBuild.wallMilliseconds")
    return snapshot


def canonical_json(value: Any) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode(
        "utf-8"
    )


def identity_payload(manifest: dict[str, Any]) -> dict[str, Any]:
    return {
        "source": manifest["source"],
        "binary": manifest["binary"],
        "toolchain": manifest["toolchain"],
        "host": manifest["host"],
        "buildConfiguration": manifest["buildConfiguration"],
        "configuration": manifest["configuration"],
        "semanticProfile": manifest["semanticProfile"],
        "semanticAssets": manifest["semanticAssets"],
        "fixture": manifest["fixture"],
        "queryPack": manifest["queryPack"],
        "stagePolicy": manifest["stagePolicy"],
        "scales": [item["totalSegments"] for item in manifest["checkpoints"]],
    }


def comparability_for(manifest: dict[str, Any]) -> dict[str, Any]:
    reasons: list[str] = []
    if tuple(item["totalSegments"] for item in manifest["checkpoints"]) != CANONICAL_SCALES:
        reasons.append("noncanonical-scales")
    if manifest["configuration"] != CANONICAL_CONFIGURATION:
        reasons.append("noncanonical-configuration")
    if not manifest["source"]["worktreeClean"]:
        reasons.append("dirty-worktree")
    measurement_scope = "canonical" if not reasons[:2] else "custom"
    identity = hashlib.sha256(canonical_json(identity_payload(manifest))).hexdigest()
    return {
        "identitySHA256": identity,
        "measurementScope": measurement_scope,
        "retentionEligible": measurement_scope == "canonical" and not reasons,
        "reasons": reasons,
    }


def assemble_manifest(
    snapshot: dict[str, Any], reports: Sequence[dict[str, Any]], generated_at: str
) -> dict[str, Any]:
    validate_snapshot(snapshot, "snapshot")
    if not reports:
        raise ManifestError("semantic benchmark produced no checkpoints")
    validated = [
        validate_report(report, f"checkpoint report {index}")
        for index, report in enumerate(reports)
    ]
    validated.sort(key=lambda report: report["checkpoint"]["totalSegments"])
    scales = [report["checkpoint"]["totalSegments"] for report in validated]
    if len(scales) != len(set(scales)):
        raise ManifestError("semantic benchmark repeated a checkpoint scale")

    first = validated[0]
    common_keys = (
        "buildConfiguration",
        "host",
        "configuration",
        "semanticProfile",
        "semanticAssets",
        "fixture",
    )
    for index, report in enumerate(validated[1:], start=1):
        for key in common_keys:
            if report[key] != first[key]:
                raise ManifestError(f"checkpoint report {index} changed {key}")
        for key in ("version", "selectionPolicy"):
            if report["queryPack"][key] != first["queryPack"][key]:
                raise ManifestError(f"checkpoint report {index} changed queryPack.{key}")

    expected_os = snapshot["host"]["operatingSystem"]
    checkpoint_host = first["host"]
    if checkpoint_host != {
        "operatingSystem": expected_os,
        "architecture": snapshot["host"]["architecture"],
        "processorCount": snapshot["host"]["processorCount"],
        "physicalMemoryBytes": snapshot["host"]["physicalMemoryBytes"],
    }:
        raise ManifestError("checkpoint host disagrees with wrapper snapshot")

    checkpoints: list[dict[str, Any]] = []
    for report in validated:
        checkpoint = dict(report["checkpoint"])
        checkpoint["firstQueryIndex"] = report["queryPack"]["firstQueryIndex"]
        checkpoints.append(checkpoint)

    manifest = {
        "schemaVersion": SCHEMA_VERSION,
        "kind": MANIFEST_KIND,
        "generatedAt": validate_timestamp(generated_at, "generatedAt"),
        "source": snapshot["source"],
        "binary": snapshot["binary"],
        "toolchain": snapshot["toolchain"],
        "host": snapshot["host"],
        "releaseBuild": snapshot["releaseBuild"],
        "buildConfiguration": first["buildConfiguration"],
        "configuration": first["configuration"],
        "semanticProfile": first["semanticProfile"],
        "semanticAssets": first["semanticAssets"],
        "fixture": first["fixture"],
        "queryPack": {
            "version": first["queryPack"]["version"],
            "selectionPolicy": first["queryPack"]["selectionPolicy"],
            "queryVariants": first["configuration"]["queryVariants"],
            "resultLimit": first["configuration"]["resultLimit"],
        },
        "stagePolicy": {
            "version": "semantic-scale-stages-v1",
            "wallClock": "continuous-clock",
            "processCPU": "rusage-user-plus-system",
            "percentile": "nearest-rank-v1",
        },
        "comparability": {},
        "checkpoints": checkpoints,
    }
    manifest["comparability"] = comparability_for(manifest)
    validate_manifest(manifest, "assembled manifest")
    return manifest


def validate_manifest(value: Any, label: str) -> dict[str, Any]:
    manifest = exact_object(value, MANIFEST_KEYS, label)
    schema_version = exact_int(
        manifest["schemaVersion"], f"{label}.schemaVersion", minimum=1
    )
    if schema_version != SCHEMA_VERSION or manifest["kind"] != MANIFEST_KIND:
        raise ManifestError(f"{label} is not a schema-{SCHEMA_VERSION} semantic manifest")
    validate_timestamp(manifest["generatedAt"], f"{label}.generatedAt")
    snapshot = {
        "schemaVersion": 1,
        "source": manifest["source"],
        "binary": manifest["binary"],
        "toolchain": manifest["toolchain"],
        "host": manifest["host"],
        "releaseBuild": manifest["releaseBuild"],
    }
    validate_snapshot(snapshot, f"{label}.identity")
    if manifest["buildConfiguration"] != "release":
        raise ManifestError(f"{label}.buildConfiguration is not release")
    configuration = validate_configuration(
        manifest["configuration"], f"{label}.configuration"
    )
    profile = validate_profile(manifest["semanticProfile"], f"{label}.semanticProfile")
    if profile["vectorDimension"] != configuration["embeddingDimension"]:
        raise ManifestError(f"{label} profile and configuration dimensions differ")
    validate_assets(manifest["semanticAssets"], f"{label}.semanticAssets")
    validate_fixture(manifest["fixture"], f"{label}.fixture")
    query_pack = exact_object(
        manifest["queryPack"], MANIFEST_QUERY_PACK_KEYS, f"{label}.queryPack"
    )
    if query_pack != {
        "version": "semantic-present-vector-queries-v1",
        "selectionPolicy": "midpoint-consecutive-wrap-v1",
        "queryVariants": configuration["queryVariants"],
        "resultLimit": configuration["resultLimit"],
    }:
        raise ManifestError(f"{label}.queryPack is inconsistent")
    stage_policy = exact_object(
        manifest["stagePolicy"], STAGE_POLICY_KEYS, f"{label}.stagePolicy"
    )
    if stage_policy != {
        "version": "semantic-scale-stages-v1",
        "wallClock": "continuous-clock",
        "processCPU": "rusage-user-plus-system",
        "percentile": "nearest-rank-v1",
    }:
        raise ManifestError(f"{label}.stagePolicy is not canonical")
    checkpoints = manifest["checkpoints"]
    if not isinstance(checkpoints, list) or not checkpoints:
        raise ManifestError(f"{label}.checkpoints must be a non-empty array")
    previous = 0
    for index, checkpoint in enumerate(checkpoints):
        validated = validate_checkpoint(
            checkpoint,
            configuration,
            label=f"{label}.checkpoints[{index}]",
            manifest_shape=True,
        )
        if validated["totalSegments"] <= previous:
            raise ManifestError(f"{label}.checkpoints are not strictly ordered")
        previous = validated["totalSegments"]
    comparability = exact_object(
        manifest["comparability"], COMPARABILITY_KEYS, f"{label}.comparability"
    )
    expected = comparability_for(manifest)
    if comparability != expected:
        raise ManifestError(f"{label}.comparability is not recomputable")
    return manifest


def legacy_observation(value: Any, label: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise ManifestError(f"{label} is neither a current nor legacy semantic report")
    schema_version = exact_int(
        value.get("schemaVersion"), f"{label}.schemaVersion", minimum=1
    )
    if schema_version != 1:
        raise ManifestError(f"{label} is neither a current nor legacy semantic report")
    configuration = value.get("configuration")
    host = value.get("host")
    checkpoints = value.get("checkpoints")
    if not isinstance(configuration, dict) or not isinstance(host, dict):
        raise ManifestError(f"{label} legacy identity is malformed")
    if not isinstance(checkpoints, list):
        raise ManifestError(f"{label} legacy checkpoints are malformed")
    hundred_thousand = [
        item
        for item in checkpoints
        if isinstance(item, dict) and item.get("totalSegments") == 100_000
    ]
    if len(hundred_thousand) != 1:
        raise ManifestError(f"{label} has no unique 100k checkpoint")
    checkpoint = hundred_thousand[0]
    wall = checkpoint.get("wallTime")
    cpu = checkpoint.get("processCPUTime")
    if not isinstance(wall, dict) or not isinstance(cpu, dict):
        raise ManifestError(f"{label} legacy timing is malformed")
    wall_p95 = finite_number(wall.get("p95Milliseconds"), f"{label}.wallP95")
    cpu_p95 = finite_number(cpu.get("p95Milliseconds"), f"{label}.cpuP95")
    missing = [
        "source",
        "binary",
        "semanticProfile",
        "semanticAssets",
        "fixture",
        "queryPack",
        "stagePolicy",
        "checkpoints[].stageTimings",
    ]
    if "queryVariants" not in configuration:
        missing.append("configuration.queryVariants")
    if not isinstance(value.get("toolchain"), dict):
        missing.append("toolchain")
    return {
        "schemaVersion": 1,
        "totalSegments": 100_000,
        "wallP95Milliseconds": wall_p95,
        "cpuP95Milliseconds": cpu_p95,
        "missingComparabilityFields": sorted(missing),
    }


def nearest_rank(values: Sequence[float], percentile: float) -> float:
    ordered = sorted(values)
    index = min(len(ordered) - 1, max(0, math.ceil(len(ordered) * percentile) - 1))
    return ordered[index]


def comparison_row(manifest: dict[str, Any]) -> dict[str, Any]:
    checkpoint = next(
        (item for item in manifest["checkpoints"] if item["totalSegments"] == 100_000),
        manifest["checkpoints"][-1],
    )
    return {
        "schemaVersion": manifest["schemaVersion"],
        "totalSegments": checkpoint["totalSegments"],
        "wallP95Milliseconds": checkpoint["wallTime"]["p95Milliseconds"],
        "cpuP95Milliseconds": checkpoint["processCPUTime"]["p95Milliseconds"],
        "missingComparabilityFields": [],
    }


def compare_documents(documents: Sequence[Any], generated_at: str) -> dict[str, Any]:
    if len(documents) < 2:
        raise ManifestError("comparison requires at least two manifests")
    manifests: list[dict[str, Any]] = []
    observations: list[dict[str, Any]] = []
    legacy = False
    for index, document in enumerate(documents):
        if (
            isinstance(document, dict)
            and document.get("schemaVersion") == SCHEMA_VERSION
            and document.get("kind") == MANIFEST_KIND
        ):
            manifest = validate_manifest(document, f"comparison input {index}")
            manifests.append(manifest)
            observations.append(comparison_row(manifest))
        else:
            legacy = True
            observations.append(legacy_observation(document, f"comparison input {index}"))

    reasons: list[str] = []
    outcome = "not-comparable"
    identity: str | None = None
    p95_summary: dict[str, Any] | None = None
    if legacy:
        reasons.append("legacy-schema-lacks-comparability-identity")
    elif len(manifests) == len(documents):
        identities = {item["comparability"]["identitySHA256"] for item in manifests}
        if len(identities) != 1:
            reasons.append("comparability-identity-mismatch")
        else:
            identity = identities.pop()
            reasons = sorted(
                {
                    reason
                    for item in manifests
                    for reason in item["comparability"]["reasons"]
                }
            )
            scales = {item["totalSegments"] for item in observations}
            if len(scales) != 1:
                outcome = "not-comparable"
                reasons = sorted({*reasons, "comparison-scale-mismatch"})
            else:
                retention = all(
                    item["comparability"]["retentionEligible"] for item in manifests
                )
                outcome = (
                    "comparable-retainable" if retention else "comparable-development"
                )
                walls = [float(item["wallP95Milliseconds"]) for item in observations]
                cpus = [float(item["cpuP95Milliseconds"]) for item in observations]
                p95_summary = {
                    "sampleCount": len(observations),
                    "wallMilliseconds": {
                        "p50Observation": nearest_rank(walls, 0.50),
                        "p95Observation": nearest_rank(walls, 0.95),
                        "minimumObservation": min(walls),
                        "maximumObservation": max(walls),
                    },
                    "processCPUMilliseconds": {
                        "p50Observation": nearest_rank(cpus, 0.50),
                        "p95Observation": nearest_rank(cpus, 0.95),
                        "minimumObservation": min(cpus),
                        "maximumObservation": max(cpus),
                    },
                }

    return {
        "schemaVersion": 1,
        "kind": COMPARISON_KIND,
        "generatedAt": validate_timestamp(generated_at, "generatedAt"),
        "outcome": outcome,
        "identitySHA256": identity,
        "reasons": reasons,
        "observations": observations,
        "p95AcrossObservations": p95_summary,
        "decisionAuthority": "none",
    }


def observation_summary(values: Sequence[float | int]) -> dict[str, Any]:
    if len(values) != CONTROL_OBSERVATION_COUNT:
        raise ManifestError(
            f"control baseline requires exactly {CONTROL_OBSERVATION_COUNT} observations"
        )
    return {
        "sampleCount": len(values),
        "p50": nearest_rank(values, 0.50),
        "p95": nearest_rank(values, 0.95),
        "minimum": min(values),
        "maximum": max(values),
    }


def positive_ratio(numerator: float, denominator: float, label: str) -> float:
    if denominator <= 0:
        raise ManifestError(f"{label} cannot establish a positive timing ratio")
    return numerator / denominator


def aggregate_timing(
    distributions: Sequence[dict[str, Any]], label: str
) -> dict[str, Any]:
    if len(distributions) != CONTROL_OBSERVATION_COUNT:
        raise ManifestError(f"{label} does not have three observations")
    counts = {distribution["sampleCount"] for distribution in distributions}
    if len(counts) != 1:
        raise ManifestError(f"{label} changed sample count")
    observations = [
        {
            "p50Milliseconds": item["p50Milliseconds"],
            "p95Milliseconds": item["p95Milliseconds"],
            "maximumMilliseconds": item["maximumMilliseconds"],
        }
        for item in distributions
    ]
    medians = [float(item["p50Milliseconds"]) for item in observations]
    p95_values = [float(item["p95Milliseconds"]) for item in observations]
    maxima = [float(item["maximumMilliseconds"]) for item in observations]
    within = [
        positive_ratio(p95, median, f"{label} within-observation")
        for median, p95 in zip(medians, p95_values, strict=True)
    ]
    across = positive_ratio(
        max(p95_values), min(p95_values), f"{label} across-observation"
    )
    return {
        "sampleCountPerObservation": counts.pop(),
        "observations": observations,
        "p50Milliseconds": observation_summary(medians),
        "p95Milliseconds": observation_summary(p95_values),
        "maximumMilliseconds": observation_summary(maxima),
        "p95ToP50Ratio": observation_summary(within),
        "acrossObservationP95MaximumToMinimumRatio": across,
    }


def aggregate_bytes(distributions: Sequence[dict[str, Any]], label: str) -> dict[str, Any]:
    if len(distributions) != CONTROL_OBSERVATION_COUNT:
        raise ManifestError(f"{label} does not have three observations")
    counts = {distribution["sampleCount"] for distribution in distributions}
    if len(counts) != 1:
        raise ManifestError(f"{label} changed sample count")
    observations = [
        {
            "p50Bytes": item["p50Bytes"],
            "p95Bytes": item["p95Bytes"],
            "maximumBytes": item["maximumBytes"],
        }
        for item in distributions
    ]
    return {
        "sampleCountPerObservation": counts.pop(),
        "observations": observations,
        "p50Bytes": observation_summary([item["p50Bytes"] for item in observations]),
        "p95Bytes": observation_summary([item["p95Bytes"] for item in observations]),
        "maximumBytes": observation_summary(
            [item["maximumBytes"] for item in observations]
        ),
    }


def baseline_scope(configuration: dict[str, Any]) -> str:
    variants = configuration["queryVariants"]
    expected = {**CANONICAL_CONFIGURATION, "queryVariants": variants}
    if configuration != expected or variants not in {1, 3}:
        raise ManifestError("control baseline configuration is unsupported")
    return "canonical-current-control" if variants == 1 else "three-variant-diagnostic"


def aggregate_control_checkpoint(
    checkpoints: Sequence[dict[str, Any]],
    scope: str,
) -> dict[str, Any]:
    first = checkpoints[0]
    scalar_keys = (
        "totalSegments",
        "meetingCount",
        "rawEmbeddingBytes",
        "resultCount",
        "firstQueryIndex",
    )
    for key in scalar_keys:
        if len({item[key] for item in checkpoints}) != 1:
            raise ManifestError(f"control checkpoint changed {key}")

    stages: dict[str, Any] = {}
    for stage_name in sorted(STAGE_TIMINGS_KEYS):
        stages[stage_name] = {
            "wallTime": aggregate_timing(
                [item["stageTimings"][stage_name]["wallTime"] for item in checkpoints],
                f"{first['totalSegments']} {stage_name} wall",
            ),
            "processCPUTime": aggregate_timing(
                [
                    item["stageTimings"][stage_name]["processCPUTime"]
                    for item in checkpoints
                ],
                f"{first['totalSegments']} {stage_name} CPU",
            ),
        }

    measured = stages["measuredQueries"]
    wall = measured["wallTime"]
    cpu = measured["processCPUTime"]
    stability = {
        "state": "stable",
        "maximumAllowedRatio": MAXIMUM_TIMING_RATIO,
        "wallMaximumWithinObservationRatio": wall["p95ToP50Ratio"]["maximum"],
        "cpuMaximumWithinObservationRatio": cpu["p95ToP50Ratio"]["maximum"],
        "wallAcrossObservationRatio": wall[
            "acrossObservationP95MaximumToMinimumRatio"
        ],
        "cpuAcrossObservationRatio": cpu[
            "acrossObservationP95MaximumToMinimumRatio"
        ],
    }
    ratios = [value for key, value in stability.items() if key.endswith("Ratio")]
    if any(value > MAXIMUM_TIMING_RATIO for value in ratios):
        raise ManifestError(
            f"measured-query timing is unstable at {first['totalSegments']} segments"
        )

    applicable = first["totalSegments"] == 100_000
    wall_p95 = wall["p95Milliseconds"]["p95"] if applicable else None
    cpu_p95 = cpu["p95Milliseconds"]["p95"] if applicable else None
    under_budget = bool(
        applicable
        and wall_p95 <= HUNDRED_THOUSAND_BUDGET_MILLISECONDS
        and cpu_p95 <= HUNDRED_THOUSAND_BUDGET_MILLISECONDS
    )
    if not applicable:
        budget_status = "not-applicable"
    elif scope == "canonical-current-control":
        budget_status = "pass" if under_budget else "fail"
    else:
        budget_status = "diagnostic-under-target" if under_budget else "diagnostic-over-target"

    footprint = {
        key: aggregate_bytes(
            [item[key] for item in checkpoints],
            f"{first['totalSegments']} {key}",
        )
        for key in (
            "baselinePhysicalFootprint",
            "peakPhysicalFootprint",
            "incrementalPeakPhysicalFootprint",
            "endingPhysicalFootprint",
        )
    }
    return {
        **{key: first[key] for key in scalar_keys},
        "databaseBytes": observation_summary(
            [item["databaseBytes"] for item in checkpoints]
        ),
        "stageTimings": stages,
        "footprint": footprint,
        "measuredQueryStability": stability,
        "budget": {
            "maximumMilliseconds": (
                HUNDRED_THOUSAND_BUDGET_MILLISECONDS if applicable else None
            ),
            "wallP95Milliseconds": wall_p95,
            "cpuP95Milliseconds": cpu_p95,
            "status": budget_status,
        },
    }


def build_control_baseline(
    documents: Sequence[Any], generated_at: str
) -> dict[str, Any]:
    if len(documents) != CONTROL_OBSERVATION_COUNT:
        raise ManifestError(
            f"control baseline requires exactly {CONTROL_OBSERVATION_COUNT} manifests"
        )
    manifests = [
        validate_manifest(document, f"control input {index}")
        for index, document in enumerate(documents)
    ]
    manifests.sort(key=lambda item: item["generatedAt"])
    if len({item["generatedAt"] for item in manifests}) != CONTROL_OBSERVATION_COUNT:
        raise ManifestError("control baseline requires unique observation timestamps")
    digests = [hashlib.sha256(canonical_json(item)).hexdigest() for item in manifests]
    if len(set(digests)) != CONTROL_OBSERVATION_COUNT:
        raise ManifestError("control baseline contains a copied observation")
    measurement_digests = [
        hashlib.sha256(canonical_json(item["checkpoints"])).hexdigest()
        for item in manifests
    ]
    if len(set(measurement_digests)) != CONTROL_OBSERVATION_COUNT:
        raise ManifestError("control baseline requires distinct measurement payloads")
    identities = {
        item["comparability"]["identitySHA256"] for item in manifests
    }
    if len(identities) != 1:
        raise ManifestError("control baseline comparability identity changed")
    if any(not item["source"]["worktreeClean"] for item in manifests):
        raise ManifestError("control baseline requires clean source observations")

    first = manifests[0]
    scope = baseline_scope(first["configuration"])
    scales = tuple(item["totalSegments"] for item in first["checkpoints"])
    if scales != CANONICAL_SCALES:
        raise ManifestError("control baseline requires canonical scales")
    expected_reasons = [] if scope == "canonical-current-control" else [
        "noncanonical-configuration"
    ]
    for item in manifests:
        if item["configuration"] != first["configuration"]:
            raise ManifestError("control baseline configuration changed")
        if item["comparability"]["reasons"] != expected_reasons:
            raise ManifestError("control baseline comparability scope is inconsistent")
        expected_comparability = (
            ("canonical", True)
            if scope == "canonical-current-control"
            else ("custom", False)
        )
        actual_comparability = (
            item["comparability"]["measurementScope"],
            item["comparability"]["retentionEligible"],
        )
        if actual_comparability != expected_comparability:
            raise ManifestError("control baseline retention state is inconsistent")

    checkpoints = []
    for index, scale in enumerate(CANONICAL_SCALES):
        selected = [item["checkpoints"][index] for item in manifests]
        if any(item["totalSegments"] != scale for item in selected):
            raise ManifestError("control baseline scale order changed")
        checkpoints.append(
            aggregate_control_checkpoint(selected, scope)
        )

    budget_status = checkpoints[-1]["budget"]["status"]
    if scope == "canonical-current-control":
        outcome = (
            "current-control-budget-pass"
            if budget_status == "pass"
            else "current-control-budget-fail"
        )
        reasons = [] if budget_status == "pass" else ["hundred-thousand-budget-miss"]
        budget_authority = "one-host-current-control"
    else:
        outcome = "stable-three-variant-diagnostic"
        reasons = ["three-query-variant-diagnostic-only"]
        budget_authority = "none"

    baseline = {
        "schemaVersion": 1,
        "kind": CONTROL_BASELINE_KIND,
        "generatedAt": validate_timestamp(generated_at, "generatedAt"),
        "identity": {
            "sha256": identities.pop(),
            "payload": identity_payload(first),
        },
        "collection": {
            "observationCount": CONTROL_OBSERVATION_COUNT,
            "observationSHA256": digests,
            "measurementSHA256": measurement_digests,
            "startedAt": manifests[0]["generatedAt"],
            "finishedAt": manifests[-1]["generatedAt"],
        },
        "scope": scope,
        "policy": {
            "version": "semantic-measured-query-stability-v1",
            "requiredObservations": CONTROL_OBSERVATION_COUNT,
            "maximumTimingRatio": MAXIMUM_TIMING_RATIO,
            "evaluatedStage": "measuredQueries",
            "diagnosticStages": ["storeOpen", "corpusSeed", "warmupQueries"],
            "budgetSegments": 100_000,
            "budgetMaximumMilliseconds": HUNDRED_THOUSAND_BUDGET_MILLISECONDS,
        },
        "authority": {
            "currentControlBudget": budget_authority,
            "crossHost": "none",
            "retrievalQuality": "none",
            "answerQuality": "none",
            "engineSelection": "none",
        },
        "checkpoints": checkpoints,
        "outcome": outcome,
        "reasons": reasons,
    }
    baseline["receiptSHA256"] = control_receipt_sha256(baseline)
    validate_control_baseline(baseline, "built control baseline")
    return baseline


def validate_observation_summary(
    value: Any, label: str, *, integer: bool = False
) -> dict[str, Any]:
    summary = exact_object(value, OBSERVATION_SUMMARY_KEYS, label)
    if exact_int(
        summary["sampleCount"], f"{label}.sampleCount", minimum=1
    ) != CONTROL_OBSERVATION_COUNT:
        raise ManifestError(f"{label}.sampleCount is not three")
    parser = exact_int if integer else finite_number
    parsed = [
        parser(summary[key], f"{label}.{key}")
        for key in ("minimum", "p50", "p95", "maximum")
    ]
    if parsed != sorted(parsed):
        raise ManifestError(f"{label} is not monotonic")
    if summary["p95"] != summary["maximum"]:
        raise ManifestError(f"{label}.p95 is not the nearest-rank maximum")
    return summary


def validate_timing_aggregate(value: Any, label: str) -> dict[str, Any]:
    aggregate = exact_object(value, TIMING_AGGREGATE_KEYS, label)
    exact_int(
        aggregate["sampleCountPerObservation"],
        f"{label}.sampleCountPerObservation",
        minimum=1,
    )
    observations = aggregate["observations"]
    if not isinstance(observations, list) or len(observations) != CONTROL_OBSERVATION_COUNT:
        raise ManifestError(f"{label}.observations are incomplete")
    medians: list[float] = []
    p95_values: list[float] = []
    maxima: list[float] = []
    ratios: list[float] = []
    for index, value in enumerate(observations):
        observation = exact_object(
            value,
            {"p50Milliseconds", "p95Milliseconds", "maximumMilliseconds"},
            f"{label}.observations[{index}]",
        )
        median = finite_number(
            observation["p50Milliseconds"],
            f"{label}.observations[{index}].p50Milliseconds",
        )
        p95 = finite_number(
            observation["p95Milliseconds"],
            f"{label}.observations[{index}].p95Milliseconds",
        )
        maximum = finite_number(
            observation["maximumMilliseconds"],
            f"{label}.observations[{index}].maximumMilliseconds",
        )
        if not median <= p95 <= maximum:
            raise ManifestError(f"{label}.observations[{index}] is not monotonic")
        medians.append(median)
        p95_values.append(p95)
        maxima.append(maximum)
        ratios.append(
            positive_ratio(p95, median, f"{label}.observations[{index}]")
        )
    expected_summaries = {
        "p50Milliseconds": observation_summary(medians),
        "p95Milliseconds": observation_summary(p95_values),
        "maximumMilliseconds": observation_summary(maxima),
        "p95ToP50Ratio": observation_summary(ratios),
    }
    for key, expected in expected_summaries.items():
        validate_observation_summary(aggregate[key], f"{label}.{key}")
        if aggregate[key] != expected:
            raise ManifestError(f"{label}.{key} is not recomputable")
    expected_across = positive_ratio(
        max(p95_values), min(p95_values), f"{label} aggregate"
    )
    if aggregate["acrossObservationP95MaximumToMinimumRatio"] != expected_across:
        raise ManifestError(f"{label} across-observation ratio is inconsistent")
    return aggregate


def validate_byte_aggregate(value: Any, label: str) -> dict[str, Any]:
    aggregate = exact_object(value, BYTE_AGGREGATE_KEYS, label)
    exact_int(
        aggregate["sampleCountPerObservation"],
        f"{label}.sampleCountPerObservation",
        minimum=1,
    )
    observations = aggregate["observations"]
    if not isinstance(observations, list) or len(observations) != CONTROL_OBSERVATION_COUNT:
        raise ManifestError(f"{label}.observations are incomplete")
    values = {"p50Bytes": [], "p95Bytes": [], "maximumBytes": []}
    for index, value in enumerate(observations):
        observation = exact_object(
            value, {"p50Bytes", "p95Bytes", "maximumBytes"},
            f"{label}.observations[{index}]",
        )
        parsed = [
            exact_int(
                observation[key], f"{label}.observations[{index}].{key}"
            )
            for key in ("p50Bytes", "p95Bytes", "maximumBytes")
        ]
        if parsed != sorted(parsed):
            raise ManifestError(f"{label}.observations[{index}] is not monotonic")
        for key, item in zip(values, parsed, strict=True):
            values[key].append(item)
    for key, items in values.items():
        expected = observation_summary(items)
        validate_observation_summary(aggregate[key], f"{label}.{key}", integer=True)
        if aggregate[key] != expected:
            raise ManifestError(f"{label}.{key} is not recomputable")
    return aggregate


def control_receipt_sha256(value: dict[str, Any]) -> str:
    payload = {key: item for key, item in value.items() if key != "receiptSHA256"}
    return hashlib.sha256(canonical_json(payload)).hexdigest()


def validate_control_baseline(value: Any, label: str) -> dict[str, Any]:
    baseline = exact_object(value, CONTROL_BASELINE_KEYS, label)
    if exact_int(baseline["schemaVersion"], f"{label}.schemaVersion", minimum=1) != 1:
        raise ManifestError(f"{label}.schemaVersion is not one")
    if baseline["kind"] != CONTROL_BASELINE_KIND:
        raise ManifestError(f"{label}.kind is invalid")
    generated = validate_timestamp(
        baseline["generatedAt"], f"{label}.generatedAt"
    )
    bounded_string(
        baseline["receiptSHA256"],
        f"{label}.receiptSHA256",
        pattern=HEX_64,
        maximum=64,
    )
    identity = exact_object(baseline["identity"], {"sha256", "payload"}, f"{label}.identity")
    bounded_string(identity["sha256"], f"{label}.identity.sha256", pattern=HEX_64, maximum=64)
    payload = exact_object(
        identity["payload"],
        {
            "source", "binary", "toolchain", "host", "buildConfiguration",
            "configuration", "semanticProfile", "semanticAssets", "fixture",
            "queryPack", "stagePolicy", "scales",
        },
        f"{label}.identity.payload",
    )
    validate_source(payload["source"], f"{label}.identity.payload.source")
    if not payload["source"]["worktreeClean"]:
        raise ManifestError(f"{label} source is not clean")
    binary = exact_object(
        payload["binary"], BINARY_KEYS, f"{label}.identity.payload.binary"
    )
    bounded_string(
        binary["sha256"],
        f"{label}.identity.payload.binary.sha256",
        pattern=HEX_64,
        maximum=64,
    )
    exact_int(
        binary["sizeBytes"], f"{label}.identity.payload.binary.sizeBytes", minimum=1
    )
    toolchain = exact_object(
        payload["toolchain"], TOOLCHAIN_KEYS, f"{label}.identity.payload.toolchain"
    )
    for key in TOOLCHAIN_KEYS:
        bounded_string(toolchain[key], f"{label}.identity.payload.toolchain.{key}")
    validate_host(payload["host"], f"{label}.identity.payload.host", snapshot=True)
    if payload["buildConfiguration"] != "release":
        raise ManifestError(f"{label}.identity.payload is not Release")
    configuration = validate_configuration(
        payload["configuration"], f"{label}.identity.payload.configuration"
    )
    profile = validate_profile(
        payload["semanticProfile"], f"{label}.identity.payload.semanticProfile"
    )
    if profile["vectorDimension"] != configuration["embeddingDimension"]:
        raise ManifestError(f"{label}.identity.payload dimensions differ")
    validate_assets(
        payload["semanticAssets"], f"{label}.identity.payload.semanticAssets"
    )
    validate_fixture(payload["fixture"], f"{label}.identity.payload.fixture")
    query_pack = exact_object(
        payload["queryPack"],
        MANIFEST_QUERY_PACK_KEYS,
        f"{label}.identity.payload.queryPack",
    )
    if query_pack != {
        "version": "semantic-present-vector-queries-v1",
        "selectionPolicy": "midpoint-consecutive-wrap-v1",
        "queryVariants": configuration["queryVariants"],
        "resultLimit": configuration["resultLimit"],
    }:
        raise ManifestError(f"{label}.identity.payload.queryPack is inconsistent")
    stage_policy = exact_object(
        payload["stagePolicy"],
        STAGE_POLICY_KEYS,
        f"{label}.identity.payload.stagePolicy",
    )
    if stage_policy != {
        "version": "semantic-scale-stages-v1",
        "wallClock": "continuous-clock",
        "processCPU": "rusage-user-plus-system",
        "percentile": "nearest-rank-v1",
    }:
        raise ManifestError(f"{label}.identity.payload.stagePolicy is inconsistent")
    scope = baseline_scope(payload["configuration"])
    if baseline["scope"] != scope:
        raise ManifestError(f"{label}.scope is inconsistent")
    if payload["scales"] != list(CANONICAL_SCALES):
        raise ManifestError(f"{label} scales are not canonical")
    if identity["sha256"] != hashlib.sha256(canonical_json(payload)).hexdigest():
        raise ManifestError(f"{label}.identity.sha256 is not recomputable")

    collection = exact_object(
        baseline["collection"],
        {
            "observationCount",
            "observationSHA256",
            "measurementSHA256",
            "startedAt",
            "finishedAt",
        },
        f"{label}.collection",
    )
    if exact_int(
        collection["observationCount"],
        f"{label}.collection.observationCount",
        minimum=1,
    ) != CONTROL_OBSERVATION_COUNT:
        raise ManifestError(f"{label}.collection count is not three")
    for digest_key in ("observationSHA256", "measurementSHA256"):
        digests = collection[digest_key]
        if not isinstance(digests, list) or len(digests) != CONTROL_OBSERVATION_COUNT:
            raise ManifestError(f"{label}.collection.{digest_key} is incomplete")
        for index, digest in enumerate(digests):
            bounded_string(
                digest,
                f"{label}.collection.{digest_key}[{index}]",
                pattern=HEX_64,
                maximum=64,
            )
        if len(set(digests)) != CONTROL_OBSERVATION_COUNT:
            raise ManifestError(f"{label}.collection.{digest_key} is not unique")
    started = validate_timestamp(
        collection["startedAt"], f"{label}.collection.startedAt"
    )
    finished = validate_timestamp(
        collection["finishedAt"], f"{label}.collection.finishedAt"
    )
    started_at = dt.datetime.fromisoformat(started.removesuffix("Z") + "+00:00")
    finished_at = dt.datetime.fromisoformat(finished.removesuffix("Z") + "+00:00")
    generated_at = dt.datetime.fromisoformat(generated.removesuffix("Z") + "+00:00")
    if started_at >= finished_at:
        raise ManifestError(f"{label}.collection timestamps are not ordered")
    if generated_at < finished_at:
        raise ManifestError(f"{label}.generatedAt predates collection completion")

    expected_policy = {
        "version": "semantic-measured-query-stability-v1",
        "requiredObservations": CONTROL_OBSERVATION_COUNT,
        "maximumTimingRatio": MAXIMUM_TIMING_RATIO,
        "evaluatedStage": "measuredQueries",
        "diagnosticStages": ["storeOpen", "corpusSeed", "warmupQueries"],
        "budgetSegments": 100_000,
        "budgetMaximumMilliseconds": HUNDRED_THOUSAND_BUDGET_MILLISECONDS,
    }
    if baseline["policy"] != expected_policy:
        raise ManifestError(f"{label}.policy is not canonical")
    expected_budget_authority = (
        "one-host-current-control" if scope == "canonical-current-control" else "none"
    )
    expected_authority = {
        "currentControlBudget": expected_budget_authority,
        "crossHost": "none",
        "retrievalQuality": "none",
        "answerQuality": "none",
        "engineSelection": "none",
    }
    if baseline["authority"] != expected_authority:
        raise ManifestError(f"{label}.authority is inconsistent")

    checkpoints = baseline["checkpoints"]
    if not isinstance(checkpoints, list) or len(checkpoints) != len(CANONICAL_SCALES):
        raise ManifestError(f"{label}.checkpoints are incomplete")
    for index, (checkpoint, scale) in enumerate(zip(checkpoints, CANONICAL_SCALES, strict=True)):
        item_label = f"{label}.checkpoints[{index}]"
        item = exact_object(checkpoint, CONTROL_CHECKPOINT_KEYS, item_label)
        if exact_int(
            item["totalSegments"], f"{item_label}.totalSegments", minimum=1
        ) != scale:
            raise ManifestError(f"{item_label}.totalSegments is inconsistent")
        expected_scalars = {
            "meetingCount": math.ceil(scale / configuration["segmentsPerMeeting"]),
            "rawEmbeddingBytes": scale * configuration["embeddingDimension"] * 4,
            "resultCount": min(scale, configuration["resultLimit"]),
            "firstQueryIndex": scale // 2,
        }
        for key, expected in expected_scalars.items():
            if exact_int(item[key], f"{item_label}.{key}", minimum=0) != expected:
                raise ManifestError(f"{item_label}.{key} is inconsistent")
        validate_observation_summary(
            item["databaseBytes"], f"{item_label}.databaseBytes", integer=True
        )
        stages = exact_object(
            item["stageTimings"], STAGE_TIMINGS_KEYS, f"{item_label}.stageTimings"
        )
        for stage_name in STAGE_TIMINGS_KEYS:
            stage = exact_object(stages[stage_name], STAGE_KEYS, f"{item_label}.{stage_name}")
            expected_count = {
                "storeOpen": 1,
                "corpusSeed": 1,
                "warmupQueries": configuration["warmupRuns"],
                "measuredQueries": configuration["measurementRuns"],
            }[stage_name]
            for clock in ("wallTime", "processCPUTime"):
                aggregate = validate_timing_aggregate(
                    stage[clock], f"{item_label}.{stage_name}.{clock}"
                )
                if aggregate["sampleCountPerObservation"] != expected_count:
                    raise ManifestError(
                        f"{item_label}.{stage_name}.{clock} sample count changed"
                    )
        measured = stages["measuredQueries"]
        stability = exact_object(
            item["measuredQueryStability"],
            {
                "state", "maximumAllowedRatio", "wallMaximumWithinObservationRatio",
                "cpuMaximumWithinObservationRatio", "wallAcrossObservationRatio",
                "cpuAcrossObservationRatio",
            },
            f"{item_label}.measuredQueryStability",
        )
        if (
            stability["state"] != "stable"
            or stability["maximumAllowedRatio"] != MAXIMUM_TIMING_RATIO
        ):
            raise ManifestError(f"{item_label} is not stably measured")
        expected_ratios = {
            "wallMaximumWithinObservationRatio": measured["wallTime"][
                "p95ToP50Ratio"
            ]["maximum"],
            "cpuMaximumWithinObservationRatio": measured["processCPUTime"][
                "p95ToP50Ratio"
            ]["maximum"],
            "wallAcrossObservationRatio": measured["wallTime"][
                "acrossObservationP95MaximumToMinimumRatio"
            ],
            "cpuAcrossObservationRatio": measured["processCPUTime"][
                "acrossObservationP95MaximumToMinimumRatio"
            ],
        }
        for key, expected in expected_ratios.items():
            if stability[key] != expected or expected > MAXIMUM_TIMING_RATIO:
                raise ManifestError(f"{item_label}.{key} is inconsistent")
        footprint = exact_object(
            item["footprint"],
            {
                "baselinePhysicalFootprint", "peakPhysicalFootprint",
                "incrementalPeakPhysicalFootprint", "endingPhysicalFootprint",
            },
            f"{item_label}.footprint",
        )
        for key, aggregate in footprint.items():
            byte_summary = validate_byte_aggregate(
                aggregate, f"{item_label}.{key}"
            )
            if exact_int(
                byte_summary["sampleCountPerObservation"],
                f"{item_label}.{key}.sampleCount",
                minimum=1,
            ) != configuration["measurementRuns"]:
                raise ManifestError(f"{item_label}.{key} sample count changed")
        budget = exact_object(
            item["budget"],
            {"maximumMilliseconds", "wallP95Milliseconds", "cpuP95Milliseconds", "status"},
            f"{item_label}.budget",
        )
        if scale != 100_000:
            if budget != {
                "maximumMilliseconds": None,
                "wallP95Milliseconds": None,
                "cpuP95Milliseconds": None,
                "status": "not-applicable",
            }:
                raise ManifestError(f"{item_label}.budget must be not-applicable")
        else:
            wall_p95 = measured["wallTime"]["p95Milliseconds"]["p95"]
            cpu_p95 = measured["processCPUTime"]["p95Milliseconds"]["p95"]
            under = (
                wall_p95 <= HUNDRED_THOUSAND_BUDGET_MILLISECONDS
                and cpu_p95 <= HUNDRED_THOUSAND_BUDGET_MILLISECONDS
            )
            expected_status = (
                ("pass" if under else "fail")
                if scope == "canonical-current-control"
                else ("diagnostic-under-target" if under else "diagnostic-over-target")
            )
            if budget != {
                "maximumMilliseconds": HUNDRED_THOUSAND_BUDGET_MILLISECONDS,
                "wallP95Milliseconds": wall_p95,
                "cpuP95Milliseconds": cpu_p95,
                "status": expected_status,
            }:
                raise ManifestError(f"{item_label}.budget is inconsistent")

    last_status = checkpoints[-1]["budget"]["status"]
    if scope == "canonical-current-control":
        expected_outcome = (
            "current-control-budget-pass"
            if last_status == "pass"
            else "current-control-budget-fail"
        )
        expected_reasons = [] if last_status == "pass" else ["hundred-thousand-budget-miss"]
    else:
        expected_outcome = "stable-three-variant-diagnostic"
        expected_reasons = ["three-query-variant-diagnostic-only"]
    if baseline["outcome"] != expected_outcome or baseline["reasons"] != expected_reasons:
        raise ManifestError(f"{label}.outcome is inconsistent")
    if baseline["receiptSHA256"] != control_receipt_sha256(baseline):
        raise ManifestError(f"{label}.receiptSHA256 is not recomputable")
    return baseline


def write_json(path: Path | None, value: Any) -> None:
    payload = json.dumps(value, indent=2, sort_keys=True, ensure_ascii=False) + "\n"
    if path is None:
        sys.stdout.write(payload)
        return
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        descriptor, temporary_name = tempfile.mkstemp(
            prefix=path.name + ".", suffix=".tmp", dir=path.parent
        )
        temporary = Path(temporary_name)
        try:
            os.fchmod(descriptor, 0o600)
            with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
                stream.write(payload)
                stream.flush()
                os.fsync(stream.fileno())
            temporary.replace(path)
        finally:
            if temporary.exists():
                temporary.unlink()
    except OSError as error:
        raise ManifestError("cannot publish semantic manifest") from error


def utc_now() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z")


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)

    source = commands.add_parser("source")
    source.add_argument("--root", type=Path, required=True)
    source.add_argument("--output", type=Path, required=True)

    snapshot = commands.add_parser("snapshot")
    snapshot.add_argument("--root", type=Path, required=True)
    snapshot.add_argument("--binary", type=Path, required=True)
    snapshot.add_argument("--build-wall-ms", type=float, required=True)
    snapshot.add_argument("--expected-source", type=Path, required=True)
    snapshot.add_argument("--output", type=Path, required=True)

    assemble = commands.add_parser("assemble")
    assemble.add_argument("--root", type=Path, required=True)
    assemble.add_argument("--binary", type=Path, required=True)
    assemble.add_argument("--snapshot", type=Path, required=True)
    assemble.add_argument("--parts", type=Path, required=True)
    assemble.add_argument("--generated-at", default=None)
    assemble.add_argument("--output", type=Path, required=True)

    compare = commands.add_parser("compare")
    compare.add_argument("inputs", nargs="+", type=Path)
    compare.add_argument("--generated-at", default=None)
    compare.add_argument("--output", type=Path)

    baseline = commands.add_parser("baseline")
    baseline.add_argument("inputs", nargs="+", type=Path)
    baseline.add_argument("--generated-at", default=None)
    baseline.add_argument("--output", type=Path, required=True)
    return parser.parse_args()


def main() -> int:
    options = parse_arguments()
    try:
        if options.command == "source":
            write_json(options.output, collect_source(options.root))
            return 0
        if options.command == "snapshot":
            if not math.isfinite(options.build_wall_ms) or options.build_wall_ms < 0:
                raise ManifestError("build wall time must be finite and nonnegative")
            expected_source = validate_source(
                read_json(options.expected_source, "pre-build source"),
                "pre-build source",
            )
            write_json(
                options.output,
                collect_snapshot(
                    options.root,
                    options.binary,
                    options.build_wall_ms,
                    expected_source=expected_source,
                ),
            )
            return 0
        if options.command == "assemble":
            snapshot = validate_snapshot(
                read_json(options.snapshot, "identity snapshot"), "identity snapshot"
            )
            current = collect_snapshot(
                options.root,
                options.binary,
                snapshot["releaseBuild"]["wallMilliseconds"],
                expected_source=snapshot["source"],
            )
            if current != snapshot:
                raise ManifestError("source, binary, toolchain, or host changed during collection")
            paths = sorted(
                (
                    path
                    for path in options.parts.glob("*.json")
                    if path.resolve() != options.snapshot.resolve()
                ),
                key=lambda path: path.name,
            )
            reports = [read_json(path, f"checkpoint {path.name}") for path in paths]
            manifest = assemble_manifest(snapshot, reports, options.generated_at or utc_now())
            write_json(options.output, manifest)
            return 0
        documents = [
            read_json(path, f"comparison input {index}")
            for index, path in enumerate(options.inputs)
        ]
        if options.command == "baseline":
            write_json(
                options.output,
                build_control_baseline(documents, options.generated_at or utc_now()),
            )
            return 0
        write_json(
            options.output,
            compare_documents(documents, options.generated_at or utc_now()),
        )
        return 0
    except ManifestError as error:
        print(f"semantic-scale-manifest error: {error}", file=sys.stderr)
        return 64


if __name__ == "__main__":
    raise SystemExit(main())
