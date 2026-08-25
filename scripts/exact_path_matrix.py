#!/usr/bin/env python3
"""Validate and aggregate content-free exact-path benchmark observations."""

from __future__ import annotations

import argparse
import datetime as dt
import json
import math
import re
import sys
from pathlib import Path
from typing import Any


REPOSITORY = Path(__file__).resolve().parents[1]
DEFAULT_CONTRACT = REPOSITORY / "docs" / "evidence" / "exact-path-shadow-matrix.json"
DEFAULT_RESOURCE_CONTRACT = (
    REPOSITORY / "docs" / "evidence" / "resource-baseline-matrix.json"
)
COMMIT = re.compile(r"^[0-9a-f]{40}$")
TOOLCHAIN = re.compile(
    r"^Apple Swift version [0-9A-Za-z.+-]+ "
    r"\(swiftlang-[0-9A-Za-z.+-]+ clang-[0-9A-Za-z.+-]+\)$"
)
OPERATING_SYSTEM = re.compile(
    r"^Version ([0-9]+)\.[0-9]+(?:\.[0-9]+)? \(Build [0-9A-Za-z]+\)$"
)
PROFILE = re.compile(r"^[a-z0-9]+(?:-[a-z0-9]+)*$")

CONTRACT_KEYS = {
    "schemaVersion",
    "hostReceiptSchemaVersion",
    "fixtureVersion",
    "measurementPolicyVersion",
    "stabilityPolicyVersion",
    "buildConfiguration",
    "canonicalScales",
    "dimension",
    "queryCount",
    "runsPerQuery",
    "resultLimit",
    "minimumStableObservations",
    "maximumTimingP95ToP50Ratio",
    "supportedOperatingSystemMajors",
}
RESOURCE_CONTRACT_KEYS = {
    "schemaVersion",
    "minimumStableSamples",
    "maximumTimingP95ToP50Ratio",
    "recordingInput",
    "profiles",
    "scenarios",
}
PROFILE_KEYS = {
    "id",
    "minimumPhysicalMemoryBytes",
    "maximumPhysicalMemoryBytes",
}
RECORDING_INPUT_KEYS = {
    "generation",
    "sampleRate",
    "chunkFrames",
}
OBSERVATION_KEYS = {
    "schemaVersion",
    "fixtureVersion",
    "measurementPolicyVersion",
    "buildConfiguration",
    "host",
    "configuration",
    "engines",
    "agreement",
}
HOST_KEYS = {
    "operatingSystem",
    "architecture",
    "processorCount",
    "physicalMemoryBytes",
}
CONFIGURATION_KEYS = {
    "corpusSize",
    "dimension",
    "queryCount",
    "runsPerQuery",
    "resultLimit",
    "rawEmbeddingBytes",
    "controlDatabaseBytes",
    "fixturePreparationMilliseconds",
    "buildOrder",
}
ENGINE_KEYS = {
    "engine",
    "buildMilliseconds",
    "queryWallMilliseconds",
    "resultCount",
}
DISTRIBUTION_KEYS = {
    "sampleCount",
    "p50Milliseconds",
    "p95Milliseconds",
    "maximumMilliseconds",
}
AGREEMENT_KEYS = {
    "comparisonCount",
    "expectedTopHitCount",
    "topHitMatchCount",
    "exactRankMatchCount",
    "overlapAtKCount",
}
HOST_RECEIPT_KEYS = {
    "schemaVersion",
    "kind",
    "generatedAt",
    "sourceCommit",
    "toolchain",
    "fixtureVersion",
    "measurementPolicyVersion",
    "stabilityPolicyVersion",
    "buildConfiguration",
    "hostProfile",
    "host",
    "configuration",
    "outcome",
    "scales",
}
HOST_RECEIPT_CONFIGURATION_KEYS = {
    "dimension",
    "queryCount",
    "runsPerQuery",
    "resultLimit",
    "minimumStableObservations",
    "maximumTimingP95ToP50Ratio",
    "buildOrder",
}
HOST_RECEIPT_SCALE_KEYS = {
    "corpusSize",
    "state",
    "observationCount",
    "rawEmbeddingBytes",
    "controlDatabaseBytes",
    "fixturePreparationMilliseconds",
    "engines",
    "agreement",
}
HOST_RECEIPT_ENGINE_KEYS = {
    "engine",
    "buildMilliseconds",
    "queryWallMilliseconds",
    "maximumWithinObservationTimingP95ToP50Ratio",
    "resultCount",
}
HOST_RECEIPT_QUERY_KEYS = {
    "p50Observation",
    "p95Observation",
    "maximumObservation",
}
NEAREST_RANK_KEYS = {
    "sampleCount",
    "p50",
    "p95",
    "maximum",
}
HOST_RECEIPT_SCALE_STATES = {
    "pass",
    "incomplete",
    "unstable",
    "agreement-failed",
}
ENGINE_ORDER = ("accelerateExact", "sqliteVecExact")
BUILD_ORDER = "accelerate-control-then-sqlite-vec-v1"


