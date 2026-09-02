#!/usr/bin/env python3
"""Wait for a content-free, bounded performance-measurement host predicate."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import re
import subprocess
import sys
import time
import uuid
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable, Iterable, Sequence


SCHEMA_VERSION = 3
POLICY_VERSION = "prebuilt-release-host-readiness-v3"
CALIBRATION_VERSION = "sha256-zero-block-512mib-v1"
DEFAULT_MAXIMUM_WAIT_SECONDS = 300.0
DEFAULT_SAMPLE_INTERVAL_SECONDS = 0.5
DEFAULT_REQUIRED_CONSECUTIVE_SAMPLES = 10
DEFAULT_MAXIMUM_CPU_CAPACITY_FRACTION = 0.25
DEFAULT_MAXIMUM_LOAD_PER_PROCESSOR = 0.50
DEFAULT_MAXIMUM_INTERFERENCE_CPU_PERCENT = 2.0
DEFAULT_CALIBRATION_SAMPLE_COUNT = 5
DEFAULT_CALIBRATION_BYTES_PER_SAMPLE = 512 * 1024 * 1024
DEFAULT_MAXIMUM_CALIBRATION_WALL_MILLISECONDS = 200.0
DEFAULT_MAXIMUM_CALIBRATION_CPU_MILLISECONDS = 200.0
DEFAULT_MAXIMUM_CALIBRATION_DISPERSION_RATIO = 1.15
CALIBRATION_BLOCK_BYTES = 1024 * 1024
MAXIMUM_RETAINED_CALIBRATION_SAMPLE_MILLISECONDS = 60_000.0
CALIBRATION_EXPECTED_SHA256 = (
    "9acca8e8c22201155389f65abbf6bc9723edc7384ead80503839f49dcc56d767"
)
HEX_40 = re.compile(r"[0-9a-f]{40}")
HEX_64 = re.compile(r"[0-9a-f]{64}")
INTERFERENCE_CLASSES = (
    "build-driver",
    "clang-compiler",
    "linker",
    "source-analysis",
    "swift-compiler",
    "symbolication",
)
INTERFERENCE_CLASS_BY_EXECUTABLE = {
    "dsymutil": "symbolication",
    "ld": "linker",
    "swift": "build-driver",
    "swift-build": "build-driver",
    "swift-package": "build-driver",
    "symbolicatecrash": "symbolication",
    "xcodebuild": "build-driver",
}
INTERFERENCE_CLASS_PREFIXES = (
    ("clang", "clang-compiler"),
    ("coresymbolication", "symbolication"),
    ("sourcekit", "source-analysis"),
    ("swift", "swift-compiler"),
)
REASONS = (
    "build-or-symbolication",
    "load-average",
    "power-mode",
    "power-source",
    "thermal-state",
    "total-cpu",
)
CALIBRATION_REASONS = (
    "cpu-ceiling",
    "dispersion",
    "wall-ceiling",
)


class ReadinessError(ValueError):
    """The host cannot produce a trustworthy readiness receipt."""


@dataclass(frozen=True)
class ReadinessPolicy:
    maximum_wait_seconds: float = DEFAULT_MAXIMUM_WAIT_SECONDS
    sample_interval_seconds: float = DEFAULT_SAMPLE_INTERVAL_SECONDS
    required_consecutive_samples: int = DEFAULT_REQUIRED_CONSECUTIVE_SAMPLES
    maximum_cpu_capacity_fraction: float = DEFAULT_MAXIMUM_CPU_CAPACITY_FRACTION
    maximum_load_per_processor: float = DEFAULT_MAXIMUM_LOAD_PER_PROCESSOR
    maximum_interference_cpu_percent: float = (
        DEFAULT_MAXIMUM_INTERFERENCE_CPU_PERCENT
    )
    calibration_sample_count: int = DEFAULT_CALIBRATION_SAMPLE_COUNT
    calibration_bytes_per_sample: int = DEFAULT_CALIBRATION_BYTES_PER_SAMPLE
    maximum_calibration_wall_milliseconds: float = (
        DEFAULT_MAXIMUM_CALIBRATION_WALL_MILLISECONDS
    )
    maximum_calibration_cpu_milliseconds: float = (
        DEFAULT_MAXIMUM_CALIBRATION_CPU_MILLISECONDS
    )
    maximum_calibration_dispersion_ratio: float = (
        DEFAULT_MAXIMUM_CALIBRATION_DISPERSION_RATIO
    )

    def validate(self) -> ReadinessPolicy:
        finite_between(
            self.maximum_wait_seconds,
            "maximumWaitSeconds",
            minimum=1,
            maximum=900,
        )
        finite_between(
            self.sample_interval_seconds,
            "sampleIntervalSeconds",
            minimum=0.1,
            maximum=30,
        )
        exact_integer(
            self.required_consecutive_samples,
            "requiredConsecutiveSamples",
            minimum=2,
            maximum=10,
        )
        finite_between(
            self.maximum_cpu_capacity_fraction,
            "maximumCPUCapacityFraction",
            minimum=0.05,
            maximum=0.50,
        )
        finite_between(
            self.maximum_load_per_processor,
            "maximumLoadPerProcessor",
            minimum=0.05,
            maximum=1.0,
        )
        finite_between(
            self.maximum_interference_cpu_percent,
            "maximumInterferenceCPUPercent",
            minimum=0,
            maximum=25,
        )
        exact_integer(
            self.calibration_sample_count,
            "throughputCalibration.sampleCount",
            minimum=DEFAULT_CALIBRATION_SAMPLE_COUNT,
            maximum=DEFAULT_CALIBRATION_SAMPLE_COUNT,
        )
        exact_integer(
            self.calibration_bytes_per_sample,
            "throughputCalibration.bytesPerSample",
            minimum=DEFAULT_CALIBRATION_BYTES_PER_SAMPLE,
            maximum=DEFAULT_CALIBRATION_BYTES_PER_SAMPLE,
        )
        finite_between(
            self.maximum_calibration_wall_milliseconds,
            "throughputCalibration.maximumWallMilliseconds",
            minimum=100,
            maximum=1_000,
        )
        finite_between(
            self.maximum_calibration_cpu_milliseconds,
            "throughputCalibration.maximumCPUMilliseconds",
            minimum=100,
            maximum=1_000,
        )
        finite_between(
            self.maximum_calibration_dispersion_ratio,
            "throughputCalibration.maximumDispersionRatio",
            minimum=1,
            maximum=1.5,
        )
        return self

    def document(self) -> dict[str, Any]:
        self.validate()
        return {
            "version": POLICY_VERSION,
            "maximumWaitSeconds": self.maximum_wait_seconds,
            "sampleIntervalSeconds": self.sample_interval_seconds,
            "requiredConsecutiveSamples": self.required_consecutive_samples,
            "maximumCPUCapacityFraction": self.maximum_cpu_capacity_fraction,
            "maximumLoadPerProcessor": self.maximum_load_per_processor,
            "maximumInterferenceCPUPercent": (
                self.maximum_interference_cpu_percent
            ),
            "throughputCalibration": {
                "version": CALIBRATION_VERSION,
                "sampleCount": self.calibration_sample_count,
                "bytesPerSample": self.calibration_bytes_per_sample,
                "maximumWallMilliseconds": (
                    self.maximum_calibration_wall_milliseconds
                ),
                "maximumCPUMilliseconds": (
                    self.maximum_calibration_cpu_milliseconds
                ),
                "maximumDispersionRatio": (
                    self.maximum_calibration_dispersion_ratio
                ),
            },
        }


@dataclass(frozen=True)
class HostObservation:
    processor_count: int
    total_cpu_percent: float
    load_average_one_minute: float
    interference_cpu_percent: float
    power_source: str
    power_mode: str
    thermal_state: str
    interference_contributors: tuple[tuple[str, float], ...] = ()


@dataclass(frozen=True)
class ThroughputCalibration:
    wall_milliseconds: tuple[float, ...]
    cpu_milliseconds: tuple[float, ...]


class SystemProbe:
    def __init__(
        self,
        *,
        command_runner: Callable[..., subprocess.CompletedProcess[str]] = subprocess.run,
    ) -> None:
        self.command_runner = command_runner
        try:
            self.processor_count = int(self._run(
                ["/usr/sbin/sysctl", "-n", "hw.logicalcpu"],
                "processor count",
            ).strip())
        except ValueError as error:
            raise ReadinessError("processor count output is malformed") from error
        exact_integer(
            self.processor_count,
            "processorCount",
            minimum=1,
            maximum=1024,
        )

    def _run(self, command: Sequence[str], label: str) -> str:
        try:
            completed = self.command_runner(
                list(command),
                check=False,
                capture_output=True,
                text=True,
                timeout=5,
            )
        except (OSError, subprocess.TimeoutExpired, UnicodeError) as error:
            raise ReadinessError(f"{label} probe unavailable") from error
        if completed.returncode != 0:
            raise ReadinessError(f"{label} probe unavailable")
        return completed.stdout

    def sample(self) -> HostObservation:
        total_cpu, interference_cpu, contributors = parse_process_cpu(self._run(
            ["/bin/ps", "-A", "-o", "pcpu=,comm="],
            "process CPU",
        ))
        load = parse_load_average(self._run(
            ["/usr/sbin/sysctl", "-n", "vm.loadavg"],
            "load average",
        ))
        power_source = parse_power_source(self._run(
            ["/usr/bin/pmset", "-g", "batt"],
            "power source",
        ))
        power_mode = parse_power_mode(
            self._run(["/usr/bin/pmset", "-g", "custom"], "power mode"),
            power_source,
        )
        thermal_state = parse_thermal_state(self._run(
            ["/usr/bin/pmset", "-g", "therm"],
            "thermal state",
        ))
        return HostObservation(
            processor_count=self.processor_count,
            total_cpu_percent=total_cpu,
            load_average_one_minute=load,
            interference_cpu_percent=interference_cpu,
            power_source=power_source,
            power_mode=power_mode,
            thermal_state=thermal_state,
            interference_contributors=contributors,
        )


def exact_integer(value: Any, label: str, *, minimum: int, maximum: int) -> int:
    if isinstance(value, bool) or not isinstance(value, int):
        raise ReadinessError(f"{label} must be an integer")
    if not minimum <= value <= maximum:
        raise ReadinessError(f"{label} is outside its bounds")
    return value


def finite_between(
    value: Any,
    label: str,
    *,
    minimum: float,
    maximum: float,
) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise ReadinessError(f"{label} must be numeric")
    result = float(value)
    if not math.isfinite(result) or not minimum <= result <= maximum:
        raise ReadinessError(f"{label} is outside its bounds")
    return result


def nearest_rank(samples: Sequence[float], percentile: float) -> float:
    if not samples:
        raise ReadinessError("throughput calibration samples are empty")
    ordered = sorted(samples)
    index = min(
        len(ordered) - 1,
        max(0, math.ceil(len(ordered) * percentile) - 1),
    )
    return ordered[index]


def sample_throughput_calibration(
    policy: ReadinessPolicy,
) -> ThroughputCalibration:
    """Measure source-independent CPU throughput without retaining payload."""
    policy.validate()
    block = bytes(CALIBRATION_BLOCK_BYTES)
    iterations = policy.calibration_bytes_per_sample // CALIBRATION_BLOCK_BYTES
    wall_samples: list[float] = []
    cpu_samples: list[float] = []
    for _ in range(policy.calibration_sample_count):
        wall_started = time.monotonic_ns()
        cpu_started = time.process_time_ns()
        digest = hashlib.sha256()
        for _ in range(iterations):
            digest.update(block)
        cpu_elapsed = (time.process_time_ns() - cpu_started) / 1_000_000
        wall_elapsed = (time.monotonic_ns() - wall_started) / 1_000_000
        if digest.hexdigest() != CALIBRATION_EXPECTED_SHA256:
            raise ReadinessError("throughput calibration digest is invalid")
        wall_samples.append(wall_elapsed)
        cpu_samples.append(cpu_elapsed)
    return ThroughputCalibration(
        wall_milliseconds=tuple(wall_samples),
        cpu_milliseconds=tuple(cpu_samples),
    )


def calibration_document(
    observation: ThroughputCalibration,
    policy: ReadinessPolicy,
) -> dict[str, Any]:
    wall = tuple(float(value) for value in observation.wall_milliseconds)
    cpu = tuple(float(value) for value in observation.cpu_milliseconds)
    if len(wall) != policy.calibration_sample_count or len(cpu) != len(wall):
        raise ReadinessError("throughput calibration sample count is invalid")
    for index, value in enumerate(wall):
        finite_between(
            value,
            f"throughput calibration wall sample {index}",
            minimum=0.001,
            maximum=MAXIMUM_RETAINED_CALIBRATION_SAMPLE_MILLISECONDS,
        )
    for index, value in enumerate(cpu):
        finite_between(
            value,
            f"throughput calibration CPU sample {index}",
            minimum=0.001,
            maximum=MAXIMUM_RETAINED_CALIBRATION_SAMPLE_MILLISECONDS,
        )
    wall = tuple(round(value, 6) for value in wall)
    cpu = tuple(round(value, 6) for value in cpu)
    wall_p50 = nearest_rank(wall, 0.50)
    wall_p95 = nearest_rank(wall, 0.95)
    cpu_p50 = nearest_rank(cpu, 0.50)
    cpu_p95 = nearest_rank(cpu, 0.95)
    dispersion = max(wall_p95 / wall_p50, cpu_p95 / cpu_p50)
    reasons: list[str] = []
    if wall_p95 > policy.maximum_calibration_wall_milliseconds:
        reasons.append("wall-ceiling")
    if cpu_p95 > policy.maximum_calibration_cpu_milliseconds:
        reasons.append("cpu-ceiling")
    if dispersion > policy.maximum_calibration_dispersion_ratio:
        reasons.append("dispersion")
    return {
        "version": CALIBRATION_VERSION,
        "sampleCount": len(wall),
        "bytesPerSample": policy.calibration_bytes_per_sample,
        "wallMilliseconds": list(wall),
        "cpuMilliseconds": list(cpu),
        "wallP50Milliseconds": round(wall_p50, 6),
        "wallP95Milliseconds": round(wall_p95, 6),
        "cpuP50Milliseconds": round(cpu_p50, 6),
        "cpuP95Milliseconds": round(cpu_p95, 6),
        "dispersionRatio": round(dispersion, 6),
        "reasons": sorted(reasons),
    }


def interference_class(executable: str) -> str | None:
    name = Path(executable).name.casefold()
    if name in INTERFERENCE_CLASS_BY_EXECUTABLE:
        return INTERFERENCE_CLASS_BY_EXECUTABLE[name]
    for prefix, contributor_class in INTERFERENCE_CLASS_PREFIXES:
        if name.startswith(prefix):
            return contributor_class
    return None


def parse_process_cpu(
    output: str,
) -> tuple[float, float, tuple[tuple[str, float], ...]]:
    total = 0.0
    contributions: dict[str, float] = {}
    observed = 0
    for line in output.splitlines():
        fields = line.strip().split(maxsplit=1)
        if len(fields) != 2:
            continue
        try:
            cpu = float(fields[0])
        except ValueError:
            continue
        if not math.isfinite(cpu) or cpu < 0:
            raise ReadinessError("process CPU inventory is invalid")
        observed += 1
        total += cpu
        contributor_class = interference_class(fields[1])
        if contributor_class is not None and cpu > 0:
            contributions[contributor_class] = (
                contributions.get(contributor_class, 0.0) + cpu
            )
    if observed == 0:
        raise ReadinessError("process CPU inventory is empty")
    contributors = tuple(sorted(contributions.items()))
    return total, sum(cpu for _, cpu in contributors), contributors


def parse_load_average(output: str) -> float:
    match = re.fullmatch(
        r"\s*\{\s*([0-9]+(?:\.[0-9]+)?)\s+"
        r"[0-9]+(?:\.[0-9]+)?\s+[0-9]+(?:\.[0-9]+)?\s*\}\s*",
        output,
    )
    if match is None:
        raise ReadinessError("load average output is malformed")
    value = float(match.group(1))
    if not math.isfinite(value):
        raise ReadinessError("load average output is invalid")
    return value


def parse_power_source(output: str) -> str:
    match = re.search(r"Now drawing from '([^']+)'", output)
    if match is None:
        raise ReadinessError("power source output is malformed")
    if match.group(1) == "AC Power":
        return "ac"
    if match.group(1) == "Battery Power":
        return "battery"
    raise ReadinessError("power source is unsupported")


def parse_power_mode(output: str, power_source: str) -> str:
    section_name = "AC Power:" if power_source == "ac" else "Battery Power:"
    active = False
    mode: int | None = None
    for line in output.splitlines():
        stripped = line.strip()
        if stripped.endswith("Power:"):
            active = stripped == section_name
            continue
        if active and (match := re.fullmatch(r"powermode\s+([0-9]+)", stripped)):
            mode = int(match.group(1))
            break
    if mode is None:
        raise ReadinessError("power mode output is malformed")
    return {0: "automatic", 1: "low-power", 2: "high-power"}.get(
        mode, "unsupported"
    )


def parse_thermal_state(output: str) -> str:
    lines = [line.strip() for line in output.splitlines() if line.strip()]
    if not lines or any(line.startswith("Error:") for line in lines):
        raise ReadinessError("thermal state output is unavailable")
    for line in lines:
        if "warning level" in line.casefold() and "no " not in line.casefold():
            return "pressured"
        if match := re.search(
            r"(?:CPU_Scheduler_Limit|CPU_Speed_Limit)\s*=\s*([0-9]+)",
            line,
        ):
            if int(match.group(1)) < 100:
                return "pressured"
    return "nominal"


def reasons_for(
    observation: HostObservation,
    policy: ReadinessPolicy,
) -> tuple[str, ...]:
    reasons: list[str] = []
    if observation.total_cpu_percent > (
        observation.processor_count
        * 100
        * policy.maximum_cpu_capacity_fraction
    ):
        reasons.append("total-cpu")
    if observation.load_average_one_minute > (
        observation.processor_count * policy.maximum_load_per_processor
    ):
        reasons.append("load-average")
    if (
        observation.interference_cpu_percent
        > policy.maximum_interference_cpu_percent
    ):
        reasons.append("build-or-symbolication")
    if observation.power_source != "ac":
        reasons.append("power-source")
    if observation.power_mode != "automatic":
        reasons.append("power-mode")
    if observation.thermal_state != "nominal":
        reasons.append("thermal-state")
    return tuple(sorted(reasons))


def sample_document(
    sequence: int,
    offset: float,
    observation: HostObservation,
    reasons: Iterable[str],
) -> dict[str, Any]:
    return {
        "sequence": sequence,
        "offsetSeconds": round(offset, 6),
        "processorCount": observation.processor_count,
        "totalCPUPercent": round(observation.total_cpu_percent, 3),
        "loadAverageOneMinute": round(observation.load_average_one_minute, 3),
        "interferenceCPUPercent": round(
            observation.interference_cpu_percent, 3
        ),
        "interferenceContributors": [
            {"class": contributor_class, "cpuPercent": round(cpu, 3)}
            for contributor_class, cpu in observation.interference_contributors
        ],
        "powerSource": observation.power_source,
        "powerMode": observation.power_mode,
        "thermalState": observation.thermal_state,
        "reasons": list(reasons),
    }


def wait_for_readiness(
    *,
    policy: ReadinessPolicy,
    source_commit: str,
    binary_sha256: str,
    sampler: Callable[[], HostObservation],
    calibrator: Callable[[], ThroughputCalibration],
    clock: Callable[[], float] = time.monotonic,
    sleeper: Callable[[float], None] = time.sleep,
    generated_at: str | None = None,
) -> dict[str, Any]:
    policy.validate()
    if HEX_40.fullmatch(source_commit) is None:
        raise ReadinessError("source commit is invalid")
    if HEX_64.fullmatch(binary_sha256) is None:
        raise ReadinessError("binary SHA-256 is invalid")
    started = clock()
    consecutive: list[dict[str, Any]] = []
    recent: list[dict[str, Any]] = []
    sequence = 0
    calibration_attempt_count = 0
    throughput_calibration: dict[str, Any] | None = None
    while True:
        sequence += 1
        observation = sampler()
        offset = clock() - started
        if not math.isfinite(offset) or offset < 0:
            raise ReadinessError("readiness clock is non-monotonic")
        reasons = reasons_for(observation, policy)
        sample = sample_document(sequence, offset, observation, reasons)
        recent = (recent + [sample])[-policy.required_consecutive_samples :]
        if reasons:
            consecutive = []
        else:
            consecutive.append(sample)
        if offset >= policy.maximum_wait_seconds:
            outcome = "blocked"
            retained = recent
            break
        if len(consecutive) == policy.required_consecutive_samples:
            calibration_attempt_count += 1
            throughput_calibration = calibration_document(calibrator(), policy)
            calibration_completed_offset = clock() - started
            if (
                not math.isfinite(calibration_completed_offset)
                or calibration_completed_offset < offset
            ):
                raise ReadinessError("readiness clock is non-monotonic")
            if (
                not throughput_calibration["reasons"]
                and calibration_completed_offset <= policy.maximum_wait_seconds
            ):
                outcome = "ready"
                retained = consecutive
                break
            consecutive = []
            if calibration_completed_offset >= policy.maximum_wait_seconds:
                outcome = "blocked"
                retained = recent
                break
            sleeper(
                min(
                    policy.sample_interval_seconds,
                    policy.maximum_wait_seconds - calibration_completed_offset,
                )
            )
            continue
        sleeper(
            min(
                policy.sample_interval_seconds,
                policy.maximum_wait_seconds - offset,
            )
        )

    generated_at = generated_at or datetime.now(timezone.utc).isoformat().replace(
        "+00:00", "Z"
    )
    receipt = {
        "schemaVersion": SCHEMA_VERSION,
        "kind": "performance-host-readiness",
        "generatedAt": generated_at,
        "sourceCommit": source_commit,
        "binarySHA256": binary_sha256,
        "policy": policy.document(),
        "outcome": outcome,
        "elapsedSeconds": round(clock() - started, 6),
        "observedSampleCount": sequence,
        "samples": retained,
        "calibrationAttemptCount": calibration_attempt_count,
        "throughputCalibration": throughput_calibration,
    }
    validate_receipt(
        receipt,
        policy=policy,
        expected_commit=source_commit,
        expected_binary_sha256=binary_sha256,
        require_ready=False,
    )
    return receipt


def exact_object(value: Any, label: str, keys: set[str]) -> dict[str, Any]:
    if not isinstance(value, dict) or set(value) != keys:
        raise ReadinessError(f"{label} does not match its schema")
    return value


def validate_calibration_document(
    value: Any,
    policy: ReadinessPolicy,
) -> dict[str, Any]:
    calibration = exact_object(
        value,
        "throughput calibration",
        {
            "version",
            "sampleCount",
            "bytesPerSample",
            "wallMilliseconds",
            "cpuMilliseconds",
            "wallP50Milliseconds",
            "wallP95Milliseconds",
            "cpuP50Milliseconds",
            "cpuP95Milliseconds",
            "dispersionRatio",
            "reasons",
        },
    )
    if calibration["version"] != CALIBRATION_VERSION:
        raise ReadinessError("throughput calibration version drifted")
    if exact_integer(
        calibration["sampleCount"],
        "throughput calibration sampleCount",
        minimum=policy.calibration_sample_count,
        maximum=policy.calibration_sample_count,
    ) != policy.calibration_sample_count:
        raise ReadinessError("throughput calibration sample count drifted")
    if exact_integer(
        calibration["bytesPerSample"],
        "throughput calibration bytesPerSample",
        minimum=policy.calibration_bytes_per_sample,
        maximum=policy.calibration_bytes_per_sample,
    ) != policy.calibration_bytes_per_sample:
        raise ReadinessError("throughput calibration byte count drifted")
    wall = calibration["wallMilliseconds"]
    cpu = calibration["cpuMilliseconds"]
    if (
        not isinstance(wall, list)
        or not isinstance(cpu, list)
        or len(wall) != policy.calibration_sample_count
        or len(cpu) != len(wall)
    ):
        raise ReadinessError("throughput calibration samples are invalid")
    reconstructed = calibration_document(
        ThroughputCalibration(
            wall_milliseconds=tuple(wall),
            cpu_milliseconds=tuple(cpu),
        ),
        policy,
    )
    if calibration != reconstructed:
        raise ReadinessError("throughput calibration summary is inconsistent")
    reasons = calibration["reasons"]
    if (
        not isinstance(reasons, list)
        or reasons != sorted(set(reasons))
        or not set(reasons) <= set(CALIBRATION_REASONS)
    ):
        raise ReadinessError("throughput calibration reasons are invalid")
    return calibration


def validate_receipt(
    value: Any,
    *,
    policy: ReadinessPolicy,
    expected_commit: str,
    expected_binary_sha256: str,
    require_ready: bool = True,
) -> dict[str, Any]:
    receipt = exact_object(
        value,
        "performance host readiness receipt",
        {
            "schemaVersion",
            "kind",
            "generatedAt",
            "sourceCommit",
            "binarySHA256",
            "policy",
            "outcome",
            "elapsedSeconds",
            "observedSampleCount",
            "samples",
            "calibrationAttemptCount",
            "throughputCalibration",
        },
    )
    exact_integer(
        receipt["schemaVersion"],
        "schemaVersion",
        minimum=SCHEMA_VERSION,
        maximum=SCHEMA_VERSION,
    )
    if receipt["kind"] != "performance-host-readiness":
        raise ReadinessError("readiness receipt kind is invalid")
    try:
        datetime.fromisoformat(receipt["generatedAt"].replace("Z", "+00:00"))
    except (AttributeError, ValueError) as error:
        raise ReadinessError("readiness receipt timestamp is invalid") from error
    if receipt["sourceCommit"] != expected_commit:
        raise ReadinessError("readiness receipt source commit changed")
    if receipt["binarySHA256"] != expected_binary_sha256:
        raise ReadinessError("readiness receipt binary SHA-256 changed")
    if receipt["policy"] != policy.document():
        raise ReadinessError("readiness receipt policy drifted")
    if receipt["outcome"] not in {"ready", "blocked"}:
        raise ReadinessError("readiness receipt outcome is invalid")
    if require_ready and receipt["outcome"] != "ready":
        raise ReadinessError("performance host did not become ready")
    finite_between(
        receipt["elapsedSeconds"],
        "elapsedSeconds",
        minimum=0,
        maximum=(
            policy.maximum_wait_seconds
            + policy.calibration_sample_count
            * MAXIMUM_RETAINED_CALIBRATION_SAMPLE_MILLISECONDS
            / 1_000
        ),
    )
    observed = exact_integer(
        receipt["observedSampleCount"],
        "observedSampleCount",
        minimum=1,
        maximum=100_000,
    )
    calibration_attempt_count = exact_integer(
        receipt["calibrationAttemptCount"],
        "calibrationAttemptCount",
        minimum=0,
        maximum=observed,
    )
    samples = receipt["samples"]
    if not isinstance(samples, list) or not 1 <= len(samples) <= (
        policy.required_consecutive_samples
    ):
        raise ReadinessError("readiness receipt samples are invalid")
    validated_samples = []
    sequences = []
    previous_sequence = 0
    for index, raw in enumerate(samples):
        sample = exact_object(
            raw,
            f"readiness receipt sample {index}",
            {
                "sequence",
                "offsetSeconds",
                "processorCount",
                "totalCPUPercent",
                "loadAverageOneMinute",
                "interferenceCPUPercent",
                "interferenceContributors",
                "powerSource",
                "powerMode",
                "thermalState",
                "reasons",
            },
        )
        sequence = exact_integer(
            sample["sequence"], "sample.sequence", minimum=1, maximum=observed
        )
        if sequence <= previous_sequence:
            raise ReadinessError("readiness receipt sample order is invalid")
        previous_sequence = sequence
        sequences.append(sequence)
        processor_count = exact_integer(
            sample["processorCount"],
            "sample.processorCount",
            minimum=1,
            maximum=1024,
        )
        finite_between(
            sample["offsetSeconds"],
            "sample.offsetSeconds",
            minimum=0,
            maximum=policy.maximum_wait_seconds + policy.sample_interval_seconds,
        )
        finite_between(
            sample["totalCPUPercent"],
            "sample.totalCPUPercent",
            minimum=0,
            maximum=processor_count * 100,
        )
        finite_between(
            sample["loadAverageOneMinute"],
            "sample.loadAverageOneMinute",
            minimum=0,
            maximum=processor_count * 100,
        )
        finite_between(
            sample["interferenceCPUPercent"],
            "sample.interferenceCPUPercent",
            minimum=0,
            maximum=processor_count * 100,
        )
        contributors = sample["interferenceContributors"]
        if not isinstance(contributors, list) or len(contributors) > len(
            INTERFERENCE_CLASSES
        ):
            raise ReadinessError(
                "readiness receipt interference contributors are invalid"
            )
        contributor_pairs: list[tuple[str, float]] = []
        for contributor_index, raw_contributor in enumerate(contributors):
            contributor = exact_object(
                raw_contributor,
                (
                    "readiness receipt interference contributor "
                    f"{contributor_index}"
                ),
                {"class", "cpuPercent"},
            )
            contributor_class = contributor["class"]
            if contributor_class not in INTERFERENCE_CLASSES:
                raise ReadinessError(
                    "readiness receipt interference class is invalid"
                )
            cpu_percent = finite_between(
                contributor["cpuPercent"],
                "interference contributor cpuPercent",
                minimum=0,
                maximum=processor_count * 100,
            )
            if cpu_percent <= 0:
                raise ReadinessError(
                    "readiness receipt interference contribution must be positive"
                )
            contributor_pairs.append((contributor_class, cpu_percent))
        contributor_classes = [item[0] for item in contributor_pairs]
        if contributor_classes != sorted(set(contributor_classes)):
            raise ReadinessError(
                "readiness receipt interference contributors are not canonical"
            )
        interference_cpu = float(sample["interferenceCPUPercent"])
        if round(sum(cpu for _, cpu in contributor_pairs), 3) != round(
            interference_cpu, 3
        ):
            raise ReadinessError(
                "readiness receipt interference contributions do not sum"
            )
        if sample["powerSource"] not in {"ac", "battery"}:
            raise ReadinessError("readiness receipt power source is invalid")
        if sample["powerMode"] not in {
            "automatic",
            "low-power",
            "high-power",
            "unsupported",
        }:
            raise ReadinessError("readiness receipt power mode is invalid")
        if sample["thermalState"] not in {"nominal", "pressured"}:
            raise ReadinessError("readiness receipt thermal state is invalid")
        reasons = sample["reasons"]
        if (
            not isinstance(reasons, list)
            or reasons != sorted(set(reasons))
            or not set(reasons) <= set(REASONS)
        ):
            raise ReadinessError("readiness receipt reasons are invalid")
        observation = HostObservation(
            processor_count=processor_count,
            total_cpu_percent=float(sample["totalCPUPercent"]),
            load_average_one_minute=float(sample["loadAverageOneMinute"]),
            interference_cpu_percent=float(sample["interferenceCPUPercent"]),
            power_source=sample["powerSource"],
            power_mode=sample["powerMode"],
            thermal_state=sample["thermalState"],
            interference_contributors=tuple(contributor_pairs),
        )
        if list(reasons_for(observation, policy)) != reasons:
            raise ReadinessError("readiness receipt reasons do not match observations")
        validated_samples.append(sample)
    if sequences != list(range(observed - len(samples) + 1, observed + 1)):
        raise ReadinessError("readiness receipt did not retain the latest samples")
    elapsed = float(receipt["elapsedSeconds"])
    last_offset = float(samples[-1]["offsetSeconds"])
    if last_offset > elapsed:
        raise ReadinessError("readiness receipt elapsed time is inconsistent")
    throughput_calibration = receipt["throughputCalibration"]
    validated_calibration = None
    if throughput_calibration is not None:
        validated_calibration = validate_calibration_document(
            throughput_calibration,
            policy,
        )
    if (calibration_attempt_count == 0) != (validated_calibration is None):
        raise ReadinessError("readiness receipt calibration attempts are inconsistent")
    if receipt["outcome"] == "ready":
        if elapsed > policy.maximum_wait_seconds:
            raise ReadinessError("ready receipt exceeded the admission deadline")
        if len(samples) != policy.required_consecutive_samples or any(
            sample["reasons"] for sample in samples
        ):
            raise ReadinessError("ready receipt lacks consecutive clean samples")
        if validated_calibration is None or validated_calibration["reasons"]:
            raise ReadinessError("ready receipt lacks clean throughput calibration")
    elif (
        not any(sample["reasons"] for sample in samples)
        and (
            validated_calibration is None
            or not validated_calibration["reasons"]
        )
        and elapsed < policy.maximum_wait_seconds
    ):
        raise ReadinessError("blocked receipt does not retain a blocker")
    return receipt


def write_private_json(path: Path, document: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    if path.exists():
        raise ReadinessError(f"output already exists: {path}")
    temporary = path.parent / f".{path.name}.{uuid.uuid4().hex}.tmp"
    descriptor = os.open(temporary, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
            json.dump(document, stream, indent=2, sort_keys=True)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.link(temporary, path)
    except FileExistsError as error:
        raise ReadinessError(f"output already exists: {path}") from error
    finally:
        temporary.unlink(missing_ok=True)


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    result.add_argument("--output", type=Path, required=True)
    result.add_argument("--source-commit", required=True)
    result.add_argument("--binary-sha256", required=True)
    result.add_argument(
        "--maximum-wait-seconds",
        type=float,
        default=DEFAULT_MAXIMUM_WAIT_SECONDS,
    )
    result.add_argument(
        "--sample-interval-seconds",
        type=float,
        default=DEFAULT_SAMPLE_INTERVAL_SECONDS,
    )
    result.add_argument(
        "--required-consecutive-samples",
        type=int,
        default=DEFAULT_REQUIRED_CONSECUTIVE_SAMPLES,
    )
    result.add_argument(
        "--maximum-cpu-capacity-fraction",
        type=float,
        default=DEFAULT_MAXIMUM_CPU_CAPACITY_FRACTION,
    )
    result.add_argument(
        "--maximum-load-per-processor",
        type=float,
        default=DEFAULT_MAXIMUM_LOAD_PER_PROCESSOR,
    )
    result.add_argument(
        "--maximum-interference-cpu-percent",
        type=float,
        default=DEFAULT_MAXIMUM_INTERFERENCE_CPU_PERCENT,
    )
    result.add_argument(
        "--calibration-sample-count",
        type=int,
        default=DEFAULT_CALIBRATION_SAMPLE_COUNT,
    )
    result.add_argument(
        "--calibration-bytes-per-sample",
        type=int,
        default=DEFAULT_CALIBRATION_BYTES_PER_SAMPLE,
    )
    result.add_argument(
        "--maximum-calibration-wall-milliseconds",
        type=float,
        default=DEFAULT_MAXIMUM_CALIBRATION_WALL_MILLISECONDS,
    )
    result.add_argument(
        "--maximum-calibration-cpu-milliseconds",
        type=float,
        default=DEFAULT_MAXIMUM_CALIBRATION_CPU_MILLISECONDS,
    )
    result.add_argument(
        "--maximum-calibration-dispersion-ratio",
        type=float,
        default=DEFAULT_MAXIMUM_CALIBRATION_DISPERSION_RATIO,
    )
    return result


def main(argv: Sequence[str] | None = None) -> int:
    arguments = parser().parse_args(argv)
    policy = ReadinessPolicy(
        maximum_wait_seconds=arguments.maximum_wait_seconds,
        sample_interval_seconds=arguments.sample_interval_seconds,
        required_consecutive_samples=arguments.required_consecutive_samples,
        maximum_cpu_capacity_fraction=arguments.maximum_cpu_capacity_fraction,
        maximum_load_per_processor=arguments.maximum_load_per_processor,
        maximum_interference_cpu_percent=(
            arguments.maximum_interference_cpu_percent
        ),
        calibration_sample_count=arguments.calibration_sample_count,
        calibration_bytes_per_sample=arguments.calibration_bytes_per_sample,
        maximum_calibration_wall_milliseconds=(
            arguments.maximum_calibration_wall_milliseconds
        ),
        maximum_calibration_cpu_milliseconds=(
            arguments.maximum_calibration_cpu_milliseconds
        ),
        maximum_calibration_dispersion_ratio=(
            arguments.maximum_calibration_dispersion_ratio
        ),
    )
    try:
        receipt = wait_for_readiness(
            policy=policy,
            source_commit=arguments.source_commit,
            binary_sha256=arguments.binary_sha256,
            sampler=SystemProbe().sample,
            calibrator=lambda: sample_throughput_calibration(policy),
        )
        write_private_json(arguments.output, receipt)
    except ReadinessError as error:
        print(f"performance host readiness error: {error}", file=sys.stderr)
        return 2
    if receipt["outcome"] != "ready":
        print(
            "performance host readiness blocked: the bounded predicate did not settle",
            file=sys.stderr,
        )
        return 1
    print(f"Performance host readiness passed: {arguments.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
