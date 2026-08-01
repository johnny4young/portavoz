#!/usr/bin/env python3
"""Validate and summarize privacy-safe Portavoz resource baseline receipts."""

from __future__ import annotations

import argparse
import json
import math
import os
import platform
import re
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path


SCHEMA_VERSION = 1
DEFAULT_CONTRACT = (
    Path(__file__).resolve().parents[1]
    / "docs"
    / "evidence"
    / "resource-baseline-matrix.json"
)
WORKLOAD_CLASSES = {
    "recordingCritical",
    "liveInteractive",
    "userInitiated",
    "postCapture",
    "maintenance",
}
WORKLOAD_KINDS = {
    "audioCapture",
    "liveTranscription",
    "qualityTranscription",
    "speakerDiarization",
    "languageInference",
    "searchIndex",
    "librarySync",
    "waveform",
    "uiProjection",
    "mediaExport",
    "supportExport",
}
WORKLOAD_OPERATIONS = {"queueWait", "execute", "prepare", "load", "release"}
WORKLOAD_OUTCOMES = {"completed", "cancelled", "failed"}
OBSERVATION_STATES = {"pass", "fail", "not-observed"}
THERMAL_STATES = {"nominal": 0, "fair": 1, "serious": 2, "critical": 3}
POWER_SOURCES = {"ac", "battery", "unknown"}
REQUIRED_PROFILES = {"memory-8gb", "memory-16gb", "reference"}
REQUIRED_SCENARIOS = {
    "idle",
    "recording",
    "stop",
    "refine",
    "summary",
    "ask",
    "indexing",
    "recording-indexing",
    "recording-batch",
}
VERSION_PATTERN = re.compile(r"^[A-Za-z0-9._+\-]{1,40}$")
BUILD_PATTERN = re.compile(r"^[A-Za-z0-9._+\-]{1,80}$")
COMMIT_PATTERN = re.compile(r"^[0-9a-f]{40}$")
SHA256_PATTERN = re.compile(r"^[0-9a-f]{64}$")
PROFILE_PATTERN = re.compile(r"^[a-z0-9][a-z0-9-]{0,39}$")
HARDWARE_PATTERN = re.compile(
    r"^(Mac|MacBookPro|MacBookAir|Macmini|MacStudio|iMac|MacPro)"
    r"[0-9]{1,2},[0-9]{1,2}$"
)
TIMESTAMP_PATTERN = re.compile(r"^[0-9T:.+\-Z]{10,64}$")
SWIFT_VERSION_PATTERN = re.compile(
    r"(?:Apple )?Swift version ([0-9]+(?:\.[0-9]+){1,2})"
)
ASK_PIPELINE_STAGES = {
    "corpusReadiness",
    "expansion",
    "lexicalQuery",
    "queryEmbedding",
    "semanticScan",
    "fusion",
    "citationFetch",
}


class ResourceBaselineError(ValueError):
    """A fail-closed resource-baseline validation error."""


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def object_shape(value, path, required, optional=()):
    if not isinstance(value, dict):
        raise ResourceBaselineError(f"{path} must be an object")
    required = set(required)
    allowed = required | set(optional)
    missing = required - value.keys()
    extra = value.keys() - allowed
    if missing:
        raise ResourceBaselineError(
            f"{path} is missing keys: {', '.join(sorted(missing))}"
        )
    if extra:
        raise ResourceBaselineError(
            f"{path} contains forbidden keys: {', '.join(sorted(extra))}"
        )
    return value


def safe_string(value, path, pattern):
    if not isinstance(value, str) or pattern.fullmatch(value) is None:
        raise ResourceBaselineError(f"{path} has an unsafe value")
    return value


def enum_value(value, path, allowed):
    if value not in allowed:
        raise ResourceBaselineError(
            f"{path} must be one of: {', '.join(sorted(allowed))}"
        )
    return value


def integer(value, path, minimum=0):
    if isinstance(value, bool) or not isinstance(value, int) or value < minimum:
        raise ResourceBaselineError(f"{path} must be an integer >= {minimum}")
    return value


def optional_integer(value, path, minimum=0):
    if value is None:
        return None
    return integer(value, path, minimum)


def number(value, path, minimum=0):
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise ResourceBaselineError(f"{path} must be numeric")
    value = float(value)
    if not math.isfinite(value):
        raise ResourceBaselineError(f"{path} must be finite")
    if value < minimum:
        raise ResourceBaselineError(f"{path} must be >= {minimum}")
    return value


def timestamp(value, path):
    value = safe_string(value, path, TIMESTAMP_PATTERN)
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as error:
        raise ResourceBaselineError(
            f"{path} must be an ISO-8601 timestamp"
        ) from error
    if parsed.utcoffset() is None:
        raise ResourceBaselineError(f"{path} must include a UTC offset")
    return value


def load_json(path, label, maximum_bytes=2 * 1024 * 1024):
    path = Path(path).expanduser()
    if not path.is_file():
        raise ResourceBaselineError(f"{label} not found: {path}")
    if path.stat().st_size > maximum_bytes:
        raise ResourceBaselineError(f"{label} exceeds the size limit")
    try:
        return json.loads(
            path.read_text(encoding="utf-8"),
            object_pairs_hook=reject_duplicate_keys,
        )
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ResourceBaselineError(f"{label} is not valid UTF-8 JSON") from error