class MatrixError(ValueError):
    """The input cannot support a comparable exact-path host receipt."""


def reject_duplicate_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise MatrixError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def read_json(path: Path, label: str) -> Any:
    try:
        return json.loads(
            path.read_text(encoding="utf-8"),
            object_pairs_hook=reject_duplicate_keys,
            parse_constant=lambda value: (_ for _ in ()).throw(
                MatrixError(f"{label} contains non-finite JSON: {value}")
            ),
        )
    except OSError as error:
        raise MatrixError(f"cannot read {label}") from error
    except json.JSONDecodeError as error:
        raise MatrixError(f"{label} is not valid JSON") from error


def read_observations(path: Path) -> list[Any]:
    try:
        text = sys.stdin.read() if str(path) == "-" else path.read_text(encoding="utf-8")
    except OSError as error:
        raise MatrixError("cannot read observation stream") from error
    observations = []
    for line_number, raw_line in enumerate(text.splitlines(), start=1):
        if not raw_line.strip():
            continue
        try:
            observations.append(
                json.loads(
                    raw_line,
                    object_pairs_hook=reject_duplicate_keys,
                    parse_constant=lambda value: (_ for _ in ()).throw(
                        MatrixError(
                            f"observation line {line_number} contains non-finite JSON: {value}"
                        )
                    ),
                )
            )
        except json.JSONDecodeError as error:
            raise MatrixError(
                f"observation line {line_number} is not valid JSON"
            ) from error
    if not observations:
        raise MatrixError("observation stream is empty")
    return observations


