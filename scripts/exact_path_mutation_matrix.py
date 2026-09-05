#!/usr/bin/env python3
"""Validate D218 observations into a threshold-free mutation host receipt."""

from __future__ import annotations

import argparse
import datetime as dt
import json
import sys
from pathlib import Path
from typing import Any


SCRIPT_DIRECTORY = Path(__file__).resolve().parent
if str(SCRIPT_DIRECTORY) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIRECTORY))

import exact_path_matrix as foundation


REPOSITORY = SCRIPT_DIRECTORY.parent
DEFAULT_CONTRACT = (
    REPOSITORY / "docs" / "evidence" / "exact-path-mutation-matrix.json"
)
DEFAULT_RESOURCE_CONTRACT = (
    REPOSITORY / "docs" / "evidence" / "resource-baseline-matrix.json"
)

CONTRACT_KEYS = {
    "schemaVersion",
    "hostReceiptSchemaVersion",
    "fixtureVersion",
    "measurementPolicyVersion",
    "reviewPolicyVersion",
    "buildConfiguration",
    "canonicalScales",
    "dimension",
    "runsPerBatch",
    "resultLimit",
    "batchSizes",
    "minimumObservations",
    "rebuildLifecycle",
    "mutationLifecycle",
    "supportedOperatingSystemMajors",
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
CONFIGURATION_KEYS = {
    "corpusSize",
    "dimension",
    "runsPerBatch",
    "resultLimit",
    "batchSizes",
    "rawEmbeddingBytes",
    "fixturePreparationMilliseconds",
    "rebuildLifecycle",
    "mutationLifecycle",
}
ENGINE_KEYS = {"engine", "fullRebuildMilliseconds", "mutations"}
MUTATION_KEYS = {"operation", "batchSize", "wallMilliseconds"}
AGREEMENT_KEYS = {
    "comparisonCount",
    "expectedTopHitCount",
    "topHitMatchCount",
    "exactRankMatchCount",
    "topKSetMatchCount",
}
RECEIPT_KEYS = {
    "schemaVersion",
    "kind",
    "generatedAt",
    "sourceCommit",
    "toolchain",
    "fixtureVersion",
    "measurementPolicyVersion",
    "reviewPolicyVersion",
    "buildConfiguration",
    "hostProfile",
    "host",
    "configuration",
    "outcome",
    "scales",
}
RECEIPT_CONFIGURATION_KEYS = {
    "dimension",
    "runsPerBatch",
    "resultLimit",
    "batchSizes",
    "minimumObservations",
    "rebuildLifecycle",
    "mutationLifecycle",
}
RECEIPT_SCALE_KEYS = {
    "corpusSize",
    "state",
    "observationCount",
    "rawEmbeddingBytes",
    "fixturePreparationMilliseconds",
    "engines",
    "agreement",
}
RECEIPT_ENGINE_KEYS = {
    "engine",
    "fullRebuildMilliseconds",
    "mutations",
}
RECEIPT_MUTATION_KEYS = {
    "operation",
    "batchSize",
    "wallMilliseconds",
}
RECEIPT_WALL_KEYS = {
    "p50Observation",
    "p95Observation",
    "maximumObservation",
    "withinObservationP95ToP50Ratio",
}
ENGINE_ORDER = ("accelerateExact", "sqliteVecExact")
OPERATION_ORDER = ("add", "update", "delete")
SCALE_STATES = {"review-required", "incomplete", "agreement-failed"}

MatrixError = foundation.MatrixError


def load_contract(path: Path) -> dict[str, Any]:
    raw = foundation.exact_object(
        foundation.read_json(path, "mutation matrix contract"),
        CONTRACT_KEYS,
        "contract",
    )
    expected_versions = {
        "schemaVersion": 1,
        "hostReceiptSchemaVersion": 1,
        "fixtureVersion": "synthetic-exact-path-mutation-v1",
        "measurementPolicyVersion": "alternating-mutation-engine-order-v1",
        "reviewPolicyVersion": "human-threshold-free-mutation-review-v1",
        "buildConfiguration": "release",
        "rebuildLifecycle":
            "control-source-publication-vs-candidate-prepared-vectors-v1",
        "mutationLifecycle":
            "control-authoritative-source-publication-vs-candidate-prepared-vectors-v1",
    }
    for key, expected in expected_versions.items():
        if raw[key] != expected:
            raise MatrixError(f"contract.{key} is not supported")
    if raw["canonicalScales"] != [1_000, 10_000, 50_000, 100_000]:
        raise MatrixError("contract canonical scales are not supported")
    if raw["batchSizes"] != [1, 10, 100]:
        raise MatrixError("contract batch sizes are not supported")
    for key, expected in (
        ("dimension", 512),
        ("runsPerBatch", 5),
        ("resultLimit", 10),
        ("minimumObservations", 3),
    ):
        if foundation.integer(raw[key], f"contract.{key}", 1) != expected:
            raise MatrixError(f"contract.{key} is not supported")
    majors = raw["supportedOperatingSystemMajors"]
    if (
        not isinstance(majors, list)
        or any(isinstance(value, bool) or not isinstance(value, int) for value in majors)
        or majors != [15, 26]
    ):
        raise MatrixError("contract operating-system matrix is not supported")
    return raw


def validate_distribution(
    raw: Any,
    expected_count: int,
    label: str,
) -> dict[str, float | int]:
    distribution = foundation.exact_object(
        raw,
        foundation.DISTRIBUTION_KEYS,
        label,
    )
    if (
        foundation.integer(
            distribution["sampleCount"],
            f"{label}.sampleCount",
            1,
        )
        != expected_count
    ):
        raise MatrixError(f"{label}.sampleCount is inconsistent")
    p50 = foundation.finite(
        distribution["p50Milliseconds"],
        f"{label}.p50Milliseconds",
    )
    p95 = foundation.finite(
        distribution["p95Milliseconds"],
        f"{label}.p95Milliseconds",
    )
    maximum = foundation.finite(
        distribution["maximumMilliseconds"],
        f"{label}.maximumMilliseconds",
    )
    if not p50 <= p95 <= maximum:
        raise MatrixError(f"{label} percentiles are not monotonic")
    return {
        "sampleCount": expected_count,
        "p50Milliseconds": p50,
        "p95Milliseconds": p95,
        "maximumMilliseconds": maximum,
    }


def expected_agreement(contract: dict[str, Any]) -> tuple[int, int]:
    comparisons = (
        1
        + len(contract["batchSizes"])
        * contract["runsPerBatch"]
        * len(OPERATION_ORDER)
    )
    expected_top_hits = (
        1
        + len(contract["batchSizes"])
        * contract["runsPerBatch"]
        * 2
    )
    return comparisons, expected_top_hits


def validate_observation(
    raw: Any,
    contract: dict[str, Any],
    profiles: dict[str, tuple[int, int | None]],
    profile_id: str,
    label: str,
) -> dict[str, Any]:
    observation = foundation.exact_object(raw, OBSERVATION_KEYS, label)
    if foundation.integer(
        observation["schemaVersion"],
        f"{label}.schemaVersion",
        1,
    ) != 1:
        raise MatrixError(f"{label}.schemaVersion must be 1")
    for key in ("fixtureVersion", "measurementPolicyVersion", "buildConfiguration"):
        if observation[key] != contract[key]:
            raise MatrixError(f"{label}.{key} does not match the contract")
    host = foundation.validate_host(
        observation["host"],
        contract,
        profiles,
        profile_id,
        f"{label}.host",
    )
    configuration = validate_configuration(
        observation["configuration"],
        contract,
        f"{label}.configuration",
    )
    engines = validate_engines(
        observation["engines"],
        contract,
        label,
    )
    agreement = validate_agreement(
        observation["agreement"],
        contract,
        f"{label}.agreement",
    )
    return {
        "host": host,
        "configuration": configuration,
        "engines": engines,
        "agreement": agreement,
    }


def validate_configuration(
    raw: Any,
    contract: dict[str, Any],
    label: str,
) -> dict[str, Any]:
    configuration = foundation.exact_object(raw, CONFIGURATION_KEYS, label)
    corpus_size = foundation.integer(
        configuration["corpusSize"],
        f"{label}.corpusSize",
        1,
    )
    if corpus_size not in contract["canonicalScales"]:
        raise MatrixError(f"{label}.corpusSize is not canonical")
    for key in ("dimension", "runsPerBatch", "resultLimit"):
        if foundation.integer(
            configuration[key],
            f"{label}.{key}",
            1,
        ) != contract[key]:
            raise MatrixError(f"{label}.{key} does not match the contract")
    if configuration["batchSizes"] != contract["batchSizes"]:
        raise MatrixError(f"{label}.batchSizes does not match the contract")
    expected_bytes = corpus_size * contract["dimension"] * 4
    if foundation.integer(
        configuration["rawEmbeddingBytes"],
        f"{label}.rawEmbeddingBytes",
        1,
    ) != expected_bytes:
        raise MatrixError(f"{label}.rawEmbeddingBytes is inconsistent")
    fixture = foundation.finite(
        configuration["fixturePreparationMilliseconds"],
        f"{label}.fixturePreparationMilliseconds",
    )
    for key in ("rebuildLifecycle", "mutationLifecycle"):
        if configuration[key] != contract[key]:
            raise MatrixError(f"{label}.{key} does not match the contract")
    return {
        **configuration,
        "fixturePreparationMilliseconds": fixture,
    }


def validate_engines(
    raw: Any,
    contract: dict[str, Any],
    label: str,
) -> list[dict[str, Any]]:
    if not isinstance(raw, list) or len(raw) != len(ENGINE_ORDER):
        raise MatrixError(f"{label}.engines must contain the two exact engines")
    expected_mutations = [
        (operation, batch)
        for batch in contract["batchSizes"]
        for operation in OPERATION_ORDER
    ]
    engines = []
    for engine_index, engine_name in enumerate(ENGINE_ORDER):
        engine_label = f"{label}.engines[{engine_index}]"
        engine = foundation.exact_object(raw[engine_index], ENGINE_KEYS, engine_label)
        if engine["engine"] != engine_name:
            raise MatrixError(f"{label}.engines must use canonical order")
        mutations = engine["mutations"]
        if not isinstance(mutations, list) or len(mutations) != len(expected_mutations):
            raise MatrixError(f"{engine_label}.mutations must cover every batch operation")
        parsed_mutations = []
        for mutation_index, (operation, batch_size) in enumerate(expected_mutations):
            mutation_label = f"{engine_label}.mutations[{mutation_index}]"
            mutation = foundation.exact_object(
                mutations[mutation_index],
                MUTATION_KEYS,
                mutation_label,
            )
            if (
                mutation["operation"] != operation
                or foundation.integer(
                    mutation["batchSize"],
                    f"{mutation_label}.batchSize",
                    1,
                )
                != batch_size
            ):
                raise MatrixError(f"{engine_label}.mutations must use canonical order")
            parsed_mutations.append({
                "operation": operation,
                "batchSize": batch_size,
                "wallMilliseconds": validate_distribution(
                    mutation["wallMilliseconds"],
                    contract["runsPerBatch"],
                    f"{mutation_label}.wallMilliseconds",
                ),
            })
        engines.append({
            "engine": engine_name,
            "fullRebuildMilliseconds": foundation.finite(
                engine["fullRebuildMilliseconds"],
                f"{engine_label}.fullRebuildMilliseconds",
            ),
            "mutations": parsed_mutations,
        })
    return engines


def validate_agreement(
    raw: Any,
    contract: dict[str, Any],
    label: str,
) -> dict[str, int]:
    agreement = foundation.exact_object(raw, AGREEMENT_KEYS, label)
    comparisons, expected_top_hits = expected_agreement(contract)
    if foundation.integer(
        agreement["comparisonCount"],
        f"{label}.comparisonCount",
        1,
    ) != comparisons:
        raise MatrixError(f"{label}.comparisonCount is inconsistent")
    if foundation.integer(
        agreement["expectedTopHitCount"],
        f"{label}.expectedTopHitCount",
        1,
    ) != expected_top_hits:
        raise MatrixError(f"{label}.expectedTopHitCount is inconsistent")
    result = {
        "comparisonCount": comparisons,
        "expectedTopHitCount": expected_top_hits,
    }
    for key in ("topHitMatchCount", "exactRankMatchCount", "topKSetMatchCount"):
        value = foundation.integer(agreement[key], f"{label}.{key}")
        if value > comparisons:
            raise MatrixError(f"{label}.{key} exceeds its bound")
        result[key] = value
    return result


def observation_wall(
    distributions: list[dict[str, float | int]],
) -> dict[str, Any]:
    ratios = [
        foundation.timing_ratio(
            float(distribution["p50Milliseconds"]),
            float(distribution["p95Milliseconds"]),
        )
        for distribution in distributions
    ]
    return {
        "p50Observation": foundation.nearest_rank([
            float(distribution["p50Milliseconds"])
            for distribution in distributions
        ]),
        "p95Observation": foundation.nearest_rank([
            float(distribution["p95Milliseconds"])
            for distribution in distributions
        ]),
        "maximumObservation": foundation.nearest_rank([
            float(distribution["maximumMilliseconds"])
            for distribution in distributions
        ]),
        "withinObservationP95ToP50Ratio": (
            None
            if any(ratio is None for ratio in ratios)
            else foundation.nearest_rank([
                float(ratio) for ratio in ratios if ratio is not None
            ])
        ),
    }


def aggregate_scale(
    corpus_size: int,
    observations: list[dict[str, Any]],
    contract: dict[str, Any],
) -> dict[str, Any]:
    required = contract["minimumObservations"]
    if len(observations) > required:
        raise MatrixError(f"scale {corpus_size} has excess observations")
    if len(observations) < required:
        return {
            "corpusSize": corpus_size,
            "state": "incomplete",
            "observationCount": len(observations),
            "rawEmbeddingBytes": corpus_size * contract["dimension"] * 4,
            "fixturePreparationMilliseconds": None,
            "engines": [],
            "agreement": None,
        }
    engine_rows = []
    mutation_count = len(contract["batchSizes"]) * len(OPERATION_ORDER)
    for engine_index, engine_name in enumerate(ENGINE_ORDER):
        source_engines = [item["engines"][engine_index] for item in observations]
        mutations = []
        for mutation_index in range(mutation_count):
            source_mutations = [
                engine["mutations"][mutation_index]
                for engine in source_engines
            ]
            mutations.append({
                "operation": source_mutations[0]["operation"],
                "batchSize": source_mutations[0]["batchSize"],
                "wallMilliseconds": observation_wall([
                    mutation["wallMilliseconds"]
                    for mutation in source_mutations
                ]),
            })
        engine_rows.append({
            "engine": engine_name,
            "fullRebuildMilliseconds": foundation.nearest_rank([
                float(engine["fullRebuildMilliseconds"])
                for engine in source_engines
            ]),
            "mutations": mutations,
        })
    agreement = {
        key: sum(item["agreement"][key] for item in observations)
        for key in AGREEMENT_KEYS
    }
    comparisons, expected_top_hits = expected_agreement(contract)
    expected_comparisons = required * comparisons
    expected_hits = required * expected_top_hits
    agreement_complete = (
        agreement["comparisonCount"] == expected_comparisons
        and agreement["expectedTopHitCount"] == expected_hits
        and agreement["topHitMatchCount"] == expected_comparisons
        and agreement["topKSetMatchCount"] == expected_comparisons
    )
    return {
        "corpusSize": corpus_size,
        "state": "review-required" if agreement_complete else "agreement-failed",
        "observationCount": required,
        "rawEmbeddingBytes": corpus_size * contract["dimension"] * 4,
        "fixturePreparationMilliseconds": foundation.nearest_rank([
            item["configuration"]["fixturePreparationMilliseconds"]
            for item in observations
        ]),
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
    if not raw_observations:
        raise MatrixError("observation stream is empty")
    if not isinstance(source_commit, str) or not foundation.COMMIT.fullmatch(
        source_commit
    ):
        raise MatrixError("source commit is invalid")
    if not isinstance(toolchain, str) or not foundation.TOOLCHAIN.fullmatch(
        toolchain
    ):
        raise MatrixError("toolchain is invalid")
    generated_at = generated_at or (
        dt.datetime.now(dt.timezone.utc)
        .isoformat(timespec="seconds")
        .replace("+00:00", "Z")
    )
    foundation.utc_timestamp(generated_at, "generatedAt")
    validated = [
        validate_observation(
            observation,
            contract,
            profiles,
            profile_id,
            f"observations[{index}]",
        )
        for index, observation in enumerate(raw_observations)
    ]
    canonical = [
        json.dumps(item, sort_keys=True, separators=(",", ":"))
        for item in validated
    ]
    if len(set(canonical)) != len(canonical):
        raise MatrixError("observation stream repeats an identical observation")
    host = validated[0]["host"]
    if any(item["host"] != host for item in validated[1:]):
        raise MatrixError("observation stream mixes different hosts")
    scales = [
        aggregate_scale(
            corpus_size,
            [
                item
                for item in validated
                if item["configuration"]["corpusSize"] == corpus_size
            ],
            contract,
        )
        for corpus_size in contract["canonicalScales"]
    ]
    outcome = (
        "review-required"
        if all(scale["state"] == "review-required" for scale in scales)
        else "blocked"
    )
    receipt = {
        "schemaVersion": contract["hostReceiptSchemaVersion"],
        "kind": "exact-path-mutation-host-receipt",
        "generatedAt": generated_at,
        "sourceCommit": source_commit,
        "toolchain": toolchain,
        "fixtureVersion": contract["fixtureVersion"],
        "measurementPolicyVersion": contract["measurementPolicyVersion"],
        "reviewPolicyVersion": contract["reviewPolicyVersion"],
        "buildConfiguration": contract["buildConfiguration"],
        "hostProfile": profile_id,
        "host": host,
        "configuration": {
            "dimension": contract["dimension"],
            "runsPerBatch": contract["runsPerBatch"],
            "resultLimit": contract["resultLimit"],
            "batchSizes": contract["batchSizes"],
            "minimumObservations": contract["minimumObservations"],
            "rebuildLifecycle": contract["rebuildLifecycle"],
            "mutationLifecycle": contract["mutationLifecycle"],
        },
        "outcome": outcome,
        "scales": scales,
    }
    return validate_host_receipt(receipt, contract, profiles)


def validate_nearest_rank(
    raw: Any,
    expected_count: int,
    label: str,
    minimum: float = 0,
) -> dict[str, float | int]:
    distribution = foundation.exact_object(
        raw,
        foundation.NEAREST_RANK_KEYS,
        label,
    )
    if foundation.integer(
        distribution["sampleCount"],
        f"{label}.sampleCount",
        1,
    ) != expected_count:
        raise MatrixError(f"{label}.sampleCount is inconsistent")
    p50 = foundation.finite(distribution["p50"], f"{label}.p50", minimum)
    p95 = foundation.finite(distribution["p95"], f"{label}.p95", minimum)
    maximum = foundation.finite(
        distribution["maximum"],
        f"{label}.maximum",
        minimum,
    )
    if not p50 <= p95 <= maximum:
        raise MatrixError(f"{label} percentiles are not monotonic")
    return distribution


def validate_receipt_wall(
    raw: Any,
    required: int,
    label: str,
) -> dict[str, Any]:
    wall = foundation.exact_object(raw, RECEIPT_WALL_KEYS, label)
    for key in ("p50Observation", "p95Observation", "maximumObservation"):
        validate_nearest_rank(wall[key], required, f"{label}.{key}")
    ratios = wall["withinObservationP95ToP50Ratio"]
    if ratios is not None:
        validate_nearest_rank(
            ratios,
            required,
            f"{label}.withinObservationP95ToP50Ratio",
            1,
        )
    return wall


def validate_receipt_scale(
    raw: Any,
    corpus_size: int,
    contract: dict[str, Any],
    label: str,
) -> dict[str, Any]:
    scale = foundation.exact_object(raw, RECEIPT_SCALE_KEYS, label)
    if foundation.integer(
        scale["corpusSize"],
        f"{label}.corpusSize",
        1,
    ) != corpus_size:
        raise MatrixError(f"{label}.corpusSize is inconsistent")
    state = foundation.bounded_string(scale["state"], f"{label}.state", 32)
    if state not in SCALE_STATES:
        raise MatrixError(f"{label}.state is invalid")
    count = foundation.integer(scale["observationCount"], f"{label}.observationCount")
    required = contract["minimumObservations"]
    if count > required:
        raise MatrixError(f"{label}.observationCount exceeds the contract")
    expected_bytes = corpus_size * contract["dimension"] * 4
    if foundation.integer(
        scale["rawEmbeddingBytes"],
        f"{label}.rawEmbeddingBytes",
        1,
    ) != expected_bytes:
        raise MatrixError(f"{label}.rawEmbeddingBytes is inconsistent")
    if count < required:
        if (
            state != "incomplete"
            or scale["fixturePreparationMilliseconds"] is not None
            or scale["engines"] != []
            or scale["agreement"] is not None
        ):
            raise MatrixError(f"{label} incomplete state is inconsistent")
        return scale
    if state == "incomplete":
        raise MatrixError(f"{label} complete evidence cannot be incomplete")
    validate_nearest_rank(
        scale["fixturePreparationMilliseconds"],
        required,
        f"{label}.fixturePreparationMilliseconds",
    )
    validate_receipt_engines(scale["engines"], contract, label)
    agreement_complete = validate_receipt_agreement(
        scale["agreement"],
        contract,
        required,
        f"{label}.agreement",
    )
    expected_state = "review-required" if agreement_complete else "agreement-failed"
    if state != expected_state:
        raise MatrixError(f"{label}.state is inconsistent with agreement")
    return scale


def validate_receipt_engines(
    raw: Any,
    contract: dict[str, Any],
    label: str,
) -> None:
    if not isinstance(raw, list) or len(raw) != len(ENGINE_ORDER):
        raise MatrixError(f"{label}.engines must contain the two exact engines")
    required = contract["minimumObservations"]
    expected_mutations = [
        (operation, batch)
        for batch in contract["batchSizes"]
        for operation in OPERATION_ORDER
    ]
    for engine_index, engine_name in enumerate(ENGINE_ORDER):
        engine_label = f"{label}.engines[{engine_index}]"
        engine = foundation.exact_object(
            raw[engine_index],
            RECEIPT_ENGINE_KEYS,
            engine_label,
        )
        if engine["engine"] != engine_name:
            raise MatrixError(f"{label}.engines must use canonical order")
        validate_nearest_rank(
            engine["fullRebuildMilliseconds"],
            required,
            f"{engine_label}.fullRebuildMilliseconds",
        )
        mutations = engine["mutations"]
        if not isinstance(mutations, list) or len(mutations) != len(expected_mutations):
            raise MatrixError(f"{engine_label}.mutations are incomplete")
        for mutation_index, (operation, batch_size) in enumerate(expected_mutations):
            mutation_label = f"{engine_label}.mutations[{mutation_index}]"
            mutation = foundation.exact_object(
                mutations[mutation_index],
                RECEIPT_MUTATION_KEYS,
                mutation_label,
            )
            if (
                mutation["operation"] != operation
                or foundation.integer(
                    mutation["batchSize"],
                    f"{mutation_label}.batchSize",
                    1,
                )
                != batch_size
            ):
                raise MatrixError(f"{engine_label}.mutations must use canonical order")
            validate_receipt_wall(
                mutation["wallMilliseconds"],
                required,
                f"{mutation_label}.wallMilliseconds",
            )


def validate_receipt_agreement(
    raw: Any,
    contract: dict[str, Any],
    required: int,
    label: str,
) -> bool:
    agreement = foundation.exact_object(raw, AGREEMENT_KEYS, label)
    comparisons, expected_hits = expected_agreement(contract)
    expected_comparisons = comparisons * required
    expected_top_hits = expected_hits * required
    if foundation.integer(
        agreement["comparisonCount"],
        f"{label}.comparisonCount",
        1,
    ) != expected_comparisons:
        raise MatrixError(f"{label}.comparisonCount is inconsistent")
    if foundation.integer(
        agreement["expectedTopHitCount"],
        f"{label}.expectedTopHitCount",
        1,
    ) != expected_top_hits:
        raise MatrixError(f"{label}.expectedTopHitCount is inconsistent")
    values = {}
    for key in ("topHitMatchCount", "exactRankMatchCount", "topKSetMatchCount"):
        values[key] = foundation.integer(agreement[key], f"{label}.{key}")
        if values[key] > expected_comparisons:
            raise MatrixError(f"{label}.{key} exceeds its bound")
    return (
        values["topHitMatchCount"] == expected_comparisons
        and values["topKSetMatchCount"] == expected_comparisons
    )


def validate_host_receipt(
    raw: Any,
    contract: dict[str, Any],
    profiles: dict[str, tuple[int, int | None]],
    label: str = "mutation host receipt",
) -> dict[str, Any]:
    receipt = foundation.exact_object(raw, RECEIPT_KEYS, label)
    if foundation.integer(
        receipt["schemaVersion"],
        f"{label}.schemaVersion",
        1,
    ) != contract["hostReceiptSchemaVersion"]:
        raise MatrixError(f"{label}.schemaVersion is not supported")
    if receipt["kind"] != "exact-path-mutation-host-receipt":
        raise MatrixError(f"{label}.kind is not supported")
    foundation.utc_timestamp(receipt["generatedAt"], f"{label}.generatedAt")
    if not isinstance(receipt["sourceCommit"], str) or not foundation.COMMIT.fullmatch(
        receipt["sourceCommit"]
    ):
        raise MatrixError(f"{label}.sourceCommit is invalid")
    if not isinstance(receipt["toolchain"], str) or not foundation.TOOLCHAIN.fullmatch(
        receipt["toolchain"]
    ):
        raise MatrixError(f"{label}.toolchain is invalid")
    for key in (
        "fixtureVersion",
        "measurementPolicyVersion",
        "reviewPolicyVersion",
        "buildConfiguration",
    ):
        if receipt[key] != contract[key]:
            raise MatrixError(f"{label}.{key} does not match the contract")
    profile_id = foundation.bounded_string(
        receipt["hostProfile"],
        f"{label}.hostProfile",
        64,
    )
    foundation.validate_host(
        receipt["host"],
        contract,
        profiles,
        profile_id,
        f"{label}.host",
    )
    configuration = foundation.exact_object(
        receipt["configuration"],
        RECEIPT_CONFIGURATION_KEYS,
        f"{label}.configuration",
    )
    for key in ("dimension", "runsPerBatch", "resultLimit", "minimumObservations"):
        if foundation.integer(
            configuration[key],
            f"{label}.configuration.{key}",
            1,
        ) != contract[key]:
            raise MatrixError(f"{label}.configuration.{key} is inconsistent")
    for key in ("batchSizes", "rebuildLifecycle", "mutationLifecycle"):
        if configuration[key] != contract[key]:
            raise MatrixError(f"{label}.configuration.{key} is inconsistent")
    scales = receipt["scales"]
    if not isinstance(scales, list) or len(scales) != len(contract["canonicalScales"]):
        raise MatrixError(f"{label}.scales must cover every canonical scale")
    validated_scales = [
        validate_receipt_scale(
            scales[index],
            corpus_size,
            contract,
            f"{label}.scales[{index}]",
        )
        for index, corpus_size in enumerate(contract["canonicalScales"])
    ]
    expected_outcome = (
        "review-required"
        if all(scale["state"] == "review-required" for scale in validated_scales)
        else "blocked"
    )
    if receipt["outcome"] != expected_outcome:
        raise MatrixError(f"{label}.outcome is inconsistent with its scales")
    return receipt


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Validate one threshold-free exact-path mutation host matrix."
    )
    parser.add_argument("--input", type=Path, required=True, help="JSONL observations or -")
    parser.add_argument("--profile", required=True)
    parser.add_argument("--commit", required=True)
    parser.add_argument("--toolchain", required=True)
    parser.add_argument("--contract", type=Path, default=DEFAULT_CONTRACT)
    parser.add_argument(
        "--resource-contract",
        type=Path,
        default=DEFAULT_RESOURCE_CONTRACT,
    )
    return parser


def main_from_args(arguments: list[str] | None = None) -> int:
    options = build_parser().parse_args(arguments)
    contract = load_contract(options.contract)
    profiles = foundation.load_profiles(options.resource_contract)
    observations = foundation.read_observations(options.input)
    receipt = build_receipt(
        observations,
        contract,
        profiles,
        options.profile,
        options.commit,
        options.toolchain,
    )
    print(json.dumps(receipt, sort_keys=True, separators=(",", ":")))
    return 0 if receipt["outcome"] == "review-required" else 1


def main() -> int:
    try:
        return main_from_args()
    except MatrixError as error:
        print(f"exact-path mutation matrix error: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