def reject_duplicate_keys(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ResourceBaselineError(f"JSON contains duplicate key: {key}")
        result[key] = value
    return result


def write_json(path, payload):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(path.parent, 0o700)
    temporary = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    with temporary.open("w", encoding="utf-8") as handle:
        json.dump(payload, handle, indent=2, sort_keys=True)
        handle.write("\n")
    os.chmod(temporary, 0o600)
    os.replace(temporary, path)


def write_text(path, value):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(path.parent, 0o700)
    temporary = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    temporary.write_text(value, encoding="utf-8")
    os.chmod(temporary, 0o600)
    os.replace(temporary, path)


def workload_descriptor(raw, path):
    descriptor = object_shape(
        raw,
        path,
        ("workloadClass", "kind", "operation"),
    )
    workload_class = enum_value(
        descriptor["workloadClass"],
        f"{path}.workloadClass",
        WORKLOAD_CLASSES,
    )
    kind = enum_value(descriptor["kind"], f"{path}.kind", WORKLOAD_KINDS)
    operation = enum_value(
        descriptor["operation"],
        f"{path}.operation",
        WORKLOAD_OPERATIONS,
    )
    return workload_class, kind, operation


def validate_contract(document):
    contract = object_shape(
        document,
        "resource baseline contract",
        (
            "schemaVersion",
            "minimumStableSamples",
            "maximumTimingP95ToP50Ratio",
            "profiles",
            "scenarios",
        ),
    )
    if integer(contract["schemaVersion"], "contract.schemaVersion") != SCHEMA_VERSION:
        raise ResourceBaselineError(
            f"contract.schemaVersion must be {SCHEMA_VERSION}"
        )
    minimum_samples = integer(
        contract["minimumStableSamples"],
        "contract.minimumStableSamples",
        3,
    )
    maximum_timing_ratio = number(
        contract["maximumTimingP95ToP50Ratio"],
        "contract.maximumTimingP95ToP50Ratio",
        1,
    )
    if maximum_timing_ratio > 1.25:
        raise ResourceBaselineError(
            "contract.maximumTimingP95ToP50Ratio must be <= 1.25"
        )
    if not isinstance(contract["profiles"], list) or not contract["profiles"]:
        raise ResourceBaselineError("contract.profiles must be a non-empty array")
    if not isinstance(contract["scenarios"], list) or not contract["scenarios"]:
        raise ResourceBaselineError("contract.scenarios must be a non-empty array")

    profiles = {}
    for index, raw in enumerate(contract["profiles"]):
        path = f"contract.profiles[{index}]"
        profile = object_shape(
            raw,
            path,
            (
                "id",
                "minimumPhysicalMemoryBytes",
                "maximumPhysicalMemoryBytes",
            ),
        )
        identifier = safe_string(profile["id"], f"{path}.id", PROFILE_PATTERN)
        if identifier in profiles:
            raise ResourceBaselineError(
                f"contract repeats profile: {identifier}"
            )
        minimum = integer(
            profile["minimumPhysicalMemoryBytes"],
            f"{path}.minimumPhysicalMemoryBytes",
            1,
        )
        maximum = optional_integer(
            profile["maximumPhysicalMemoryBytes"],
            f"{path}.maximumPhysicalMemoryBytes",
            1,
        )
        if maximum is not None and maximum < minimum:
            raise ResourceBaselineError(
                f"{path}.maximumPhysicalMemoryBytes must be >= its minimum"
            )
        profiles[identifier] = {
            "minimum": minimum,
            "maximum": maximum,
        }
    if set(profiles) != REQUIRED_PROFILES:
        raise ResourceBaselineError(
            "contract profiles must be exactly: "
            + ", ".join(sorted(REQUIRED_PROFILES))
        )

    scenarios = {}
    for index, raw in enumerate(contract["scenarios"]):
        path = f"contract.scenarios[{index}]"
        scenario = object_shape(raw, path, ("id", "requiredWorkloads"))
        identifier = safe_string(scenario["id"], f"{path}.id", PROFILE_PATTERN)
        if identifier in scenarios:
            raise ResourceBaselineError(
                f"contract repeats scenario: {identifier}"
            )
        if not isinstance(scenario["requiredWorkloads"], list):
            raise ResourceBaselineError(
                f"{path}.requiredWorkloads must be an array"
            )
        descriptors = []
        for descriptor_index, descriptor in enumerate(
            scenario["requiredWorkloads"]
        ):
            parsed = workload_descriptor(
                descriptor,
                f"{path}.requiredWorkloads[{descriptor_index}]",
            )
            if parsed in descriptors:
                raise ResourceBaselineError(
                    f"{path} repeats required workload: {'/'.join(parsed)}"
                )
            descriptors.append(parsed)
        scenarios[identifier] = tuple(descriptors)
    if set(scenarios) != REQUIRED_SCENARIOS:
        raise ResourceBaselineError(
            "contract scenarios must be exactly: "
            + ", ".join(sorted(REQUIRED_SCENARIOS))
        )

    return {
        "minimumSamples": minimum_samples,
        "maximumTimingRatio": maximum_timing_ratio,
        "profiles": profiles,
        "scenarios": scenarios,
    }


def validate_build(raw, path):
    build = object_shape(
        raw,
        path,
        ("version", "build", "commit", "configuration"),
    )
    safe_string(build["version"], f"{path}.version", VERSION_PATTERN)
    safe_string(build["build"], f"{path}.build", BUILD_PATTERN)
    safe_string(build["commit"], f"{path}.commit", COMMIT_PATTERN)
    if build["configuration"] != "release":
        raise ResourceBaselineError(f"{path}.configuration must be release")
    return build


def validate_host(raw, path, contract):
    host = object_shape(
        raw,
        path,
        (
            "profile",
            "osVersion",
            "osBuild",
            "architecture",
            "physicalMemoryBytes",
            "hardwareModel",
        ),
    )
    profile = safe_string(host["profile"], f"{path}.profile", PROFILE_PATTERN)
    if profile not in contract["profiles"]:
        raise ResourceBaselineError(f"{path}.profile is not in the contract")
    safe_string(host["osVersion"], f"{path}.osVersion", VERSION_PATTERN)
    safe_string(host["osBuild"], f"{path}.osBuild", BUILD_PATTERN)
    if host["architecture"] != "arm64":
        raise ResourceBaselineError(f"{path}.architecture must be arm64")
    physical_memory = integer(
        host["physicalMemoryBytes"],
        f"{path}.physicalMemoryBytes",
        1,
    )
    safe_string(host["hardwareModel"], f"{path}.hardwareModel", HARDWARE_PATTERN)
    limits = contract["profiles"][profile]
    if physical_memory < limits["minimum"] or (
        limits["maximum"] is not None
        and physical_memory > limits["maximum"]
    ):
        raise ResourceBaselineError(
            f"{path}.physicalMemoryBytes does not match profile {profile}"
        )
    return host


def validate_toolchain(raw, path):
    toolchain = object_shape(
        raw,
        path,
        ("xcodeVersion", "xcodeBuild", "swiftVersion"),
    )
    safe_string(
        toolchain["xcodeVersion"],
        f"{path}.xcodeVersion",
        VERSION_PATTERN,
    )
    safe_string(toolchain["xcodeBuild"], f"{path}.xcodeBuild", BUILD_PATTERN)
    safe_string(
        toolchain["swiftVersion"],
        f"{path}.swiftVersion",
        VERSION_PATTERN,
    )
    return toolchain


def validate_duration_summary(raw, path):
    summary = object_shape(raw, path, ("p50", "p95", "maximum"))
    p50 = number(summary["p50"], f"{path}.p50")
    p95 = number(summary["p95"], f"{path}.p95")
    maximum = number(summary["maximum"], f"{path}.maximum")
    if p50 > p95 or p95 > maximum:
        raise ResourceBaselineError(f"{path} must satisfy p50 <= p95 <= maximum")
    return {"p50": p50, "p95": p95, "maximum": maximum}


def validate_ask_timing(raw, path):
    timing = object_shape(
        raw,
        path,
        ("wallDurationMilliseconds", "cpuTimeMilliseconds"),
    )
    return {
        "wallDurationMilliseconds": number(
            timing["wallDurationMilliseconds"],
            f"{path}.wallDurationMilliseconds",
        ),
        "cpuTimeMilliseconds": number(
            timing["cpuTimeMilliseconds"],
            f"{path}.cpuTimeMilliseconds",
        ),
    }


def validate_ask_pipeline_sample(raw, path):
    sample = object_shape(
        raw,
        path,
        (
            "schemaVersion",
            "run",
            "operation",
            "outcome",
            "total",
            "firstEvidence",
            "firstToken",
            "stages",
            "corpus",
            "citations",
        ),
    )
    if integer(sample["schemaVersion"], f"{path}.schemaVersion") != 2:
        raise ResourceBaselineError(f"{path}.schemaVersion must be 2")
    run = integer(sample["run"], f"{path}.run", 1)
    if sample["operation"] != "answer":
        raise ResourceBaselineError(f"{path}.operation must be answer")
    if sample["outcome"] != "completed":
        raise ResourceBaselineError(f"{path}.outcome must be completed")
    total = validate_ask_timing(sample["total"], f"{path}.total")
    first_evidence = validate_ask_timing(
        sample["firstEvidence"], f"{path}.firstEvidence"
    )
    first_token = validate_ask_timing(
        sample["firstToken"], f"{path}.firstToken"
    )
    for name, timing in (
        ("firstEvidence", first_evidence),
        ("firstToken", first_token),
    ):
        for metric in ("wallDurationMilliseconds", "cpuTimeMilliseconds"):
            if timing[metric] > total[metric]:
                raise ResourceBaselineError(
                    f"{path}.{name}.{metric} must not exceed total"
                )
    for metric in ("wallDurationMilliseconds", "cpuTimeMilliseconds"):
        if first_evidence[metric] > first_token[metric]:
            raise ResourceBaselineError(
                f"{path}.firstEvidence must not follow firstToken"
            )
    if not isinstance(sample["stages"], list):
        raise ResourceBaselineError(f"{path}.stages must be an array")
    stages = {}
    for index, raw_stage in enumerate(sample["stages"]):
        stage_path = f"{path}.stages[{index}]"
        stage = object_shape(
            raw_stage,
            stage_path,
            (
                "stage",
                "outcome",
                "wallDurationMilliseconds",
                "cpuTimeMilliseconds",
            ),
        )
        identifier = enum_value(
            stage["stage"], f"{stage_path}.stage", ASK_PIPELINE_STAGES
        )
        if identifier in stages:
            raise ResourceBaselineError(
                f"{path} repeats Ask stage: {identifier}"
            )
        if stage["outcome"] != "completed":
            raise ResourceBaselineError(
                f"{stage_path}.outcome must be completed"
            )
        stages[identifier] = {
            "wallDurationMilliseconds": number(
                stage["wallDurationMilliseconds"],
                f"{stage_path}.wallDurationMilliseconds",
            ),
            "cpuTimeMilliseconds": number(
                stage["cpuTimeMilliseconds"],
                f"{stage_path}.cpuTimeMilliseconds",
            ),
        }
    if set(stages) != ASK_PIPELINE_STAGES:
        missing = ASK_PIPELINE_STAGES - set(stages)
        extra = set(stages) - ASK_PIPELINE_STAGES
        details = []
        if missing:
            details.append("missing " + ", ".join(sorted(missing)))
        if extra:
            details.append("unexpected " + ", ".join(sorted(extra)))
        raise ResourceBaselineError(
            f"{path}.stages must be exact: {'; '.join(details)}"
        )

    corpus = object_shape(
        sample["corpus"],
        f"{path}.corpus",
        (
            "generation",
            "checksum",
            "fixtureSegmentCount",
            "pendingAtSeed",
            "pendingBefore",
            "pendingAfter",
            "readyBefore",
            "readyAfter",
            "warmup",
        ),
    )
    generation = safe_string(
        corpus["generation"], f"{path}.corpus.generation", PROFILE_PATTERN
    )
    checksum = safe_string(
        corpus["checksum"], f"{path}.corpus.checksum", SHA256_PATTERN
    )
    fixture_count = integer(
        corpus["fixtureSegmentCount"],
        f"{path}.corpus.fixtureSegmentCount",
        1,
    )
    pending_before = integer(
        corpus["pendingBefore"], f"{path}.corpus.pendingBefore"
    )
    pending_at_seed = integer(
        corpus["pendingAtSeed"], f"{path}.corpus.pendingAtSeed"
    )
    pending_after = integer(
        corpus["pendingAfter"], f"{path}.corpus.pendingAfter"
    )
    if not isinstance(corpus["readyBefore"], bool) or not isinstance(
        corpus["readyAfter"], bool
    ):
        raise ResourceBaselineError(
            f"{path}.corpus readiness fields must be booleans"
        )
    if (
        pending_at_seed != fixture_count
        or pending_before != 0
        or pending_after != 0
        or not corpus["readyBefore"]
        or not corpus["readyAfter"]
        or corpus["warmup"] != "preindexed"
    ):
        raise ResourceBaselineError(
            f"{path}.corpus must prove setup-only indexing and query-time readiness"
        )

    citations = object_shape(
        sample["citations"],
        f"{path}.citations",
        ("count", "digest", "valid"),
    )
    citation_count = integer(
        citations["count"], f"{path}.citations.count", 1
    )
    citation_digest = safe_string(
        citations["digest"], f"{path}.citations.digest", SHA256_PATTERN
    )
    if citations["valid"] is not True:
        raise ResourceBaselineError(f"{path}.citations.valid must be true")
    return run, {
        "total": total,
        "firstEvidence": first_evidence,
        "firstToken": first_token,
        "stages": stages,
        "corpus": {
            "generation": generation,
            "checksum": checksum,
            "fixtureSegmentCount": fixture_count,
            "warmup": "preindexed",
        },
        "citations": {
            "count": citation_count,
            "digest": citation_digest,
        },
    }


def validate_ask_pipeline(raw, path):
    pipeline = object_shape(raw, path, ("state", "samples"))
    state = enum_value(pipeline["state"], f"{path}.state", OBSERVATION_STATES)
    if not isinstance(pipeline["samples"], list):
        raise ResourceBaselineError(f"{path}.samples must be an array")
    runs = {}
    for index, raw_sample in enumerate(pipeline["samples"]):
        run, sample = validate_ask_pipeline_sample(
            raw_sample, f"{path}.samples[{index}]"
        )
        if run in runs:
            raise ResourceBaselineError(f"{path} repeats run: {run}")
        runs[run] = sample
    if state == "pass" and not runs:
        raise ResourceBaselineError(f"{path}.samples must not be empty")
    return {"state": state, "runs": runs}


def validate_workload_summary(raw, path):
    summary = object_shape(
        raw,
        path,
        (
            "workloadClass",
            "kind",
            "operation",
            "outcome",
            "count",
            "durationMilliseconds",
        ),
    )
    descriptor = workload_descriptor(
        {
            key: summary[key]
            for key in ("workloadClass", "kind", "operation")
        },
        path,
    )
    outcome = enum_value(
        summary["outcome"],
        f"{path}.outcome",
        WORKLOAD_OUTCOMES,
    )
    count = integer(summary["count"], f"{path}.count", 1)
    duration = validate_duration_summary(
        summary["durationMilliseconds"],
        f"{path}.durationMilliseconds",
    )
    return descriptor, outcome, count, duration


def validate_sample(raw, path):
    sample = object_shape(
        raw,
        path,
        (
            "run",
            "wallDurationMilliseconds",
            "cpuTimeMilliseconds",
            "peakPhysicalFootprintBytes",
            "energyNanojoules",
            "diskReadBytes",
            "diskWrittenBytes",
            "minimumAvailableDiskBytes",
            "maximumThermalState",
            "powerSource",
            "lowPowerModeEnabled",
            "workloads",
        ),
    )
    run = integer(sample["run"], f"{path}.run", 1)
    metrics = {
        "wallDurationMilliseconds": number(
            sample["wallDurationMilliseconds"],
            f"{path}.wallDurationMilliseconds",
        ),
        "cpuTimeMilliseconds": number(
            sample["cpuTimeMilliseconds"],
            f"{path}.cpuTimeMilliseconds",
        ),
        "peakPhysicalFootprintBytes": integer(
            sample["peakPhysicalFootprintBytes"],
            f"{path}.peakPhysicalFootprintBytes",
        ),
        "energyNanojoules": integer(
            sample["energyNanojoules"],
            f"{path}.energyNanojoules",
        ),
        "diskReadBytes": integer(
            sample["diskReadBytes"],
            f"{path}.diskReadBytes",
        ),
        "diskWrittenBytes": integer(
            sample["diskWrittenBytes"],
            f"{path}.diskWrittenBytes",
        ),
        "minimumAvailableDiskBytes": integer(
            sample["minimumAvailableDiskBytes"],
            f"{path}.minimumAvailableDiskBytes",
        ),
        "maximumThermalState": enum_value(
            sample["maximumThermalState"],
            f"{path}.maximumThermalState",
            THERMAL_STATES,
        ),
        "powerSource": enum_value(
            sample["powerSource"],
            f"{path}.powerSource",
            POWER_SOURCES,
        ),
    }
    if not isinstance(sample["lowPowerModeEnabled"], bool):
        raise ResourceBaselineError(
            f"{path}.lowPowerModeEnabled must be a boolean"
        )
    metrics["lowPowerModeEnabled"] = sample["lowPowerModeEnabled"]
    if not isinstance(sample["workloads"], list):
        raise ResourceBaselineError(f"{path}.workloads must be an array")
    if len(sample["workloads"]) > 200:
        raise ResourceBaselineError(f"{path}.workloads exceeds the 200-item limit")
    workloads = {}
    for index, raw_summary in enumerate(sample["workloads"]):
        workload_path = f"{path}.workloads[{index}]"
        descriptor, outcome, count, duration = validate_workload_summary(
            raw_summary,
            workload_path,
        )
        key = (*descriptor, outcome)
        if key in workloads:
            raise ResourceBaselineError(
                f"{path} repeats workload summary: {'/'.join(key)}"
            )
        workloads[key] = {
            "count": count,
            "durationMilliseconds": duration,
        }
    return run, metrics, workloads


def validate_scenario(raw, path, contract):
    scenario = object_shape(raw, path, ("id", "state", "samples"))
    identifier = safe_string(scenario["id"], f"{path}.id", PROFILE_PATTERN)
    if identifier not in contract["scenarios"]:
        raise ResourceBaselineError(f"{path}.id is not in the contract")
    state = enum_value(
        scenario["state"],
        f"{path}.state",
        OBSERVATION_STATES,
    )
    if not isinstance(scenario["samples"], list):
        raise ResourceBaselineError(f"{path}.samples must be an array")
    runs = {}
    for index, raw_sample in enumerate(scenario["samples"]):
        run, metrics, workloads = validate_sample(
            raw_sample,
            f"{path}.samples[{index}]",
        )
        if run in runs:
            raise ResourceBaselineError(f"{path} repeats run: {run}")
        runs[run] = {
            "metrics": metrics,
            "workloads": workloads,
        }
    if state == "pass":
        required = contract["scenarios"][identifier]
        for run, sample in runs.items():
            descriptors = {key[:3] for key in sample["workloads"]}
            missing = set(required) - descriptors
            if missing:
                rendered = ", ".join("/".join(value) for value in sorted(missing))
                raise ResourceBaselineError(
                    f"{path}.samples run {run} is missing workloads: {rendered}"
                )
    return identifier, state, runs


def validate_receipt(document, contract, label):
    receipt = object_shape(
        document,
        label,
        (
            "schemaVersion",
            "kind",
            "collectedAt",
            "build",
            "host",
            "toolchain",
            "scenarios",
        ),
        ("askPipeline",),
    )
    if integer(receipt["schemaVersion"], f"{label}.schemaVersion") != SCHEMA_VERSION:
        raise ResourceBaselineError(
            f"{label}.schemaVersion must be {SCHEMA_VERSION}"
        )
    if receipt["kind"] != "resource-baseline":
        raise ResourceBaselineError(f"{label}.kind must be resource-baseline")
    timestamp(receipt["collectedAt"], f"{label}.collectedAt")
    build = validate_build(receipt["build"], f"{label}.build")
    host = validate_host(receipt["host"], f"{label}.host", contract)
    toolchain = validate_toolchain(receipt["toolchain"], f"{label}.toolchain")
    if not isinstance(receipt["scenarios"], list):
        raise ResourceBaselineError(f"{label}.scenarios must be an array")
    scenarios = {}
    for index, raw_scenario in enumerate(receipt["scenarios"]):
        identifier, state, runs = validate_scenario(
            raw_scenario,
            f"{label}.scenarios[{index}]",
            contract,
        )
        if identifier in scenarios:
            raise ResourceBaselineError(
                f"{label} repeats scenario: {identifier}"
            )
        scenarios[identifier] = {"state": state, "runs": runs}
    ask_pipeline = None
    if "askPipeline" in receipt:
        ask_pipeline = validate_ask_pipeline(
            receipt["askPipeline"], f"{label}.askPipeline"
        )
    ask_scenario = scenarios.get("ask")
    if ask_scenario is not None and ask_scenario["state"] == "pass":
        if ask_pipeline is None:
            raise ResourceBaselineError(
                f"{label}.askPipeline is required for a passing Ask scenario"
            )
        if set(ask_scenario["runs"]) != set(ask_pipeline["runs"]):
            raise ResourceBaselineError(
                f"{label}.askPipeline runs must match Ask resource runs"
            )
    return {
        "build": dict(build),
        "host": dict(host),
        "toolchain": dict(toolchain),
        "scenarios": scenarios,
        "askPipeline": ask_pipeline,
    }


def nearest_rank(values, percentile):
    if not values:
        return None
    ordered = sorted(values)
    rank = max(1, math.ceil(percentile * len(ordered)))
    return ordered[rank - 1]


def summarize_runs(runs):
    samples = [run["metrics"] for _, run in sorted(runs.items())]
    numeric_metrics = (
        "wallDurationMilliseconds",
        "cpuTimeMilliseconds",
        "peakPhysicalFootprintBytes",
        "energyNanojoules",
        "diskReadBytes",
        "diskWrittenBytes",
    )
    summary = {}
    for metric in numeric_metrics:
        values = [sample[metric] for sample in samples]
        summary[metric] = {
            "p50": nearest_rank(values, 0.50),
            "p95": nearest_rank(values, 0.95),
            "maximum": max(values),
        }
    summary["minimumAvailableDiskBytes"] = min(
        sample["minimumAvailableDiskBytes"] for sample in samples
    )
    summary["maximumThermalState"] = max(
        (sample["maximumThermalState"] for sample in samples),
        key=THERMAL_STATES.__getitem__,
    )
    summary["powerSources"] = sorted({sample["powerSource"] for sample in samples})
    summary["lowPowerModeObserved"] = any(
        sample["lowPowerModeEnabled"] for sample in samples
    )
    return summary


def summarize_ask_timings(values):
    return {
        metric: {
            "p50": nearest_rank([value[metric] for value in values], 0.50),
            "p95": nearest_rank([value[metric] for value in values], 0.95),
            "maximum": max(value[metric] for value in values),
        }
        for metric in ("wallDurationMilliseconds", "cpuTimeMilliseconds")
    }


def summarize_ask_pipeline(runs):
    samples = [sample for _, sample in sorted(runs.items())]
    generation = [
        {
            metric: sample["firstToken"][metric]
            - sample["firstEvidence"][metric]
            for metric in (
                "wallDurationMilliseconds",
                "cpuTimeMilliseconds",
            )
        }
        for sample in samples
    ]
    return {
        "total": summarize_ask_timings(
            [sample["total"] for sample in samples]
        ),
        "firstEvidence": summarize_ask_timings(
            [sample["firstEvidence"] for sample in samples]
        ),
        "firstToken": summarize_ask_timings(
            [sample["firstToken"] for sample in samples]
        ),
        "generation": summarize_ask_timings(generation),
        "stages": {
            stage: summarize_ask_timings(
                [sample["stages"][stage] for sample in samples]
            )
            for stage in sorted(ASK_PIPELINE_STAGES)
        },
    }


def ask_pipeline_row(
    profile_id,
    pipeline,
    minimum_samples,
    maximum_timing_ratio,
):
    if pipeline is None:
        return {
            "profile": profile_id,
            "state": "missing",
            "sampleCount": 0,
            "corpus": None,
            "citations": None,
            "metrics": None,
        }
    runs = pipeline["runs"]
    corpus_values = {tuple(sorted(run["corpus"].items())) for run in runs.values()}
    if len(corpus_values) != 1:
        raise ResourceBaselineError(
            f"Ask pipeline corpus is inconsistent for profile {profile_id}"
        )
    citation_values = {
        (run["citations"]["count"], run["citations"]["digest"])
        for run in runs.values()
    }
    if len(citation_values) != 1:
        raise ResourceBaselineError(
            f"Ask pipeline citations are nondeterministic for profile {profile_id}"
        )
    sample_count = len(runs)
    metrics = summarize_ask_pipeline(runs) if sample_count else None
    state = pipeline["state"]
    if state == "pass" and sample_count < minimum_samples:
        state = "incomplete"
    elif state == "pass" and metrics is not None:
        timing_groups = [
            metrics["total"],
            metrics["firstEvidence"],
            metrics["firstToken"],
            metrics["generation"],
            *metrics["stages"].values(),
        ]
        if any(
            not timing_is_stable(group, maximum_timing_ratio)
            for group in timing_groups
        ):
            state = "unstable"
    corpus = dict(corpus_values.pop()) if corpus_values else None
    citations = None
    if citation_values:
        count, digest = citation_values.pop()
        citations = {"count": count, "digest": digest, "valid": True}
    return {
        "profile": profile_id,
        "state": state,
        "sampleCount": sample_count,
        "corpus": corpus,
        "citations": citations,
        "metrics": metrics,
    }


def timing_is_stable(metrics, maximum_ratio):
    for metric in ("wallDurationMilliseconds", "cpuTimeMilliseconds"):
        p50 = metrics[metric]["p50"]
        p95 = metrics[metric]["p95"]
        if p50 == 0:
            if p95 > 0:
                return False
        elif p95 / p50 > maximum_ratio:
            return False
    return True


def scenario_row(
    profile_id,
    scenario_id,
    scenario,
    minimum_samples,
    maximum_timing_ratio,
):
    if scenario is None:
        return {
            "profile": profile_id,
            "scenario": scenario_id,
            "state": "missing",
            "sampleCount": 0,
            "metrics": None,
        }
    state = scenario["state"]
    sample_count = len(scenario["runs"])
    metrics = summarize_runs(scenario["runs"]) if sample_count else None
    if state == "pass" and sample_count < minimum_samples:
        state = "incomplete"
    elif (
        state == "pass"
        and metrics is not None
        and not timing_is_stable(metrics, maximum_timing_ratio)
    ):
        state = "unstable"
    return {
        "profile": profile_id,
        "scenario": scenario_id,
        "state": state,
        "sampleCount": sample_count,
        "metrics": metrics,
    }


def expected_build(arguments):
    return {
        "version": safe_string(
            arguments.version,
            "--version",
            VERSION_PATTERN,
        ),
        "build": safe_string(arguments.build, "--build", BUILD_PATTERN),
        "commit": safe_string(arguments.commit, "--commit", COMMIT_PATTERN),
        "configuration": "release",
    }


def command_output(command, label):
    try:
        result = subprocess.run(
            command,
            check=True,
            capture_output=True,
            text=True,
        )
    except (OSError, subprocess.CalledProcessError) as error:
        raise ResourceBaselineError(f"could not detect {label}") from error
    value = result.stdout.strip()
    if not value:
        raise ResourceBaselineError(f"could not detect {label}")
    return value


def detect_machine_metadata(profile_id, contract):
    if platform.system() != "Darwin":
        raise ResourceBaselineError("resource receipts require macOS")
    os_version = command_output(
        ["sw_vers", "-productVersion"],
        "macOS version",
    )
    os_build = command_output(
        ["sw_vers", "-buildVersion"],
        "macOS build",
    )
    architecture = platform.machine()
    physical_memory = command_output(
        ["sysctl", "-n", "hw.memsize"],
        "physical memory",
    )
    hardware_model = command_output(
        ["sysctl", "-n", "hw.model"],
        "hardware model",
    )
    xcode_lines = command_output(
        ["xcodebuild", "-version"],
        "Xcode version",
    ).splitlines()
    if len(xcode_lines) != 2 or not xcode_lines[0].startswith("Xcode "):
        raise ResourceBaselineError("could not parse Xcode version")
    if not xcode_lines[1].startswith("Build version "):
        raise ResourceBaselineError("could not parse Xcode build")
    swift_output = command_output(["swift", "--version"], "Swift version")
    swift_match = SWIFT_VERSION_PATTERN.search(swift_output)
    if swift_match is None:
        raise ResourceBaselineError("could not parse Swift version")
    try:
        physical_memory_bytes = int(physical_memory)
    except ValueError as error:
        raise ResourceBaselineError(
            "could not parse physical memory"
        ) from error
    host = {
        "profile": profile_id,
        "osVersion": os_version,
        "osBuild": os_build,
        "architecture": architecture,
        "physicalMemoryBytes": physical_memory_bytes,
        "hardwareModel": hardware_model,
    }
    toolchain = {
        "xcodeVersion": xcode_lines[0].removeprefix("Xcode ").strip(),
        "xcodeBuild": xcode_lines[1].removeprefix("Build version ").strip(),
        "swiftVersion": swift_match.group(1),
    }
    validate_host(host, "detected host", contract)
    validate_toolchain(toolchain, "detected toolchain")
    return host, toolchain


def split_sample_assignment(value):
    scenario_id, separator, raw_path = value.partition("=")
    if not separator or not raw_path:
        raise ResourceBaselineError(
            "--sample must use the form scenario=/path/to/sample.json"
        )
    scenario_id = safe_string(
        scenario_id,
        "--sample scenario",
        PROFILE_PATTERN,
    )
    return scenario_id, raw_path


def assemble_namespace(arguments):
    contract = validate_contract(load_json(arguments.contract, "resource contract"))
    build = expected_build(arguments)
    profile = safe_string(arguments.profile, "--profile", PROFILE_PATTERN)
    if profile not in contract["profiles"]:
        raise ResourceBaselineError("--profile is not in the resource contract")
    if not arguments.sample:
        raise ResourceBaselineError("at least one --sample is required")
    samples_by_scenario = {}
    for index, assignment in enumerate(arguments.sample):
        scenario, sample_path = split_sample_assignment(assignment)
        if scenario not in contract["scenarios"]:
            raise ResourceBaselineError(
                f"--sample scenario is not in the contract: {scenario}"
            )
        raw_sample = load_json(
            sample_path,
            f"resource sample {index + 1}",
        )
        run, _, _ = validate_sample(
            raw_sample,
            f"resource sample {index + 1}",
        )
        scenario_samples = samples_by_scenario.setdefault(scenario, {})
        if run in scenario_samples:
            raise ResourceBaselineError(
                f"resource samples repeat {scenario} run: {run}"
            )
        scenario_samples[run] = raw_sample

    ask_pipeline_samples = {}
    for index, sample_path in enumerate(arguments.ask_pipeline_sample):
        raw_sample = load_json(
            sample_path,
            f"Ask pipeline sample {index + 1}",
        )
        run, _ = validate_ask_pipeline_sample(
            raw_sample,
            f"Ask pipeline sample {index + 1}",
        )
        if run in ask_pipeline_samples:
            raise ResourceBaselineError(
                f"Ask pipeline samples repeat run: {run}"
            )
        ask_pipeline_samples[run] = raw_sample
    ask_resource_runs = set(samples_by_scenario.get("ask", {}))
    if ask_resource_runs != set(ask_pipeline_samples):
        raise ResourceBaselineError(
            "Ask pipeline samples must match Ask resource sample runs"
        )

    host, toolchain = detect_machine_metadata(profile, contract)
    receipt = {
        "schemaVersion": SCHEMA_VERSION,
        "kind": "resource-baseline",
        "collectedAt": utc_now(),
        "build": build,
        "host": host,
        "toolchain": toolchain,
        "scenarios": [
            {
                "id": scenario,
                "state": "pass",
                "samples": [
                    samples[run]
                    for run in sorted(samples)
                ],
            }
            for scenario, samples in sorted(samples_by_scenario.items())
        ],
    }
    if ask_pipeline_samples:
        receipt["askPipeline"] = {
            "state": "pass",
            "samples": [
                ask_pipeline_samples[run]
                for run in sorted(ask_pipeline_samples)
            ],
        }
    validate_receipt(receipt, contract, "assembled resource receipt")
    write_json(Path(arguments.output).expanduser(), receipt)
    return 0


def render_markdown(scorecard):
    build = scorecard["build"]
    lines = [
        "# Portavoz resource baseline",
        "",
        f"- Outcome: **{scorecard['outcome'].upper()}**",
        f"- Version/build: `{build['version']} ({build['build']})`",
        f"- Commit: `{build['commit']}`",
        f"- Minimum stable samples: `{scorecard['minimumStableSamples']}`",
        "- Maximum timing p95/p50 ratio: "
        f"`{scorecard['maximumTimingP95ToP50Ratio']:.2f}`",
        "",
        "| Profile | Scenario | State | Samples | Wall p50/p95 | Peak footprint | Energy p50/p95 | Thermal |",
        "| --- | --- | --- | ---: | ---: | ---: | ---: | --- |",
    ]
    for row in scorecard["measurements"]:
        metrics = row["metrics"]
        if metrics is None:
            wall = peak = energy = thermal = "—"
        else:
            wall_metric = metrics["wallDurationMilliseconds"]
            footprint = metrics["peakPhysicalFootprintBytes"]
            energy_metric = metrics["energyNanojoules"]
            wall = f"{wall_metric['p50']:.0f}/{wall_metric['p95']:.0f} ms"
            peak = f"{footprint['maximum'] / 1_048_576:.0f} MiB"
            energy = (
                f"{energy_metric['p50'] / 1_000_000:.2f}/"
                f"{energy_metric['p95'] / 1_000_000:.2f} mJ"
            )
            thermal = metrics["maximumThermalState"]
        lines.append(
            f"| `{row['profile']}` | `{row['scenario']}` | "
            f"**{row['state']}** | {row['sampleCount']} | {wall} | "
            f"{peak} | {energy} | {thermal} |"
        )
    lines += [
        "",
        "## Ask pipeline",
        "",
        "Time to first evidence is reported separately from the subsequent "
        "answer-generation interval. Every value is p50/p95 wall time with "
        "process CPU in parentheses.",
        "",
        "| Profile | State | Samples | Total | First evidence | Generation | Corpus | Citations |",
        "| --- | --- | ---: | ---: | ---: | ---: | --- | --- |",
    ]
    for row in scorecard["askPipelineMeasurements"]:
        metrics = row["metrics"]
        if metrics is None:
            total = evidence = generation = corpus = citations = "—"
        else:
            def render_timing(timing):
                wall = timing["wallDurationMilliseconds"]
                cpu = timing["cpuTimeMilliseconds"]
                return (
                    f"{wall['p50']:.0f}/{wall['p95']:.0f} ms "
                    f"({cpu['p50']:.0f}/{cpu['p95']:.0f} CPU ms)"
                )

            total = render_timing(metrics["total"])
            evidence = render_timing(metrics["firstEvidence"])
            generation = render_timing(metrics["generation"])
            corpus = (
                f"`{row['corpus']['generation']}` / "
                f"`{row['corpus']['checksum']}`"
            )
            citations = (
                f"{row['citations']['count']} / "
                f"`{row['citations']['digest']}`"
            )
        lines.append(
            f"| `{row['profile']}` | **{row['state']}** | "
            f"{row['sampleCount']} | {total} | {evidence} | {generation} | "
            f"{corpus} | {citations} |"
        )
    lines += [
        "",
        "| Profile | Stage | Wall p50/p95 | CPU p50/p95 |",
        "| --- | --- | ---: | ---: |",
    ]
    for row in scorecard["askPipelineMeasurements"]:
        if row["metrics"] is None:
            continue
        for stage, timing in row["metrics"]["stages"].items():
            wall = timing["wallDurationMilliseconds"]
            cpu = timing["cpuTimeMilliseconds"]
            lines.append(
                f"| `{row['profile']}` | `{stage}` | "
                f"{wall['p50']:.0f}/{wall['p95']:.0f} ms | "
                f"{cpu['p50']:.0f}/{cpu['p95']:.0f} ms |"
            )
    lines += [
        "",
        "This scorecard proves measurement completeness only. It does not set "
        "resource budgets or authorize admission, eviction, or scheduling policy.",
        "",
    ]
    return "\n".join(lines)


def evaluate_namespace(arguments):
    contract = validate_contract(load_json(arguments.contract, "resource contract"))
    build = expected_build(arguments)
    receipts = {}
    profile_metadata = []
    for index, receipt_path in enumerate(arguments.receipt):
        receipt = validate_receipt(
            load_json(receipt_path, f"resource receipt {index + 1}"),
            contract,
            f"resource receipt {index + 1}",
        )
        profile = receipt["host"]["profile"]
        if profile in receipts:
            raise ResourceBaselineError(
                f"resource evidence repeats profile: {profile}"
            )
        if receipt["build"] != build:
            raise ResourceBaselineError(
                f"resource receipt for {profile} does not match requested build"
            )
        receipts[profile] = receipt
        profile_metadata.append(
            {
                "profile": profile,
                "hardwareModel": receipt["host"]["hardwareModel"],
                "physicalMemoryBytes": receipt["host"]["physicalMemoryBytes"],
                "osVersion": receipt["host"]["osVersion"],
                "osBuild": receipt["host"]["osBuild"],
                "toolchain": receipt["toolchain"],
            }
        )

    measurements = []
    ask_pipeline_measurements = []
    for profile in contract["profiles"]:
        receipt = receipts.get(profile)
        scenarios = receipt["scenarios"] if receipt is not None else {}
        for scenario in contract["scenarios"]:
            measurements.append(
                scenario_row(
                    profile,
                    scenario,
                    scenarios.get(scenario),
                    contract["minimumSamples"],
                    contract["maximumTimingRatio"],
                )
            )
        ask_pipeline_measurements.append(
            ask_pipeline_row(
                profile,
                receipt["askPipeline"] if receipt is not None else None,
                contract["minimumSamples"],
                contract["maximumTimingRatio"],
            )
        )
    comparable_ask = [
        row for row in ask_pipeline_measurements
        if row["corpus"] is not None and row["citations"] is not None
    ]
    corpus_identities = {
        (
            row["corpus"]["generation"],
            row["corpus"]["checksum"],
            row["corpus"]["fixtureSegmentCount"],
            row["corpus"]["warmup"],
        )
        for row in comparable_ask
    }
    if len(corpus_identities) > 1:
        raise ResourceBaselineError(
            "Ask pipeline corpus is not comparable across profiles"
        )
    citation_identities = {
        (row["citations"]["count"], row["citations"]["digest"])
        for row in comparable_ask
    }
    if len(citation_identities) > 1:
        raise ResourceBaselineError(
            "Ask pipeline citations are nondeterministic across profiles"
        )
    outcome = (
        "pass"
        if all(row["state"] == "pass" for row in measurements)
        and all(
            row["state"] == "pass"
            for row in ask_pipeline_measurements
        )
        else "blocked"
    )
    scorecard = {
        "schemaVersion": SCHEMA_VERSION,
        "kind": "resource-baseline-scorecard",
        "generatedAt": utc_now(),
        "build": build,
        "outcome": outcome,
        "minimumStableSamples": contract["minimumSamples"],
        "maximumTimingP95ToP50Ratio": contract["maximumTimingRatio"],
        "profiles": sorted(profile_metadata, key=lambda value: value["profile"]),
        "measurements": measurements,
        "askPipelineMeasurements": ask_pipeline_measurements,
    }
    output = Path(arguments.output).expanduser()
    write_json(output / "resource-baseline.json", scorecard)
    write_text(output / "resource-baseline.md", render_markdown(scorecard))
    return 0 if outcome == "pass" else 1


def build_parser():
    parser = argparse.ArgumentParser(
        description="Evaluate privacy-safe Portavoz resource baseline receipts."
    )
    subparsers = parser.add_subparsers(dest="command", required=True)
    assemble = subparsers.add_parser(
        "assemble",
        help="Assemble native app samples into one exact-shaped host receipt.",
    )
    assemble.add_argument("--version", required=True)
    assemble.add_argument("--build", required=True)
    assemble.add_argument("--commit", required=True)
    assemble.add_argument("--profile", required=True)
    assemble.add_argument(
        "--contract",
        default=str(DEFAULT_CONTRACT),
        help="Tracked resource matrix contract.",
    )
    assemble.add_argument(
        "--sample",
        action="append",
        default=[],
        help="Scenario/sample assignment; repeat for every measured run.",
    )
    assemble.add_argument(
        "--ask-pipeline-sample",
        action="append",
        default=[],
        help="Content-free Ask pipeline sample; repeat for every Ask run.",
    )
    assemble.add_argument("--output", required=True)
    evaluate = subparsers.add_parser(
        "evaluate",
        help="Write a complete pass/blocked resource scorecard.",
    )
    evaluate.add_argument("--version", required=True)
    evaluate.add_argument("--build", required=True)
    evaluate.add_argument("--commit", required=True)
    evaluate.add_argument(
        "--contract",
        default=str(DEFAULT_CONTRACT),
        help="Tracked resource matrix contract.",
    )
    evaluate.add_argument(
        "--receipt",
        action="append",
        default=[],
        help="Content-free resource receipt; repeat once per measured profile.",
    )
    evaluate.add_argument("--output", required=True)
    return parser


def main_from_args(arguments):
    parser = build_parser()
    namespace = parser.parse_args(arguments)
    if namespace.command == "assemble":
        return assemble_namespace(namespace)
    if namespace.command == "evaluate":
        return evaluate_namespace(namespace)
    raise ResourceBaselineError(f"unsupported command: {namespace.command}")


def main():
    try:
        return main_from_args(sys.argv[1:])
    except ResourceBaselineError as error:
        print(f"resource baseline error: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