def exact_object(value: Any, keys: set[str], label: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise MatrixError(f"{label} must be an object")
    actual = set(value)
    if actual != keys:
        missing = sorted(keys - actual)
        extra = sorted(actual - keys)
        details = []
        if missing:
            details.append("missing " + ", ".join(missing))
        if extra:
            details.append("forbidden " + ", ".join(extra))
        raise MatrixError(f"{label} has an invalid shape: {'; '.join(details)}")
    return value


def integer(value: Any, label: str, minimum: int = 0) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value < minimum:
        raise MatrixError(f"{label} must be an integer >= {minimum}")
    return value


def finite(value: Any, label: str, minimum: float = 0) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise MatrixError(f"{label} must be numeric")
    number = float(value)
    if not math.isfinite(number) or number < minimum:
        raise MatrixError(f"{label} must be finite and >= {minimum}")
    return number


def bounded_string(value: Any, label: str, maximum: int = 256) -> str:
    if not isinstance(value, str) or not value or len(value) > maximum:
        raise MatrixError(f"{label} must be a nonempty bounded string")
    return value


def utc_timestamp(value: Any, label: str) -> str:
    timestamp = bounded_string(value, label, 40)
    if not timestamp.endswith("Z"):
        raise MatrixError(f"{label} must be a UTC timestamp")
    try:
        parsed = dt.datetime.fromisoformat(timestamp.removesuffix("Z") + "+00:00")
    except ValueError as error:
        raise MatrixError(f"{label} must be a UTC timestamp") from error
    if parsed.utcoffset() != dt.timedelta(0):
        raise MatrixError(f"{label} must be a UTC timestamp")
    return timestamp


def load_contract(path: Path) -> dict[str, Any]:
    raw = exact_object(read_json(path, "matrix contract"), CONTRACT_KEYS, "contract")
    if integer(raw["schemaVersion"], "contract.schemaVersion", 1) != 1:
        raise MatrixError("contract.schemaVersion must be 1")
    if raw["fixtureVersion"] != "synthetic-exact-path-v1":
        raise MatrixError("contract fixture is not supported")
    if (
        integer(
            raw["hostReceiptSchemaVersion"],
            "contract.hostReceiptSchemaVersion",
            1,
        )
        != 2
    ):
        raise MatrixError("contract host receipt schema is not supported")
    if raw["measurementPolicyVersion"] != "alternating-query-order-v1":
        raise MatrixError("contract measurement policy is not supported")
    if raw["stabilityPolicyVersion"] != "nearest-rank-p95-p50-v1":
        raise MatrixError("contract stability policy is not supported")
    if raw["buildConfiguration"] != "release":
        raise MatrixError("contract must require a Release build")
    scales = raw["canonicalScales"]
    if (
        not isinstance(scales, list)
        or any(
            isinstance(value, bool) or not isinstance(value, int)
            for value in scales
        )
        or scales != [1_000, 10_000, 50_000, 100_000]
    ):
        raise MatrixError("contract canonical scales are not supported")
    if (
        integer(raw["dimension"], "contract.dimension", 1) != 512
        or integer(raw["queryCount"], "contract.queryCount", 1) != 8
    ):
        raise MatrixError("contract query profile is not supported")
    if (
        integer(raw["runsPerQuery"], "contract.runsPerQuery", 1) != 5
        or integer(raw["resultLimit"], "contract.resultLimit", 1) != 10
    ):
        raise MatrixError("contract run profile is not supported")
    if (
        integer(
            raw["minimumStableObservations"],
            "contract.minimumStableObservations",
            1,
        )
        != 3
    ):
        raise MatrixError("contract must require three observations per scale")
    if finite(
        raw["maximumTimingP95ToP50Ratio"],
        "contract.maximumTimingP95ToP50Ratio",
        1,
    ) != 1.25:
        raise MatrixError("contract stability ratio is not supported")
    majors = raw["supportedOperatingSystemMajors"]
    if (
        not isinstance(majors, list)
        or any(
            isinstance(value, bool) or not isinstance(value, int)
            for value in majors
        )
        or majors != [15, 26]
    ):
        raise MatrixError("contract operating-system matrix is not supported")
    return raw


def load_profiles(path: Path) -> dict[str, tuple[int, int | None]]:
    raw = exact_object(
        read_json(path, "resource contract"),
        RESOURCE_CONTRACT_KEYS,
        "resource contract",
    )
    if integer(raw["schemaVersion"], "resource contract.schemaVersion", 1) != 2:
        raise MatrixError("resource contract schemaVersion must be 2")
    recording_input = exact_object(
        raw["recordingInput"],
        RECORDING_INPUT_KEYS,
        "resource contract recordingInput",
    )
    if (
        recording_input["generation"] != "public-synthetic-dual-channel-v1"
        or integer(
            recording_input["sampleRate"],
            "resource contract recordingInput.sampleRate",
            1,
        )
        != 16_000
        or integer(
            recording_input["chunkFrames"],
            "resource contract recordingInput.chunkFrames",
            1,
        )
        != 1_600
    ):
        raise MatrixError("resource contract recordingInput is not supported")
    profiles: dict[str, tuple[int, int | None]] = {}
    if not isinstance(raw["profiles"], list):
        raise MatrixError("resource contract profiles must be an array")
    for index, value in enumerate(raw["profiles"]):
        profile = exact_object(value, PROFILE_KEYS, f"resource profiles[{index}]")
        identifier = bounded_string(profile["id"], f"resource profiles[{index}].id", 64)
        if not PROFILE.fullmatch(identifier) or identifier in profiles:
            raise MatrixError("resource contract profile identifiers are invalid")
        minimum = integer(
            profile["minimumPhysicalMemoryBytes"],
            f"resource profiles[{index}].minimumPhysicalMemoryBytes",
            1,
        )
        maximum = profile["maximumPhysicalMemoryBytes"]
        if maximum is not None:
            maximum = integer(
                maximum,
                f"resource profiles[{index}].maximumPhysicalMemoryBytes",
                minimum,
            )
        profiles[identifier] = (minimum, maximum)
    if set(profiles) != {"memory-8gb", "memory-16gb", "reference"}:
        raise MatrixError("resource contract host profiles are not supported")
    return profiles


def validate_host(
    raw: Any,
    contract: dict[str, Any],
    profiles: dict[str, tuple[int, int | None]],
    profile_id: str,
    label: str,
) -> dict[str, Any]:
    host = exact_object(raw, HOST_KEYS, label)
    operating_system = bounded_string(host["operatingSystem"], f"{label}.operatingSystem")
    match = OPERATING_SYSTEM.fullmatch(operating_system)
    if match is None or int(match.group(1)) not in contract["supportedOperatingSystemMajors"]:
        raise MatrixError(f"{label} is not a supported Sequoia/Tahoe host")
    if host["architecture"] != "arm64":
        raise MatrixError(f"{label}.architecture must be arm64")
    integer(host["processorCount"], f"{label}.processorCount", 1)
    memory = integer(host["physicalMemoryBytes"], f"{label}.physicalMemoryBytes", 1)
    if profile_id not in profiles:
        raise MatrixError(f"unknown host profile: {profile_id}")
    minimum, maximum = profiles[profile_id]
    if memory < minimum or (maximum is not None and memory > maximum):
        raise MatrixError(f"{label} does not match host profile {profile_id}")
    return host


def validate_distribution(
    raw: Any,
    expected_count: int,
    label: str,
) -> dict[str, float | int]:
    distribution = exact_object(raw, DISTRIBUTION_KEYS, label)
    if integer(distribution["sampleCount"], f"{label}.sampleCount", 1) != expected_count:
        raise MatrixError(f"{label}.sampleCount is inconsistent")
    p50 = finite(distribution["p50Milliseconds"], f"{label}.p50Milliseconds")
    p95 = finite(distribution["p95Milliseconds"], f"{label}.p95Milliseconds")
    maximum = finite(distribution["maximumMilliseconds"], f"{label}.maximumMilliseconds")
    if not p50 <= p95 <= maximum:
        raise MatrixError(f"{label} percentiles are not monotonic")
    return {
        "sampleCount": expected_count,
        "p50Milliseconds": p50,
        "p95Milliseconds": p95,
        "maximumMilliseconds": maximum,
    }


def validate_observation(
    raw: Any,
    contract: dict[str, Any],
    profiles: dict[str, tuple[int, int | None]],
    profile_id: str,
    label: str,
) -> dict[str, Any]:
    observation = exact_object(raw, OBSERVATION_KEYS, label)
    if integer(observation["schemaVersion"], f"{label}.schemaVersion", 1) != 1:
        raise MatrixError(f"{label}.schemaVersion must be 1")
    for key in ("fixtureVersion", "measurementPolicyVersion", "buildConfiguration"):
        if observation[key] != contract[key]:
            raise MatrixError(f"{label}.{key} does not match the contract")
    host = validate_host(observation["host"], contract, profiles, profile_id, f"{label}.host")

    configuration = exact_object(
        observation["configuration"], CONFIGURATION_KEYS, f"{label}.configuration"
    )
    corpus_size = integer(
        configuration["corpusSize"], f"{label}.configuration.corpusSize", 1
    )
    if corpus_size not in contract["canonicalScales"]:
        raise MatrixError(f"{label} uses a noncanonical corpus size")
    for key in ("dimension", "queryCount", "runsPerQuery", "resultLimit"):
        configured = integer(
            configuration[key],
            f"{label}.configuration.{key}",
            1,
        )
        if configured != contract[key]:
            raise MatrixError(f"{label}.configuration.{key} does not match the contract")
    expected_raw_bytes = corpus_size * contract["dimension"] * 4
    if (
        integer(
            configuration["rawEmbeddingBytes"],
            f"{label}.configuration.rawEmbeddingBytes",
            1,
        )
        != expected_raw_bytes
    ):
        raise MatrixError(f"{label}.configuration.rawEmbeddingBytes is inconsistent")
    integer(
        configuration["controlDatabaseBytes"],
        f"{label}.configuration.controlDatabaseBytes",
        1,
    )
    finite(
        configuration["fixturePreparationMilliseconds"],
        f"{label}.configuration.fixturePreparationMilliseconds",
    )
    if configuration["buildOrder"] != BUILD_ORDER:
        raise MatrixError(f"{label}.configuration.buildOrder is not supported")

    engines = observation["engines"]
    if not isinstance(engines, list) or len(engines) != len(ENGINE_ORDER):
        raise MatrixError(f"{label}.engines must contain the two exact engines")
    parsed_engines = []
    sample_count = contract["queryCount"] * contract["runsPerQuery"]
    for index, expected_engine in enumerate(ENGINE_ORDER):
        engine = exact_object(engines[index], ENGINE_KEYS, f"{label}.engines[{index}]")
        if engine["engine"] != expected_engine:
            raise MatrixError(f"{label}.engines must use canonical order")
        if (
            integer(
                engine["resultCount"],
                f"{label}.{expected_engine}.resultCount",
                1,
            )
            != contract["resultLimit"]
        ):
            raise MatrixError(f"{label}.{expected_engine}.resultCount is incomplete")
        parsed_engines.append(
            {
                "engine": expected_engine,
                "buildMilliseconds": finite(
                    engine["buildMilliseconds"],
                    f"{label}.{expected_engine}.buildMilliseconds",
                ),
                "queryWallMilliseconds": validate_distribution(
                    engine["queryWallMilliseconds"],
                    sample_count,
                    f"{label}.{expected_engine}.queryWallMilliseconds",
                ),
                "resultCount": contract["resultLimit"],
            }
        )

    agreement = exact_object(observation["agreement"], AGREEMENT_KEYS, f"{label}.agreement")
    comparison_count = sample_count
    expected_overlap = comparison_count * contract["resultLimit"]
    if (
        integer(
            agreement["comparisonCount"],
            f"{label}.agreement.comparisonCount",
            1,
        )
        != comparison_count
    ):
        raise MatrixError(f"{label}.agreement.comparisonCount is inconsistent")
    if (
        integer(
            agreement["expectedTopHitCount"],
            f"{label}.agreement.expectedTopHitCount",
            1,
        )
        != comparison_count
    ):
        raise MatrixError(f"{label}.agreement.expectedTopHitCount is inconsistent")
    for key, maximum in (
        ("topHitMatchCount", comparison_count),
        ("exactRankMatchCount", comparison_count),
        ("overlapAtKCount", expected_overlap),
    ):
        count = integer(agreement[key], f"{label}.agreement.{key}")
        if count > maximum:
            raise MatrixError(f"{label}.agreement.{key} exceeds its bound")

    return {
        "host": host,
        "configuration": configuration,
        "engines": parsed_engines,
        "agreement": agreement,
    }


def nearest_rank(values: list[float]) -> dict[str, float | int]:
    if not values:
        raise MatrixError("cannot summarize an empty measurement set")
    ordered = sorted(values)

    def percentile(fraction: float) -> float:
        index = min(len(ordered) - 1, max(0, math.ceil(len(ordered) * fraction) - 1))
        return ordered[index]

    return {
        "sampleCount": len(ordered),
        "p50": percentile(0.50),
        "p95": percentile(0.95),
        "maximum": ordered[-1],
    }


def stable(distribution: dict[str, float | int], maximum_ratio: float) -> bool:
    p50 = float(distribution["p50"])
    p95 = float(distribution["p95"])
    if p50 == 0:
        return p95 == 0
    return p95 / p50 <= maximum_ratio


def query_observation_is_stable(
    distribution: dict[str, float | int], maximum_ratio: float
) -> bool:
    p50 = float(distribution["p50Milliseconds"])
    p95 = float(distribution["p95Milliseconds"])
    if p50 == 0:
        return p95 == 0
    return p95 / p50 <= maximum_ratio


def timing_ratio(p50: float, p95: float) -> float | None:
    if p50 == 0:
        return 1.0 if p95 == 0 else None
    return p95 / p50


def aggregate_scale(
    corpus_size: int,
    observations: list[dict[str, Any]],
    contract: dict[str, Any],
) -> dict[str, Any]:
    required = contract["minimumStableObservations"]
    if len(observations) > required:
        raise MatrixError(f"scale {corpus_size} has excess or duplicate observations")
    if len(observations) < required:
        return {
            "corpusSize": corpus_size,
            "state": "incomplete",
            "observationCount": len(observations),
            "rawEmbeddingBytes": corpus_size * contract["dimension"] * 4,
            "controlDatabaseBytes": None,
            "fixturePreparationMilliseconds": None,
            "engines": [],
            "agreement": None,
        }

    fixture = nearest_rank(
        [item["configuration"]["fixturePreparationMilliseconds"] for item in observations]
    )
    database_bytes = nearest_rank(
        [item["configuration"]["controlDatabaseBytes"] for item in observations]
    )
    maximum_ratio = contract["maximumTimingP95ToP50Ratio"]
    timing_stable = stable(fixture, maximum_ratio)
    engine_rows = []
    for engine_index, engine_name in enumerate(ENGINE_ORDER):
        engine_observations = [item["engines"][engine_index] for item in observations]
        build = nearest_rank([item["buildMilliseconds"] for item in engine_observations])
        p50 = nearest_rank(
            [item["queryWallMilliseconds"]["p50Milliseconds"] for item in engine_observations]
        )
        p95 = nearest_rank(
            [item["queryWallMilliseconds"]["p95Milliseconds"] for item in engine_observations]
        )
        maximum = nearest_rank(
            [item["queryWallMilliseconds"]["maximumMilliseconds"] for item in engine_observations]
        )
        internally_stable = all(
            query_observation_is_stable(item["queryWallMilliseconds"], maximum_ratio)
            for item in engine_observations
        )
        within_observation_ratios = [
            timing_ratio(
                float(item["queryWallMilliseconds"]["p50Milliseconds"]),
                float(item["queryWallMilliseconds"]["p95Milliseconds"]),
            )
            for item in engine_observations
        ]
        maximum_within_observation_ratio = (
            None
            if any(value is None for value in within_observation_ratios)
            else max(value for value in within_observation_ratios if value is not None)
        )
        timing_stable = (
            timing_stable
            and stable(build, maximum_ratio)
            and stable(p50, maximum_ratio)
            and stable(p95, maximum_ratio)
            and internally_stable
        )
        engine_rows.append(
            {
                "engine": engine_name,
                "buildMilliseconds": build,
                "queryWallMilliseconds": {
                    "p50Observation": p50,
                    "p95Observation": p95,
                    "maximumObservation": maximum,
                },
                "maximumWithinObservationTimingP95ToP50Ratio": (
                    maximum_within_observation_ratio
                ),
                "resultCount": contract["resultLimit"],
            }
        )

    agreement = {
        key: sum(item["agreement"][key] for item in observations)
        for key in AGREEMENT_KEYS
    }
    expected_comparisons = (
        required * contract["queryCount"] * contract["runsPerQuery"]
    )
    expected_overlap = expected_comparisons * contract["resultLimit"]
    result_agreement = (
        agreement["comparisonCount"] == expected_comparisons
        and agreement["expectedTopHitCount"] == expected_comparisons
        and agreement["topHitMatchCount"] == expected_comparisons
        and agreement["overlapAtKCount"] == expected_overlap
    )
    state = (
        "pass"
        if timing_stable and result_agreement
        else "unstable"
        if not timing_stable
        else "agreement-failed"
    )
    return {
        "corpusSize": corpus_size,
        "state": state,
        "observationCount": required,
        "rawEmbeddingBytes": corpus_size * contract["dimension"] * 4,
        "controlDatabaseBytes": database_bytes,
        "fixturePreparationMilliseconds": fixture,
        "engines": engine_rows,
        "agreement": agreement,
    }


def build_receipt(
    raw_observations: list[Any],
    contract: dict[str, Any],
    profiles: dict[str, tuple[int, int | None]],
    profile_id: str,
    source_commit: str,
    toolchain: str,
    generated_at: str | None = None,
) -> dict[str, Any]:
    if not COMMIT.fullmatch(source_commit):
        raise MatrixError("source commit must be a lowercase 40-character SHA")
    if not TOOLCHAIN.fullmatch(toolchain) or len(toolchain) > 160:
        raise MatrixError("toolchain must be one bounded Apple Swift version line")
    parsed = [
        validate_observation(value, contract, profiles, profile_id, f"observations[{index}]")
        for index, value in enumerate(raw_observations)
    ]
    if not parsed:
        raise MatrixError("observation stream is empty")
    canonical = [
        json.dumps(value, sort_keys=True, separators=(",", ":"))
        for value in raw_observations
    ]
    if len(set(canonical)) != len(canonical):
        raise MatrixError("observation stream repeats an identical observation")
    hosts = {json.dumps(item["host"], sort_keys=True) for item in parsed}
    if len(hosts) != 1:
        raise MatrixError("observations came from different hosts")
    host = parsed[0]["host"]
    by_scale = {scale: [] for scale in contract["canonicalScales"]}
    for item in parsed:
        by_scale[item["configuration"]["corpusSize"]].append(item)
    scales = [aggregate_scale(scale, by_scale[scale], contract) for scale in by_scale]
    outcome = "pass" if all(scale["state"] == "pass" for scale in scales) else "blocked"
    timestamp = generated_at or dt.datetime.now(dt.timezone.utc).isoformat().replace(
        "+00:00", "Z"
    )
    timestamp = utc_timestamp(timestamp, "receipt.generatedAt")
    return {
        "schemaVersion": contract["hostReceiptSchemaVersion"],
        "kind": "exact-path-shadow-host-receipt",
        "generatedAt": timestamp,
        "sourceCommit": source_commit,
        "toolchain": toolchain,
        "fixtureVersion": contract["fixtureVersion"],
        "measurementPolicyVersion": contract["measurementPolicyVersion"],
        "stabilityPolicyVersion": contract["stabilityPolicyVersion"],
        "buildConfiguration": contract["buildConfiguration"],
        "hostProfile": profile_id,
        "host": host,
        "configuration": {
            "dimension": contract["dimension"],
            "queryCount": contract["queryCount"],
            "runsPerQuery": contract["runsPerQuery"],
            "resultLimit": contract["resultLimit"],
            "minimumStableObservations": contract["minimumStableObservations"],
            "maximumTimingP95ToP50Ratio": contract[
                "maximumTimingP95ToP50Ratio"
            ],
            "buildOrder": BUILD_ORDER,
        },
        "outcome": outcome,
        "scales": scales,
    }


def validate_nearest_rank_distribution(
    raw: Any,
    expected_count: int,
    label: str,
    *,
    integral: bool = False,
) -> dict[str, float | int]:
    distribution = exact_object(raw, NEAREST_RANK_KEYS, label)
    if integer(distribution["sampleCount"], f"{label}.sampleCount", 1) != expected_count:
        raise MatrixError(f"{label}.sampleCount is inconsistent")

    def value(key: str) -> float | int:
        if integral:
            return integer(distribution[key], f"{label}.{key}")
        return finite(distribution[key], f"{label}.{key}")

    p50 = value("p50")
    p95 = value("p95")
    maximum = value("maximum")
    if not p50 <= p95 <= maximum:
        raise MatrixError(f"{label} percentiles are not monotonic")
    return {
        "sampleCount": expected_count,
        "p50": p50,
        "p95": p95,
        "maximum": maximum,
    }


def validate_host_receipt_scale(
    raw: Any,
    expected_corpus_size: int,
    contract: dict[str, Any],
    label: str,
) -> dict[str, Any]:
    scale = exact_object(raw, HOST_RECEIPT_SCALE_KEYS, label)
    corpus_size = integer(scale["corpusSize"], f"{label}.corpusSize", 1)
    if corpus_size != expected_corpus_size:
        raise MatrixError(f"{label}.corpusSize is not in canonical order")
    state = bounded_string(scale["state"], f"{label}.state", 32)
    if state not in HOST_RECEIPT_SCALE_STATES:
        raise MatrixError(f"{label}.state is not supported")
    observation_count = integer(scale["observationCount"], f"{label}.observationCount")
    required = contract["minimumStableObservations"]
    if observation_count > required:
        raise MatrixError(f"{label}.observationCount exceeds the contract")
    expected_raw_bytes = corpus_size * contract["dimension"] * 4
    if (
        integer(scale["rawEmbeddingBytes"], f"{label}.rawEmbeddingBytes", 1)
        != expected_raw_bytes
    ):
        raise MatrixError(f"{label}.rawEmbeddingBytes is inconsistent")

    if observation_count < required:
        if (
            state != "incomplete"
            or scale["controlDatabaseBytes"] is not None
            or scale["fixturePreparationMilliseconds"] is not None
            or scale["engines"] != []
            or scale["agreement"] is not None
        ):
            raise MatrixError(f"{label} has an inconsistent incomplete shape")
        return scale

    fixture = validate_nearest_rank_distribution(
        scale["fixturePreparationMilliseconds"],
        required,
        f"{label}.fixturePreparationMilliseconds",
    )
    validate_nearest_rank_distribution(
        scale["controlDatabaseBytes"],
        required,
        f"{label}.controlDatabaseBytes",
        integral=True,
    )
    timing_stable = stable(fixture, contract["maximumTimingP95ToP50Ratio"])

    engines = scale["engines"]
    if not isinstance(engines, list) or len(engines) != len(ENGINE_ORDER):
        raise MatrixError(f"{label}.engines must contain the two exact engines")
    for index, expected_engine in enumerate(ENGINE_ORDER):
        engine_label = f"{label}.engines[{index}]"
        engine = exact_object(engines[index], HOST_RECEIPT_ENGINE_KEYS, engine_label)
        if engine["engine"] != expected_engine:
            raise MatrixError(f"{label}.engines must use canonical order")
        build = validate_nearest_rank_distribution(
            engine["buildMilliseconds"],
            required,
            f"{engine_label}.buildMilliseconds",
        )
        query = exact_object(
            engine["queryWallMilliseconds"],
            HOST_RECEIPT_QUERY_KEYS,
            f"{engine_label}.queryWallMilliseconds",
        )
        p50 = validate_nearest_rank_distribution(
            query["p50Observation"],
            required,
            f"{engine_label}.queryWallMilliseconds.p50Observation",
        )
        p95 = validate_nearest_rank_distribution(
            query["p95Observation"],
            required,
            f"{engine_label}.queryWallMilliseconds.p95Observation",
        )
        maximum = validate_nearest_rank_distribution(
            query["maximumObservation"],
            required,
            f"{engine_label}.queryWallMilliseconds.maximumObservation",
        )
        for percentile in ("p50", "p95", "maximum"):
            if not (
                p50[percentile]
                <= p95[percentile]
                <= maximum[percentile]
            ):
                raise MatrixError(
                    f"{engine_label}.queryWallMilliseconds distributions are not monotonic"
                )
        within_ratio_raw = engine["maximumWithinObservationTimingP95ToP50Ratio"]
        within_ratio = (
            None
            if within_ratio_raw is None
            else finite(
                within_ratio_raw,
                f"{engine_label}.maximumWithinObservationTimingP95ToP50Ratio",
                1,
            )
        )
        maximum_p50 = float(p50["maximum"])
        maximum_p95 = float(p95["maximum"])
        if maximum_p50 == 0:
            expected_zero_ratio = 1.0 if maximum_p95 == 0 else None
            if within_ratio != expected_zero_ratio:
                raise MatrixError(
                    f"{engine_label}.maximumWithinObservationTimingP95ToP50Ratio "
                    "is inconsistent with zero-median evidence"
                )
        elif (
            within_ratio is not None
            and within_ratio + 1e-12 < maximum_p95 / maximum_p50
        ):
            raise MatrixError(
                f"{engine_label}.maximumWithinObservationTimingP95ToP50Ratio "
                "is below its aggregate lower bound"
            )
        timing_stable = (
            timing_stable
            and stable(build, contract["maximumTimingP95ToP50Ratio"])
            and stable(p50, contract["maximumTimingP95ToP50Ratio"])
            and stable(p95, contract["maximumTimingP95ToP50Ratio"])
            and within_ratio is not None
            and within_ratio <= contract["maximumTimingP95ToP50Ratio"]
        )
        if (
            integer(engine["resultCount"], f"{engine_label}.resultCount", 1)
            != contract["resultLimit"]
        ):
            raise MatrixError(f"{engine_label}.resultCount is inconsistent")

    agreement = exact_object(scale["agreement"], AGREEMENT_KEYS, f"{label}.agreement")
    expected_comparisons = required * contract["queryCount"] * contract["runsPerQuery"]
    expected_overlap = expected_comparisons * contract["resultLimit"]
    if (
        integer(
            agreement["comparisonCount"],
            f"{label}.agreement.comparisonCount",
            1,
        )
        != expected_comparisons
    ):
        raise MatrixError(f"{label}.agreement.comparisonCount is inconsistent")
    if (
        integer(
            agreement["expectedTopHitCount"],
            f"{label}.agreement.expectedTopHitCount",
            1,
        )
        != expected_comparisons
    ):
        raise MatrixError(f"{label}.agreement.expectedTopHitCount is inconsistent")
    for key, maximum in (
        ("topHitMatchCount", expected_comparisons),
        ("exactRankMatchCount", expected_comparisons),
        ("overlapAtKCount", expected_overlap),
    ):
        count = integer(agreement[key], f"{label}.agreement.{key}")
        if count > maximum:
            raise MatrixError(f"{label}.agreement.{key} exceeds its bound")
    result_agreement = (
        agreement["topHitMatchCount"] == expected_comparisons
        and agreement["overlapAtKCount"] == expected_overlap
    )
    expected_state = (
        "pass"
        if timing_stable and result_agreement
        else "unstable"
        if not timing_stable
        else "agreement-failed"
    )
    if state != expected_state:
        raise MatrixError(f"{label}.state is inconsistent with its aggregate evidence")
    return scale


def validate_host_receipt(
    raw: Any,
    contract: dict[str, Any],
    profiles: dict[str, tuple[int, int | None]],
    label: str = "host receipt",
) -> dict[str, Any]:
    receipt = exact_object(raw, HOST_RECEIPT_KEYS, label)
    if (
        integer(receipt["schemaVersion"], f"{label}.schemaVersion", 1)
        != contract["hostReceiptSchemaVersion"]
    ):
        raise MatrixError(f"{label}.schemaVersion is not supported")
    if receipt["kind"] != "exact-path-shadow-host-receipt":
        raise MatrixError(f"{label}.kind is not supported")
    utc_timestamp(receipt["generatedAt"], f"{label}.generatedAt")
    if not isinstance(receipt["sourceCommit"], str) or not COMMIT.fullmatch(
        receipt["sourceCommit"]
    ):
        raise MatrixError(f"{label}.sourceCommit is invalid")
    if not isinstance(receipt["toolchain"], str) or not TOOLCHAIN.fullmatch(
        receipt["toolchain"]
    ):
        raise MatrixError(f"{label}.toolchain is invalid")
    for key in (
        "fixtureVersion",
        "measurementPolicyVersion",
        "stabilityPolicyVersion",
        "buildConfiguration",
    ):
        if receipt[key] != contract[key]:
            raise MatrixError(f"{label}.{key} does not match the contract")
    profile = bounded_string(receipt["hostProfile"], f"{label}.hostProfile", 64)
    validate_host(receipt["host"], contract, profiles, profile, f"{label}.host")

    configuration = exact_object(
        receipt["configuration"],
        HOST_RECEIPT_CONFIGURATION_KEYS,
        f"{label}.configuration",
    )
    for key in (
        "dimension",
        "queryCount",
        "runsPerQuery",
        "resultLimit",
        "minimumStableObservations",
    ):
        if integer(configuration[key], f"{label}.configuration.{key}", 1) != contract[key]:
            raise MatrixError(f"{label}.configuration.{key} is inconsistent")
    if (
        finite(
            configuration["maximumTimingP95ToP50Ratio"],
            f"{label}.configuration.maximumTimingP95ToP50Ratio",
            1,
        )
        != contract["maximumTimingP95ToP50Ratio"]
    ):
        raise MatrixError(
            f"{label}.configuration.maximumTimingP95ToP50Ratio is inconsistent"
        )
    if configuration["buildOrder"] != BUILD_ORDER:
        raise MatrixError(f"{label}.configuration.buildOrder is inconsistent")

    scales = receipt["scales"]
    if not isinstance(scales, list) or len(scales) != len(contract["canonicalScales"]):
        raise MatrixError(f"{label}.scales must cover every canonical scale")
    validated_scales = [
        validate_host_receipt_scale(
            scales[index],
            corpus_size,
            contract,
            f"{label}.scales[{index}]",
        )
        for index, corpus_size in enumerate(contract["canonicalScales"])
    ]
    expected_outcome = (
        "pass"
        if all(scale["state"] == "pass" for scale in validated_scales)
        else "blocked"
    )
    if receipt["outcome"] != expected_outcome:
        raise MatrixError(f"{label}.outcome is inconsistent with its scales")
    return receipt


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Validate one content-free exact-path host matrix."
    )
    parser.add_argument("--input", type=Path, required=True, help="JSONL observations or -")
    parser.add_argument("--profile", required=True)
    parser.add_argument("--commit", required=True)
    parser.add_argument("--toolchain", required=True)
    parser.add_argument("--contract", type=Path, default=DEFAULT_CONTRACT)
    parser.add_argument(
        "--resource-contract", type=Path, default=DEFAULT_RESOURCE_CONTRACT
    )
    return parser


def main_from_args(arguments: list[str] | None = None) -> int:
    options = build_parser().parse_args(arguments)
    contract = load_contract(options.contract)
    profiles = load_profiles(options.resource_contract)
    observations = read_observations(options.input)
    receipt = build_receipt(
        observations,
        contract,
        profiles,
        options.profile,
        options.commit,
        options.toolchain,
    )
    print(json.dumps(receipt, sort_keys=True, separators=(",", ":")))
    return 0 if receipt["outcome"] == "pass" else 1


def main() -> int:
    try:
        return main_from_args()
    except MatrixError as error:
        print(f"exact-path matrix error: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
