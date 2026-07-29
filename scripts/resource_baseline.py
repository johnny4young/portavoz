#!/usr/bin/env python3
"""Validate and summarize privacy-safe Portavoz resource baseline receipts."""

from __future__ import annotations

import argparse
import json
import math
import os
import re
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
PROFILE_PATTERN = re.compile(r"^[a-z0-9][a-z0-9-]{0,39}$")
HARDWARE_PATTERN = re.compile(
    r"^(Mac|MacBookPro|MacBookAir|Macmini|MacStudio|iMac|MacPro)"
    r"[0-9]{1,2},[0-9]{1,2}$"
)
TIMESTAMP_PATTERN = re.compile(r"^[0-9T:.+\-Z]{10,64}$")


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
    return {
        "build": dict(build),
        "host": dict(host),
        "toolchain": dict(toolchain),
        "scenarios": scenarios,
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
    outcome = (
        "pass"
        if all(row["state"] == "pass" for row in measurements)
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
