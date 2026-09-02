#!/usr/bin/env python3
"""Run and attest the finite, autonomous Portavoz candidate qualification."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import re
import shutil
import subprocess
import sys
import time
import wave
import xml.etree.ElementTree as ET
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterable, Sequence

import apuntador_leak_baseline
import long_capture_evidence
import perf_host_readiness
import release_reliability
import resource_baseline


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_CONTRACT = ROOT / "docs" / "evidence" / "candidate-automation.json"
DEFAULT_OUTPUT_PARENT = ROOT / "dist" / "release-readiness"
CONTRACT_SCHEMA_VERSION = 6
PERF_LEDGER_SCHEMA_VERSION = 1
PERFORMANCE_CONFIRMATION_SCHEMA_VERSION = 2
UI_BUDGET_SCHEMA_VERSION = 1
UI_RECEIPT_SCHEMA_VERSION = 3
UI_MEASUREMENT_POLICY = "xcresult-duration-with-activity-boundary-exclusions-v2"
UI_HARNESS_NOISE_THRESHOLD_SECONDS = 1.0
EXPECTED_PERFORMANCE_CONFIRMATION_RUNS = 3
EXPECTED_PERFORMANCE_ARTIFACTS = (
    "host-readiness.json",
    "host-readiness-semantic.json",
    "host-readiness-spotlight.json",
    "ledger.json",
    "ledger.md",
    "scale.json",
    "semantic.json",
    "spotlight.json",
)
EXPECTED_MODEL_CLASSES = (
    "DiarizationIntegrationTests",
    "FoundationModelIntegrationTests",
    "MeetingTypeDetectorIntegrationTests",
    "ObjectiveCheckDetectorShapeTests",
    "ParakeetIntegrationTests",
    "SentenceEmbedderIntegrationTests",
)
EXPECTED_UPGRADE_RECOVERY_CLASSES = (
    "BackupFailureRecoveryStoreTests",
    "LibraryMarkdownBackupRecoveryStoreTests",
    "MeetingStoreLaunchRecoveryTests",
    "ProcessingJobPersistenceTests",
    "RecoverInterruptedMeetingsUseCaseTests",
    "RecoverLibraryMarkdownBackupTests",
    "StorageUpgradeTests",
)
EXPECTED_RESOURCE_SCENARIOS = (
    "ask",
    "idle",
    "indexing",
    "recording",
    "recording-batch",
    "recording-indexing",
    "refine",
    "stop",
    "summary",
)
EXPECTED_UI_LOCALES = ("en", "es")
EXPECTED_LEAK_SCENARIOS = apuntador_leak_baseline.EXPECTED_SCENARIOS
EXPECTED_CONVERSATION_VOICES = ("Daniel", "Paulina")
EXPECTED_CONVERSATION_SEQUENCE = ("Daniel", "Paulina", "Daniel", "Paulina")
EXPECTED_CONVERSATION_SILENCE_MILLISECONDS = 700
MINIMUM_CONVERSATION_TURN_WORDS = 50
MAXIMUM_CONVERSATION_TURN_WORDS = 90
MINIMUM_CONVERSATION_DURATION_SECONDS = 60
EXPECTED_CONTRACT_PATHS = {
    "modelFixture": "Fixtures/CandidateAutomation/public-model-lane-en-v1.txt",
    "modelConversation": (
        "Fixtures/CandidateAutomation/public-diarization-en-es-v1.txt"
    ),
    "performance": "docs/evidence/perf-thresholds.json",
    "resource": "docs/evidence/resource-baseline-matrix.json",
    "memoryLeaks": "docs/evidence/apuntador-leak-baseline.json",
    "ui": "docs/evidence/ui-test-runtime-budget.json",
}
EXECUTED_PATTERN = re.compile(r"Executed\s+([0-9]+)\s+tests?,")
SKIPPED_PATTERN = re.compile(r"([0-9]+)\s+tests?\s+skipped")


class CandidateAutomationError(ValueError):
    """A fail-closed candidate qualification error."""


def exact_schema_version(value: Any, expected: int, label: str) -> None:
    if isinstance(value, bool) or not isinstance(value, int) or value != expected:
        raise CandidateAutomationError(f"{label} must be {expected}")


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def exact_object(
    value: Any,
    label: str,
    required: Sequence[str],
    optional: Sequence[str] = (),
) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise CandidateAutomationError(f"{label} must be an object")
    required_keys = set(required)
    allowed_keys = required_keys | set(optional)
    missing = required_keys - value.keys()
    extra = value.keys() - allowed_keys
    if missing:
        raise CandidateAutomationError(
            f"{label} is missing keys: {', '.join(sorted(missing))}"
        )
    if extra:
        raise CandidateAutomationError(
            f"{label} contains forbidden keys: {', '.join(sorted(extra))}"
        )
    return value


def string_list(value: Any, label: str) -> tuple[str, ...]:
    if not isinstance(value, list) or not value:
        raise CandidateAutomationError(f"{label} must be a non-empty array")
    if any(not isinstance(item, str) or not item for item in value):
        raise CandidateAutomationError(f"{label} must contain non-empty strings")
    if len(set(value)) != len(value):
        raise CandidateAutomationError(f"{label} contains duplicates")
    return tuple(value)


def finite_nonnegative(value: Any, label: str) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise CandidateAutomationError(f"{label} must be numeric")
    number = float(value)
    if not math.isfinite(number) or number < 0:
        raise CandidateAutomationError(f"{label} must be finite and non-negative")
    return number


def parse_public_conversation(text: str) -> tuple[tuple[str, str], ...]:
    if not 160 <= len(text) <= 3_000:
        raise CandidateAutomationError(
            "candidate conversation fixture must be bounded"
        )
    pattern = re.compile(
        r"\A\s*\[\[voice Daniel\]\]\s*(.*?)\s*"
        r"\[\[slnc 700\]\]\s*"
        r"\[\[voice Paulina\]\]\s*(.*?)\s*"
        r"\[\[slnc 700\]\]\s*"
        r"\[\[voice Daniel\]\]\s*(.*?)\s*"
        r"\[\[slnc 700\]\]\s*"
        r"\[\[voice Paulina\]\]\s*(.*?)\s*\Z",
        re.DOTALL,
    )
    match = pattern.fullmatch(text)
    if match is None:
        raise CandidateAutomationError(
            "candidate conversation fixture must have four bounded, "
            "long, alternating Daniel/Paulina turns"
        )
    turns = tuple(
        (voice, match.group(index + 1).strip())
        for index, voice in enumerate(EXPECTED_CONVERSATION_SEQUENCE)
    )
    word_counts = tuple(len(turn.split()) for _, turn in turns)
    if (
        any("[[" in turn or "]]" in turn for _, turn in turns)
        or any(
            not MINIMUM_CONVERSATION_TURN_WORDS
            <= count
            <= MAXIMUM_CONVERSATION_TURN_WORDS
            for count in word_counts
        )
    ):
        raise CandidateAutomationError(
            "candidate conversation fixture must have four bounded, "
            "long, alternating Daniel/Paulina turns"
        )
    return turns


def load_json(path: Path, label: str, maximum_bytes: int = 2 * 1024 * 1024) -> Any:
    if not path.is_file():
        raise CandidateAutomationError(f"{label} not found: {path}")
    if path.stat().st_size > maximum_bytes:
        raise CandidateAutomationError(f"{label} exceeds the size limit")

    def reject_duplicate_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
        result: dict[str, Any] = {}
        for key, value in pairs:
            if key in result:
                raise CandidateAutomationError(f"{label} repeats key: {key}")
            result[key] = value
        return result

    try:
        return json.loads(
            path.read_text(encoding="utf-8"),
            object_pairs_hook=reject_duplicate_keys,
        )
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise CandidateAutomationError(f"{label} is not valid UTF-8 JSON") from error


def tracked_path(root: Path, raw: Any, label: str, expected: str) -> Path:
    if raw != expected:
        raise CandidateAutomationError(f"{label} must be {expected}")
    path = (root / expected).resolve()
    try:
        path.relative_to(root.resolve())
    except ValueError as error:
        raise CandidateAutomationError(f"{label} escapes the repository") from error
    if not path.is_file():
        raise CandidateAutomationError(f"{label} does not exist: {path}")
    return path


def validate_contract(document: Any, root: Path = ROOT) -> dict[str, Any]:
    contract = exact_object(
        document,
        "candidate contract",
        (
            "schemaVersion",
            "kind",
            "proofs",
            "modelFixture",
            "modelGatedTestClasses",
            "upgradeRecoveryTestClasses",
            "performance",
            "resource",
            "memoryLeaks",
            "ui",
        ),
    )
    exact_schema_version(
        contract["schemaVersion"],
        CONTRACT_SCHEMA_VERSION,
        "candidate contract.schemaVersion",
    )
    if contract["kind"] != "candidate-automation-contract":
        raise CandidateAutomationError(
            "candidate contract.kind must be candidate-automation-contract"
        )

    model_fixture = exact_object(
        contract["modelFixture"],
        "candidate contract.modelFixture",
        (
            "text",
            "conversationText",
            "conversationVoices",
            "systemVoice",
            "rateWordsPerMinute",
        ),
    )
    model_fixture_path = tracked_path(
        root,
        model_fixture["text"],
        "candidate contract.modelFixture.text",
        EXPECTED_CONTRACT_PATHS["modelFixture"],
    )
    conversation_fixture_path = tracked_path(
        root,
        model_fixture["conversationText"],
        "candidate contract.modelFixture.conversationText",
        EXPECTED_CONTRACT_PATHS["modelConversation"],
    )
    if string_list(
        model_fixture["conversationVoices"],
        "candidate contract.modelFixture.conversationVoices",
    ) != EXPECTED_CONVERSATION_VOICES:
        raise CandidateAutomationError(
            "candidate contract.modelFixture.conversationVoices drifted"
        )
    try:
        spoken_text = model_fixture_path.read_text(encoding="utf-8")
        conversation_text = conversation_fixture_path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError) as error:
        raise CandidateAutomationError("candidate model fixture text is unreadable") from error
    if not 80 <= len(spoken_text) <= 2_000 or "[[" in spoken_text:
        raise CandidateAutomationError(
            "candidate spoken fixture text is empty, unbounded, or directive-bearing"
        )
    conversation_turns = parse_public_conversation(conversation_text)
    if model_fixture["systemVoice"] != "Samantha":
        raise CandidateAutomationError(
            "candidate contract.modelFixture.systemVoice must be Samantha"
        )
    fixture_rate = model_fixture["rateWordsPerMinute"]
    if (
        isinstance(fixture_rate, bool)
        or not isinstance(fixture_rate, int)
        or fixture_rate != 170
    ):
        raise CandidateAutomationError(
            "candidate contract.modelFixture.rateWordsPerMinute must be 170"
        )

    expected_proofs = tuple(
        release_reliability.QUALIFICATION_RECEIPTS["candidate-automation"][
            "proofs"
        ]
    )
    if string_list(contract["proofs"], "candidate contract.proofs") != expected_proofs:
        raise CandidateAutomationError(
            "candidate contract.proofs must match the release-admission scope exactly"
        )
    if (
        string_list(
            contract["modelGatedTestClasses"],
            "candidate contract.modelGatedTestClasses",
        )
        != EXPECTED_MODEL_CLASSES
    ):
        raise CandidateAutomationError("candidate contract model classes drifted")
    if (
        string_list(
            contract["upgradeRecoveryTestClasses"],
            "candidate contract.upgradeRecoveryTestClasses",
        )
        != EXPECTED_UPGRADE_RECOVERY_CLASSES
    ):
        raise CandidateAutomationError(
            "candidate contract upgrade/recovery classes drifted"
        )

    performance = exact_object(
        contract["performance"],
        "candidate contract.performance",
        (
            "thresholdContract",
            "binaryPolicy",
            "confirmationRuns",
            "hostReadiness",
            "requiredMeasuredMetricIDs",
            "allowedNotMeasuredMetricIDs",
            "acceptedMeasuredStates",
        ),
    )
    if performance["binaryPolicy"] != "single-exact-release-build-sha256-v1":
        raise CandidateAutomationError(
            "candidate performance binary policy must require one exact Release build"
        )
    host_readiness = exact_object(
        performance["hostReadiness"],
        "candidate contract.performance.hostReadiness",
        (
            "version",
            "maximumWaitSeconds",
            "sampleIntervalSeconds",
            "requiredConsecutiveSamples",
            "maximumCPUCapacityFraction",
            "maximumLoadPerProcessor",
            "maximumInterferenceCPUPercent",
            "throughputCalibration",
        ),
    )
    if host_readiness["version"] != perf_host_readiness.POLICY_VERSION:
        raise CandidateAutomationError(
            "candidate performance host-readiness policy version drifted"
        )
    calibration = exact_object(
        host_readiness["throughputCalibration"],
        "candidate contract.performance.hostReadiness.throughputCalibration",
        (
            "version",
            "sampleCount",
            "bytesPerSample",
            "maximumWallMilliseconds",
            "maximumCPUMilliseconds",
            "maximumDispersionRatio",
        ),
    )
    if calibration["version"] != perf_host_readiness.CALIBRATION_VERSION:
        raise CandidateAutomationError(
            "candidate performance throughput-calibration version drifted"
        )
    try:
        readiness_policy = perf_host_readiness.ReadinessPolicy(
            maximum_wait_seconds=host_readiness["maximumWaitSeconds"],
            sample_interval_seconds=host_readiness["sampleIntervalSeconds"],
            required_consecutive_samples=(
                host_readiness["requiredConsecutiveSamples"]
            ),
            maximum_cpu_capacity_fraction=(
                host_readiness["maximumCPUCapacityFraction"]
            ),
            maximum_load_per_processor=(
                host_readiness["maximumLoadPerProcessor"]
            ),
            maximum_interference_cpu_percent=(
                host_readiness["maximumInterferenceCPUPercent"]
            ),
            calibration_sample_count=calibration["sampleCount"],
            calibration_bytes_per_sample=calibration["bytesPerSample"],
            maximum_calibration_wall_milliseconds=(
                calibration["maximumWallMilliseconds"]
            ),
            maximum_calibration_cpu_milliseconds=(
                calibration["maximumCPUMilliseconds"]
            ),
            maximum_calibration_dispersion_ratio=(
                calibration["maximumDispersionRatio"]
            ),
        ).validate()
    except perf_host_readiness.ReadinessError as error:
        raise CandidateAutomationError(str(error)) from error
    performance_path = tracked_path(
        root,
        performance["thresholdContract"],
        "candidate contract.performance.thresholdContract",
        EXPECTED_CONTRACT_PATHS["performance"],
    )
    threshold_contract = load_json(performance_path, "performance threshold contract")
    try:
        threshold_contract = resource_baseline.object_shape(
            threshold_contract,
            "performance threshold contract",
            ("schemaVersion", "metrics"),
            ("authority", "baselines", "description", "regression", "stability"),
        )
    except resource_baseline.ResourceBaselineError as error:
        raise CandidateAutomationError(str(error)) from error
    exact_schema_version(
        threshold_contract["schemaVersion"],
        PERF_LEDGER_SCHEMA_VERSION,
        "performance threshold contract.schemaVersion",
    )
    regression = exact_object(
        threshold_contract.get("regression"),
        "performance threshold contract.regression",
        (
            "latencyToleranceFraction",
            "footprintToleranceFraction",
            "confirmationRuns",
        ),
        ("note",),
    )
    confirmation_runs = performance["confirmationRuns"]
    threshold_confirmation_runs = regression["confirmationRuns"]
    if (
        isinstance(confirmation_runs, bool)
        or not isinstance(confirmation_runs, int)
        or confirmation_runs != EXPECTED_PERFORMANCE_CONFIRMATION_RUNS
        or isinstance(threshold_confirmation_runs, bool)
        or not isinstance(threshold_confirmation_runs, int)
        or threshold_confirmation_runs != confirmation_runs
    ):
        raise CandidateAutomationError(
            "candidate performance confirmation runs must match the tracked "
            "three-run PERF-008 contract"
        )
    raw_metrics = threshold_contract["metrics"]
    if not isinstance(raw_metrics, list) or not raw_metrics:
        raise CandidateAutomationError(
            "performance threshold contract.metrics must be a non-empty array"
        )
    threshold_ids: list[str] = []
    for index, metric in enumerate(raw_metrics):
        if not isinstance(metric, dict) or not isinstance(metric.get("id"), str):
            raise CandidateAutomationError(
                f"performance threshold contract.metrics[{index}].id is invalid"
            )
        threshold_ids.append(metric["id"])
    if len(set(threshold_ids)) != len(threshold_ids):
        raise CandidateAutomationError("performance threshold contract repeats metrics")
    required_metrics = string_list(
        performance["requiredMeasuredMetricIDs"],
        "candidate contract.performance.requiredMeasuredMetricIDs",
    )
    allowed_unmeasured = string_list(
        performance["allowedNotMeasuredMetricIDs"],
        "candidate contract.performance.allowedNotMeasuredMetricIDs",
    )
    if set(required_metrics) & set(allowed_unmeasured):
        raise CandidateAutomationError(
            "candidate performance measured and unmeasured sets overlap"
        )
    if set(required_metrics) | set(allowed_unmeasured) != set(threshold_ids):
        raise CandidateAutomationError(
            "candidate performance policy must partition every threshold metric"
        )
    accepted_states = string_list(
        performance["acceptedMeasuredStates"],
        "candidate contract.performance.acceptedMeasuredStates",
    )
    if set(accepted_states) != {"pass", "diagnostic"}:
        raise CandidateAutomationError(
            "candidate performance accepted states must be diagnostic and pass"
        )

    resource = exact_object(
        contract["resource"],
        "candidate contract.resource",
        ("contract", "samplesPerScenario", "requiredScenarios"),
    )
    resource_path = tracked_path(
        root,
        resource["contract"],
        "candidate contract.resource.contract",
        EXPECTED_CONTRACT_PATHS["resource"],
    )
    try:
        resource_contract = resource_baseline.validate_contract(
            resource_baseline.load_json(resource_path, "resource contract")
        )
    except resource_baseline.ResourceBaselineError as error:
        raise CandidateAutomationError(str(error)) from error
    sample_count = resource["samplesPerScenario"]
    if isinstance(sample_count, bool) or not isinstance(sample_count, int):
        raise CandidateAutomationError(
            "candidate contract.resource.samplesPerScenario must be an integer"
        )
    if sample_count != resource_contract["minimumSamples"]:
        raise CandidateAutomationError(
            "candidate resource sample count must match the accepted minimum"
        )
    scenarios = string_list(
        resource["requiredScenarios"],
        "candidate contract.resource.requiredScenarios",
    )
    if scenarios != EXPECTED_RESOURCE_SCENARIOS:
        raise CandidateAutomationError("candidate resource scenarios drifted")
    if set(scenarios) != set(resource_contract["scenarios"]):
        raise CandidateAutomationError(
            "candidate resource scenarios must cover the resource contract"
        )

    memory_leaks = exact_object(
        contract["memoryLeaks"],
        "candidate contract.memoryLeaks",
        ("contract", "requiredScenarios", "scenarioIterations"),
    )
    leak_contract_path = tracked_path(
        root,
        memory_leaks["contract"],
        "candidate contract.memoryLeaks.contract",
        EXPECTED_CONTRACT_PATHS["memoryLeaks"],
    )
    try:
        leak_contract = apuntador_leak_baseline.validate_contract(
            apuntador_leak_baseline.load_json(
                leak_contract_path, "candidate leak contract"
            )
        )
    except apuntador_leak_baseline.ApuntadorLeakBaselineError as error:
        raise CandidateAutomationError(str(error)) from error
    leak_scenarios = string_list(
        memory_leaks["requiredScenarios"],
        "candidate contract.memoryLeaks.requiredScenarios",
    )
    if (
        leak_scenarios != EXPECTED_LEAK_SCENARIOS
        or leak_scenarios != leak_contract["orderedScenarioIDs"]
    ):
        raise CandidateAutomationError("candidate leak scenarios drifted")
    leak_iterations = exact_object(
        memory_leaks["scenarioIterations"],
        "candidate contract.memoryLeaks.scenarioIterations",
        EXPECTED_LEAK_SCENARIOS,
    )
    for identifier in EXPECTED_LEAK_SCENARIOS:
        iterations = leak_iterations[identifier]
        if (
            isinstance(iterations, bool)
            or not isinstance(iterations, int)
            or iterations != leak_contract["scenarios"][identifier]["iterations"]
        ):
            raise CandidateAutomationError(
                "candidate leak iterations must match the tracked contract"
            )

    ui = exact_object(
        contract["ui"],
        "candidate contract.ui",
        ("budget", "locales"),
    )
    ui_budget_path = tracked_path(
        root,
        ui["budget"],
        "candidate contract.ui.budget",
        EXPECTED_CONTRACT_PATHS["ui"],
    )
    locales = string_list(ui["locales"], "candidate contract.ui.locales")
    if locales != EXPECTED_UI_LOCALES:
        raise CandidateAutomationError("candidate UI locales must be exactly en and es")

    return {
        "proofs": expected_proofs,
        "modelFixture": {
            "textPath": model_fixture_path,
            "conversationTextPath": conversation_fixture_path,
            "conversationVoices": EXPECTED_CONVERSATION_VOICES,
            "conversationTurns": conversation_turns,
            "conversationSilenceMilliseconds": (
                EXPECTED_CONVERSATION_SILENCE_MILLISECONDS
            ),
            "systemVoice": "Samantha",
            "rateWordsPerMinute": fixture_rate,
        },
        "modelClasses": EXPECTED_MODEL_CLASSES,
        "upgradeRecoveryClasses": EXPECTED_UPGRADE_RECOVERY_CLASSES,
        "performance": {
            "thresholdContract": performance_path,
            "binaryPolicy": performance["binaryPolicy"],
            "confirmationRuns": confirmation_runs,
            "hostReadiness": readiness_policy.document(),
            "requiredMeasuredMetricIDs": required_metrics,
            "allowedNotMeasuredMetricIDs": allowed_unmeasured,
            "acceptedMeasuredStates": accepted_states,
        },
        "resource": {
            "contractPath": resource_path,
            "contract": resource_contract,
            "samplesPerScenario": sample_count,
            "requiredScenarios": scenarios,
        },
        "memoryLeaks": {
            "contractPath": leak_contract_path,
            "contract": leak_contract,
            "scenarioIterations": leak_iterations,
            "requiredScenarios": leak_scenarios,
        },
        "ui": {
            "budgetPath": ui_budget_path,
            "locales": locales,
        },
    }


def load_contract(path: Path = DEFAULT_CONTRACT, root: Path = ROOT) -> dict[str, Any]:
    return validate_contract(load_json(path, "candidate contract"), root)


def candidate_performance_readiness_policy(
    contract: dict[str, Any],
) -> perf_host_readiness.ReadinessPolicy:
    policy = contract["performance"]["hostReadiness"]
    calibration = policy["throughputCalibration"]
    return perf_host_readiness.ReadinessPolicy(
        maximum_wait_seconds=policy["maximumWaitSeconds"],
        sample_interval_seconds=policy["sampleIntervalSeconds"],
        required_consecutive_samples=policy["requiredConsecutiveSamples"],
        maximum_cpu_capacity_fraction=policy["maximumCPUCapacityFraction"],
        maximum_load_per_processor=policy["maximumLoadPerProcessor"],
        maximum_interference_cpu_percent=(
            policy["maximumInterferenceCPUPercent"]
        ),
        calibration_sample_count=calibration["sampleCount"],
        calibration_bytes_per_sample=calibration["bytesPerSample"],
        maximum_calibration_wall_milliseconds=(
            calibration["maximumWallMilliseconds"]
        ),
        maximum_calibration_cpu_milliseconds=(
            calibration["maximumCPUMilliseconds"]
        ),
        maximum_calibration_dispersion_ratio=(
            calibration["maximumDispersionRatio"]
        ),
    ).validate()


def validate_release_identity(
    release: dict[str, Any],
    *,
    version: str,
    build: str,
    commit: str,
    label: str,
) -> None:
    expected = {"version": version, "build": build, "commit": commit}
    if release != expected:
        raise CandidateAutomationError(f"{label} release identity does not match")


def validate_deterministic_receipt(
    path: Path,
    *,
    version: str,
    build: str,
    commit: str,
) -> None:
    try:
        _, release, proofs = release_reliability.validate_deterministic_receipt(
            load_json(path, "deterministic receipt")
        )
    except release_reliability.ReliabilityError as error:
        raise CandidateAutomationError(str(error)) from error
    validate_release_identity(
        release,
        version=version,
        build=build,
        commit=commit,
        label="deterministic receipt",
    )
    failed = sorted(identifier for identifier, state in proofs.items() if state != "pass")
    if failed:
        raise CandidateAutomationError(
            "deterministic receipt did not pass: " + ", ".join(failed)
        )


def validated_performance_ledger(
    path: Path,
    contract: dict[str, Any],
    *,
    allow_regression_candidates: bool = False,
) -> dict[str, Any]:
    ledger = exact_object(
        load_json(path, "performance ledger"),
        "performance ledger",
        ("schemaVersion", "authority", "metrics", "summary"),
        ("generatedAt", "host", "toolchain", "comparability"),
    )
    exact_schema_version(
        ledger["schemaVersion"],
        PERF_LEDGER_SCHEMA_VERSION,
        "performance ledger.schemaVersion",
    )
    if ledger["authority"] != "authoritative":
        raise CandidateAutomationError("performance ledger is not authoritative")
    if not isinstance(ledger.get("host"), dict) or not ledger["host"]:
        raise CandidateAutomationError("performance ledger has no host identity")
    if not isinstance(ledger.get("toolchain"), dict) or not ledger["toolchain"]:
        raise CandidateAutomationError("performance ledger has no toolchain identity")
    if "generatedAt" in ledger:
        try:
            release_reliability.timestamp(
                ledger["generatedAt"], "performance ledger.generatedAt"
            )
        except release_reliability.ReliabilityError as error:
            raise CandidateAutomationError(str(error)) from error

    metrics = ledger["metrics"]
    if not isinstance(metrics, list):
        raise CandidateAutomationError("performance ledger.metrics must be an array")
    by_identifier: dict[str, dict[str, Any]] = {}
    status_counts: dict[str, int] = {}
    for index, raw_metric in enumerate(metrics):
        if not isinstance(raw_metric, dict):
            raise CandidateAutomationError(
                f"performance ledger.metrics[{index}] must be an object"
            )
        identifier = raw_metric.get("id")
        status = raw_metric.get("status")
        if not isinstance(identifier, str) or not isinstance(status, str):
            raise CandidateAutomationError(
                f"performance ledger.metrics[{index}] has invalid identity or status"
            )
        if identifier in by_identifier:
            raise CandidateAutomationError(
                f"performance ledger repeats metric: {identifier}"
            )
        by_identifier[identifier] = raw_metric
        status_counts[status] = status_counts.get(status, 0) + 1

    policy = contract["performance"]
    required = set(policy["requiredMeasuredMetricIDs"])
    allowed_unmeasured = set(policy["allowedNotMeasuredMetricIDs"])
    if set(by_identifier) != required | allowed_unmeasured:
        raise CandidateAutomationError(
            "performance ledger metric inventory does not match the candidate contract"
        )
    accepted_states = set(policy["acceptedMeasuredStates"])
    for identifier in sorted(required):
        status = by_identifier[identifier]["status"]
        if status not in accepted_states and not (
            allow_regression_candidates and status == "regression-candidate"
        ):
            raise CandidateAutomationError(
                f"performance metric {identifier} has blocking state {status}"
            )
        finite_nonnegative(
            by_identifier[identifier].get("measured"),
            f"performance metric {identifier}.measured",
        )
    for identifier in sorted(allowed_unmeasured):
        if by_identifier[identifier]["status"] != "not-measured":
            raise CandidateAutomationError(
                f"performance metric {identifier} must be explicitly not-measured"
            )

    summary = exact_object(
        ledger["summary"],
        "performance ledger.summary",
        (
            "failures",
            "regressionCandidates",
            "notMeasured",
            "unresolved",
            "unstable",
            "dispersed",
        ),
    )
    expected_summary = {
        "failures": status_counts.get("fail", 0),
        "regressionCandidates": status_counts.get("regression-candidate", 0),
        "notMeasured": status_counts.get("not-measured", 0),
        "unresolved": status_counts.get("unresolved", 0),
        "unstable": status_counts.get("unstable", 0),
    }
    for key, expected in expected_summary.items():
        value = summary[key]
        if isinstance(value, bool) or not isinstance(value, int) or value != expected:
            raise CandidateAutomationError(
                f"performance ledger.summary.{key} is inconsistent"
            )
    always_blocking = ("failures", "unresolved", "unstable")
    if any(summary[key] != 0 for key in always_blocking):
        raise CandidateAutomationError("performance ledger contains blocking results")
    if summary["regressionCandidates"] != 0 and not allow_regression_candidates:
        raise CandidateAutomationError("performance ledger contains blocking results")
    if summary["notMeasured"] != len(allowed_unmeasured):
        raise CandidateAutomationError(
            "performance ledger not-measured count does not match policy"
        )
    if isinstance(summary["dispersed"], bool) or not isinstance(
        summary["dispersed"], int
    ) or not 0 <= summary["dispersed"] <= len(metrics):
        raise CandidateAutomationError(
            "performance ledger.summary.dispersed is outside the metric inventory"
        )
    return ledger


def validate_performance_ledger(path: Path, contract: dict[str, Any]) -> None:
    validated_performance_ledger(path, contract)


def performance_candidate_metric_ids(ledger: dict[str, Any]) -> tuple[str, ...]:
    return tuple(sorted(
        metric["id"]
        for metric in ledger["metrics"]
        if metric["status"] == "regression-candidate"
    ))


def validate_resource_receipt(
    path: Path,
    contract: dict[str, Any],
    *,
    version: str,
    build: str,
    commit: str,
    profile: str,
) -> None:
    policy = contract["resource"]
    try:
        receipt = resource_baseline.validate_receipt(
            load_json(path, "resource receipt"),
            policy["contract"],
            "resource receipt",
        )
    except resource_baseline.ResourceBaselineError as error:
        raise CandidateAutomationError(str(error)) from error
    resource_build = dict(receipt["build"])
    if resource_build.pop("configuration", None) != "release":
        raise CandidateAutomationError("resource receipt is not a Release build")
    validate_release_identity(
        resource_build,
        version=version,
        build=build,
        commit=commit,
        label="resource receipt",
    )
    if receipt["host"]["profile"] != profile:
        raise CandidateAutomationError("resource receipt host profile does not match")
    scenarios = receipt["scenarios"]
    if set(scenarios) != set(policy["requiredScenarios"]):
        raise CandidateAutomationError(
            "resource receipt scenario inventory does not match"
        )
    expected_samples = policy["samplesPerScenario"]
    expected_runs = set(range(1, expected_samples + 1))
    for identifier in policy["requiredScenarios"]:
        scenario = scenarios[identifier]
        if set(scenario["runs"]) != expected_runs:
            raise CandidateAutomationError(
                f"resource scenario {identifier} must have exact runs 1...{expected_samples}"
            )
        try:
            row = resource_baseline.scenario_row(
                profile,
                identifier,
                scenario,
                expected_samples,
                policy["contract"]["maximumTimingRatio"],
                policy["contract"]["minimumBlockingTimingDelta"],
            )
        except resource_baseline.ResourceBaselineError as error:
            raise CandidateAutomationError(str(error)) from error
        if row["state"] != "pass":
            raise CandidateAutomationError(
                f"resource scenario {identifier} has blocking state {row['state']}"
            )
    ask_pipeline = receipt["askPipeline"]
    try:
        ask_row = resource_baseline.ask_pipeline_row(
            profile,
            ask_pipeline,
            expected_samples,
            policy["contract"]["maximumTimingRatio"],
            policy["contract"]["minimumBlockingTimingDelta"],
        )
    except resource_baseline.ResourceBaselineError as error:
        raise CandidateAutomationError(str(error)) from error
    if ask_row["state"] != "pass":
        raise CandidateAutomationError(
            f"resource Ask pipeline has blocking state {ask_row['state']}"
        )
    if set(ask_pipeline["runs"]) != expected_runs:
        raise CandidateAutomationError(
            f"resource Ask pipeline must have exact runs 1...{expected_samples}"
        )
    if set(ask_pipeline["runs"]) != set(scenarios["ask"]["runs"]):
        raise CandidateAutomationError(
            "resource Ask pipeline runs do not match the Ask samples"
        )


def validate_memory_leak_receipt(
    path: Path,
    contract: dict[str, Any],
    *,
    version: str,
    build: str,
    commit: str,
) -> None:
    policy = contract["memoryLeaks"]
    try:
        receipt = apuntador_leak_baseline.validate_receipt(
            apuntador_leak_baseline.load_json(path, "memory leak receipt"),
            policy["contract"],
        )
    except apuntador_leak_baseline.ApuntadorLeakBaselineError as error:
        raise CandidateAutomationError(str(error)) from error
    validate_release_identity(
        receipt["release"],
        version=version,
        build=build,
        commit=commit,
        label="memory leak receipt",
    )
    if tuple(row["id"] for row in receipt["scenarios"]) != policy[
        "requiredScenarios"
    ]:
        raise CandidateAutomationError(
            "memory leak receipt scenario inventory does not match"
        )


def validate_long_capture(path: Path, commit: str) -> None:
    try:
        long_capture_evidence.validate_report(
            load_json(path, "long-capture receipt", maximum_bytes=512 * 1024),
            commit,
        )
    except long_capture_evidence.EvidenceError as error:
        raise CandidateAutomationError(str(error)) from error


def validate_ui_receipts(results_root: Path, contract: dict[str, Any]) -> None:
    ui_policy = contract["ui"]
    budget = exact_object(
        load_json(ui_policy["budgetPath"], "UI runtime budget"),
        "UI runtime budget",
        ("schemaVersion", "catalog", "fullSuite", "testBudgetsSeconds"),
        ("historicalBaseline", "qualifiedCandidate"),
    )
    exact_schema_version(
        budget["schemaVersion"],
        UI_BUDGET_SCHEMA_VERSION,
        "UI runtime budget.schemaVersion",
    )
    catalog = exact_object(
        budget["catalog"], "UI runtime budget.catalog", ("expectedCaseCount",)
    )
    expected_count = catalog["expectedCaseCount"]
    if isinstance(expected_count, bool) or not isinstance(expected_count, int):
        raise CandidateAutomationError("UI expected case count must be an integer")
    raw_test_budgets = budget["testBudgetsSeconds"]
    if not isinstance(raw_test_budgets, dict):
        raise CandidateAutomationError("UI test budgets must be an object")
    expected_identifiers = set(raw_test_budgets)
    if len(expected_identifiers) != expected_count:
        raise CandidateAutomationError(
            "UI budget inventory does not match its expected case count"
        )

    build_durations: list[float] = []
    for locale in ui_policy["locales"]:
        receipt = exact_object(
            load_json(results_root / f"{locale}-runtime.json", f"{locale} UI receipt"),
            f"{locale} UI receipt",
            (
                "schemaVersion",
                "locale",
                "selectorCount",
                "caseCount",
                "buildDurationSeconds",
                "testWallDurationSeconds",
                "testDurationSeconds",
                "p50Seconds",
                "p95Seconds",
                "maximumSeconds",
                "budgetStatus",
                "budgetViolations",
                "measurementPolicy",
                "runtimeAdjustments",
                "tests",
            ),
        )
        exact_schema_version(
            receipt["schemaVersion"],
            UI_RECEIPT_SCHEMA_VERSION,
            f"{locale} UI receipt.schemaVersion",
        )
        if receipt["locale"] != locale:
            raise CandidateAutomationError(f"{locale} UI receipt locale does not match")
        if receipt["measurementPolicy"] != UI_MEASUREMENT_POLICY:
            raise CandidateAutomationError(
                f"{locale} UI receipt measurement policy does not match"
            )
        if (
            isinstance(receipt["selectorCount"], bool)
            or not isinstance(receipt["selectorCount"], int)
            or receipt["selectorCount"] != 0
        ):
            raise CandidateAutomationError(
                f"{locale} UI receipt is not a complete-catalog run"
            )
        if receipt["caseCount"] != expected_count:
            raise CandidateAutomationError(
                f"{locale} UI receipt has {receipt['caseCount']} cases; "
                f"expected {expected_count}"
            )
        if receipt["budgetStatus"] != "passed" or receipt["budgetViolations"] != []:
            raise CandidateAutomationError(f"{locale} UI receipt failed its budget")
        build_durations.append(
            finite_nonnegative(
                receipt["buildDurationSeconds"],
                f"{locale} UI receipt.buildDurationSeconds",
            )
        )
        for key in (
            "testWallDurationSeconds",
            "testDurationSeconds",
            "p50Seconds",
            "p95Seconds",
            "maximumSeconds",
        ):
            finite_nonnegative(receipt[key], f"{locale} UI receipt.{key}")
        tests = receipt["tests"]
        if not isinstance(tests, list) or len(tests) != expected_count:
            raise CandidateAutomationError(
                f"{locale} UI receipt tests do not match the full catalog"
            )
        identifiers: set[str] = set()
        for index, raw_test in enumerate(tests):
            test = exact_object(
                raw_test,
                f"{locale} UI receipt.tests[{index}]",
                ("identifier", "durationSeconds", "result"),
            )
            identifier = test["identifier"]
            if not isinstance(identifier, str) or not identifier:
                raise CandidateAutomationError(
                    f"{locale} UI receipt.tests[{index}].identifier is invalid"
                )
            if identifier in identifiers:
                raise CandidateAutomationError(
                    f"{locale} UI receipt repeats test: {identifier}"
                )
            identifiers.add(identifier)
            finite_nonnegative(
                test["durationSeconds"],
                f"{locale} UI receipt test {identifier}.durationSeconds",
            )
            if test["result"] != "Passed":
                raise CandidateAutomationError(
                    f"{locale} UI receipt test {identifier} did not pass"
                )
        if identifiers != expected_identifiers:
            raise CandidateAutomationError(
                f"{locale} UI receipt test inventory does not match the budget"
            )
        tests_by_identifier = {
            test["identifier"]: test
            for test in tests
        }
        adjustments = receipt["runtimeAdjustments"]
        if not isinstance(adjustments, list):
            raise CandidateAutomationError(
                f"{locale} UI receipt runtime adjustments must be an array"
            )
        adjusted_identifiers: set[str] = set()
        for index, raw_adjustment in enumerate(adjustments):
            adjustment = exact_object(
                raw_adjustment,
                f"{locale} UI receipt.runtimeAdjustments[{index}]",
                (
                    "identifier",
                    "reportedDurationSeconds",
                    "attributedDurationSeconds",
                    "excludedPreSetupSeconds",
                    "excludedPostTeardownSeconds",
                    "excludedHarnessSeconds",
                    "reason",
                ),
            )
            identifier = adjustment["identifier"]
            if (
                not isinstance(identifier, str)
                or identifier not in tests_by_identifier
                or identifier in adjusted_identifiers
                or tests_by_identifier[identifier]["result"] != "Passed"
                or adjustment["reason"] != "outside-test-activity-boundaries"
            ):
                raise CandidateAutomationError(
                    f"{locale} UI runtime adjustment identity differs"
                )
            reported = finite_nonnegative(
                adjustment["reportedDurationSeconds"],
                f"{locale} UI runtime adjustment reported duration",
            )
            attributed = finite_nonnegative(
                adjustment["attributedDurationSeconds"],
                f"{locale} UI runtime adjustment attributed duration",
            )
            excluded_pre_setup = finite_nonnegative(
                adjustment["excludedPreSetupSeconds"],
                f"{locale} UI runtime adjustment pre-setup duration",
            )
            excluded_post_teardown = finite_nonnegative(
                adjustment["excludedPostTeardownSeconds"],
                f"{locale} UI runtime adjustment post-teardown duration",
            )
            excluded = finite_nonnegative(
                adjustment["excludedHarnessSeconds"],
                f"{locale} UI runtime adjustment excluded duration",
            )
            test_duration = finite_nonnegative(
                tests_by_identifier[identifier]["durationSeconds"],
                f"{locale} UI runtime adjustment test duration",
            )
            if (
                attributed > reported
                or excluded < UI_HARNESS_NOISE_THRESHOLD_SECONDS
                or abs((reported - attributed) - excluded) > 0.002
                or abs(
                    (excluded_pre_setup + excluded_post_teardown) - excluded
                ) > 0.003
                or abs(test_duration - attributed) > 0.002
            ):
                raise CandidateAutomationError(
                    f"{locale} UI runtime adjustment values differ"
                )
            adjusted_identifiers.add(identifier)
    if len(set(build_durations)) != 1:
        raise CandidateAutomationError(
            "bilingual UI receipts do not share one build duration"
        )


def detect_profile(contract: dict[str, Any], physical_memory_bytes: int) -> str:
    if isinstance(physical_memory_bytes, bool) or not isinstance(
        physical_memory_bytes, int
    ) or physical_memory_bytes <= 0:
        raise CandidateAutomationError("physical memory must be a positive integer")
    matches = []
    for identifier, profile in contract["resource"]["contract"]["profiles"].items():
        minimum = profile["minimum"]
        maximum = profile["maximum"]
        if physical_memory_bytes >= minimum and (
            maximum is None or physical_memory_bytes <= maximum
        ):
            matches.append(identifier)
    if len(matches) != 1:
        raise CandidateAutomationError(
            "this Mac does not map to exactly one accepted resource profile"
        )
    return matches[0]


def physical_memory_bytes() -> int:
    try:
        result = subprocess.run(
            ["sysctl", "-n", "hw.memsize"],
            check=True,
            capture_output=True,
            text=True,
        )
        return int(result.stdout.strip())
    except (OSError, subprocess.CalledProcessError, ValueError) as error:
        raise CandidateAutomationError("cannot read this Mac's physical memory") from error


def developer_environment() -> dict[str, str]:
    environment = os.environ.copy()
    if environment.get("DEVELOPER_DIR"):
        return environment
    try:
        selected = subprocess.run(
            ["xcode-select", "-p"],
            check=True,
            capture_output=True,
            text=True,
        ).stdout.strip()
    except (OSError, subprocess.CalledProcessError):
        return environment
    fallback = Path("/Applications/Xcode.app/Contents/Developer")
    if selected.endswith("/CommandLineTools") and fallback.is_dir():
        environment["DEVELOPER_DIR"] = str(fallback)
    return environment


def exact_checkout(root: Path, expected_commit: str | None = None) -> str:
    try:
        head = subprocess.run(
            ["git", "rev-parse", "HEAD"],
            cwd=root,
            check=True,
            capture_output=True,
            text=True,
        ).stdout.strip()
        status = subprocess.run(
            ["git", "status", "--porcelain", "--untracked-files=all"],
            cwd=root,
            check=True,
            capture_output=True,
            text=True,
        ).stdout
    except (OSError, subprocess.CalledProcessError) as error:
        raise CandidateAutomationError("cannot inspect the source checkout") from error
    try:
        release_reliability.safe_string(
            head, "candidate source commit", release_reliability.COMMIT_PATTERN
        )
    except release_reliability.ReliabilityError as error:
        raise CandidateAutomationError(str(error)) from error
    if expected_commit is not None and head != expected_commit:
        raise CandidateAutomationError("candidate source HEAD changed during qualification")
    if status:
        raise CandidateAutomationError(
            "candidate qualification requires a completely clean worktree"
        )
    return head


def run_command(
    root: Path,
    expected_commit: str,
    label: str,
    command: Sequence[str],
    *,
    environment: dict[str, str | None] | None = None,
    accepted_exit_codes: Sequence[int] = (0,),
) -> int:
    accepted = tuple(accepted_exit_codes)
    if (
        not accepted
        or len(set(accepted)) != len(accepted)
        or any(
            isinstance(code, bool)
            or not isinstance(code, int)
            or not 0 <= code <= 255
            for code in accepted
        )
    ):
        raise CandidateAutomationError(f"{label} has invalid accepted exit codes")
    exact_checkout(root, expected_commit)
    print(f"==> {label}", flush=True)
    merged_environment = developer_environment()
    if environment:
        for key, value in environment.items():
            if value is None:
                merged_environment.pop(key, None)
            else:
                merged_environment[key] = value
    try:
        status = subprocess.run(
            list(command),
            cwd=root,
            env=merged_environment,
            check=False,
        ).returncode
    except OSError as error:
        raise CandidateAutomationError(f"{label} could not start") from error
    exact_checkout(root, expected_commit)
    if status not in accepted:
        raise CandidateAutomationError(f"{label} failed with exit status {status}")
    return status


def sha256_file(
    path: Path,
    label: str,
    *,
    maximum_bytes: int = 64 * 1024 * 1024,
) -> str:
    if path.is_symlink() or not path.is_file():
        raise CandidateAutomationError(f"{label} is missing or not a regular file")
    if path.stat().st_size > maximum_bytes:
        raise CandidateAutomationError(f"{label} exceeds the size limit")
    digest = hashlib.sha256()
    try:
        with path.open("rb") as handle:
            for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                digest.update(chunk)
    except OSError as error:
        raise CandidateAutomationError(f"{label} is unreadable") from error
    return digest.hexdigest()


def build_candidate_performance_binary(
    root: Path,
    expected_commit: str,
    *,
    environment: dict[str, str | None],
) -> dict[str, Any]:
    binary = root / ".build" / "release" / "portavoz-cli"
    started = time.monotonic_ns()
    run_command(
        root,
        expected_commit,
        "Exact performance Release build",
        ["swift", "build", "-c", "release", "--product", "portavoz-cli"],
        environment=environment,
    )
    finished = time.monotonic_ns()
    if finished < started or not os.access(binary, os.X_OK):
        raise CandidateAutomationError(
            "exact performance Release binary is missing or not executable"
        )
    wall_milliseconds = finite_nonnegative(
        (finished - started) / 1_000_000,
        "exact performance Release build duration",
    )
    return {
        "path": binary,
        "sha256": sha256_file(
            binary,
            "exact performance Release binary",
            maximum_bytes=512 * 1024 * 1024,
        ),
        "wallMilliseconds": wall_milliseconds,
    }


def exact_sorted_string_array(value: Any, label: str) -> tuple[str, ...]:
    if not isinstance(value, list):
        raise CandidateAutomationError(f"{label} must be an array")
    if any(not isinstance(item, str) or not item for item in value):
        raise CandidateAutomationError(f"{label} must contain non-empty strings")
    if value != sorted(set(value)):
        raise CandidateAutomationError(f"{label} must be sorted and unique")
    return tuple(value)


def validate_performance_run(
    path: Path,
    contract: dict[str, Any],
    *,
    exit_code: int,
    expected_commit: str,
    expected_binary_sha256: str,
    expected_host: dict[str, Any] | None = None,
    expected_toolchain: dict[str, Any] | None = None,
) -> tuple[dict[str, Any], tuple[str, ...]]:
    for readiness_name, readiness_label in (
        ("host-readiness.json", "scale performance host readiness"),
        ("host-readiness-semantic.json", "semantic performance host readiness"),
        ("host-readiness-spotlight.json", "Spotlight performance host readiness"),
    ):
        try:
            perf_host_readiness.validate_receipt(
                load_json(path.parent / readiness_name, readiness_label),
                policy=candidate_performance_readiness_policy(contract),
                expected_commit=expected_commit,
                expected_binary_sha256=expected_binary_sha256,
            )
        except perf_host_readiness.ReadinessError as error:
            raise CandidateAutomationError(str(error)) from error
    ledger = validated_performance_ledger(
        path,
        contract,
        allow_regression_candidates=True,
    )
    candidate_ids = performance_candidate_metric_ids(ledger)
    expected_exit_code = 2 if candidate_ids else 0
    if exit_code != expected_exit_code:
        raise CandidateAutomationError(
            "performance ledger exit status does not match its regression candidates"
        )
    if expected_host is not None and ledger["host"] != expected_host:
        raise CandidateAutomationError(
            "performance confirmation changed host identity between runs"
        )
    if expected_toolchain is not None and ledger["toolchain"] != expected_toolchain:
        raise CandidateAutomationError(
            "performance confirmation changed toolchain identity between runs"
        )
    return ledger, candidate_ids


def performance_confirmation_document(
    runs: Sequence[dict[str, Any]],
    *,
    required_runs: int,
    outcome: str,
    selected_run: int | None,
    source_commit: str,
    binary_sha256: str,
    build_wall_milliseconds: float,
) -> dict[str, Any]:
    candidate_sets = [set(run["candidateMetricIDs"]) for run in runs]
    confirmed = (
        sorted(set.intersection(*candidate_sets))
        if len(candidate_sets) == required_runs
        else []
    )
    return {
        "schemaVersion": PERFORMANCE_CONFIRMATION_SCHEMA_VERSION,
        "kind": "performance-regression-confirmation",
        "sourceCommit": source_commit,
        "binarySHA256": binary_sha256,
        "buildWallMilliseconds": build_wall_milliseconds,
        "requiredRuns": required_runs,
        "observedRuns": len(runs),
        "outcome": outcome,
        "selectedRun": selected_run,
        "initialCandidateMetricIDs": list(runs[0]["candidateMetricIDs"]),
        "confirmedRegressionMetricIDs": confirmed,
        "runs": [
            {
                "run": run["run"],
                "exitCode": run["exitCode"],
                "ledgerSHA256": run["ledgerSHA256"],
                "candidateMetricIDs": list(run["candidateMetricIDs"]),
            }
            for run in runs
        ],
    }


def validate_performance_confirmation(
    path: Path,
    contract: dict[str, Any],
    *,
    runs_root: Path | None = None,
) -> dict[str, Any]:
    receipt = exact_object(
        load_json(path, "performance confirmation receipt"),
        "performance confirmation receipt",
        (
            "schemaVersion",
            "kind",
            "sourceCommit",
            "binarySHA256",
            "buildWallMilliseconds",
            "requiredRuns",
            "observedRuns",
            "outcome",
            "selectedRun",
            "initialCandidateMetricIDs",
            "confirmedRegressionMetricIDs",
            "runs",
        ),
    )
    exact_schema_version(
        receipt["schemaVersion"],
        PERFORMANCE_CONFIRMATION_SCHEMA_VERSION,
        "performance confirmation receipt.schemaVersion",
    )
    if receipt["kind"] != "performance-regression-confirmation":
        raise CandidateAutomationError("performance confirmation kind is invalid")
    source_commit = receipt["sourceCommit"]
    binary_sha256 = receipt["binarySHA256"]
    if not isinstance(source_commit, str) or re.fullmatch(
        r"[0-9a-f]{40}", source_commit
    ) is None:
        raise CandidateAutomationError(
            "performance confirmation source commit is invalid"
        )
    if not isinstance(binary_sha256, str) or re.fullmatch(
        r"[0-9a-f]{64}", binary_sha256
    ) is None:
        raise CandidateAutomationError(
            "performance confirmation binary SHA-256 is invalid"
        )
    finite_nonnegative(
        receipt["buildWallMilliseconds"],
        "performance confirmation buildWallMilliseconds",
    )
    required_runs = contract["performance"]["confirmationRuns"]
    if (
        isinstance(receipt["requiredRuns"], bool)
        or not isinstance(receipt["requiredRuns"], int)
        or receipt["requiredRuns"] != required_runs
    ):
        raise CandidateAutomationError(
            "performance confirmation required-run count drifted"
        )
    raw_runs = receipt["runs"]
    if not isinstance(raw_runs, list) or not raw_runs:
        raise CandidateAutomationError("performance confirmation runs are missing")
    if (
        isinstance(receipt["observedRuns"], bool)
        or not isinstance(receipt["observedRuns"], int)
        or receipt["observedRuns"] != len(raw_runs)
    ):
        raise CandidateAutomationError(
            "performance confirmation observed-run count is inconsistent"
        )
    allowed_metric_ids = set(contract["performance"]["requiredMeasuredMetricIDs"])
    parsed_runs: list[dict[str, Any]] = []
    expected_host: dict[str, Any] | None = None
    expected_toolchain: dict[str, Any] | None = None
    for index, raw_run in enumerate(raw_runs, start=1):
        run = exact_object(
            raw_run,
            f"performance confirmation runs[{index}]",
            ("run", "exitCode", "ledgerSHA256", "candidateMetricIDs"),
        )
        if (
            isinstance(run["run"], bool)
            or not isinstance(run["run"], int)
            or run["run"] != index
            or isinstance(run["exitCode"], bool)
            or not isinstance(run["exitCode"], int)
            or run["exitCode"] not in (0, 2)
        ):
            raise CandidateAutomationError(
                "performance confirmation run order or exit status is invalid"
            )
        digest = run["ledgerSHA256"]
        if not isinstance(digest, str) or re.fullmatch(r"[0-9a-f]{64}", digest) is None:
            raise CandidateAutomationError(
                "performance confirmation ledger digest is invalid"
            )
        candidate_ids = exact_sorted_string_array(
            run["candidateMetricIDs"],
            f"performance confirmation runs[{index}].candidateMetricIDs",
        )
        if not set(candidate_ids) <= allowed_metric_ids:
            raise CandidateAutomationError(
                "performance confirmation names an unknown candidate metric"
            )
        if run["exitCode"] != (2 if candidate_ids else 0):
            raise CandidateAutomationError(
                "performance confirmation exit status is inconsistent"
            )
        if runs_root is not None:
            ledger_path = runs_root / f"run-{index}" / "ledger.json"
            if sha256_file(
                ledger_path,
                f"performance confirmation run {index} ledger",
            ) != digest:
                raise CandidateAutomationError(
                    "performance confirmation ledger digest does not match"
                )
            ledger, ledger_candidate_ids = validate_performance_run(
                ledger_path,
                contract,
                exit_code=run["exitCode"],
                expected_commit=source_commit,
                expected_binary_sha256=binary_sha256,
                expected_host=expected_host,
                expected_toolchain=expected_toolchain,
            )
            if ledger_candidate_ids != candidate_ids:
                raise CandidateAutomationError(
                    "performance confirmation candidate metrics do not match ledger"
                )
            expected_host = ledger["host"]
            expected_toolchain = ledger["toolchain"]
        parsed_runs.append({**run, "candidateMetricIDs": candidate_ids})

    initial_ids = exact_sorted_string_array(
        receipt["initialCandidateMetricIDs"],
        "performance confirmation initialCandidateMetricIDs",
    )
    confirmed_ids = exact_sorted_string_array(
        receipt["confirmedRegressionMetricIDs"],
        "performance confirmation confirmedRegressionMetricIDs",
    )
    if initial_ids != parsed_runs[0]["candidateMetricIDs"]:
        raise CandidateAutomationError(
            "performance confirmation initial candidates are inconsistent"
        )
    candidate_sets = [set(run["candidateMetricIDs"]) for run in parsed_runs]
    expected_confirmed = (
        tuple(sorted(set.intersection(*candidate_sets)))
        if len(parsed_runs) == required_runs
        else ()
    )
    if confirmed_ids != expected_confirmed:
        raise CandidateAutomationError(
            "performance confirmation confirmed candidates are inconsistent"
        )
    clean_runs = [
        run["run"] for run in parsed_runs if not run["candidateMetricIDs"]
    ]
    selected_run = receipt["selectedRun"]
    if selected_run is not None and (
        isinstance(selected_run, bool) or not isinstance(selected_run, int)
    ):
        raise CandidateAutomationError("performance confirmation selected run is invalid")
    outcome = receipt["outcome"]
    valid = False
    if outcome == "clean-first-run":
        valid = (
            len(parsed_runs) == 1
            and not initial_ids
            and selected_run == 1
            and clean_runs == [1]
        )
    elif outcome == "unconfirmed-regression":
        valid = (
            len(parsed_runs) == required_runs
            and bool(initial_ids)
            and not confirmed_ids
            and bool(clean_runs)
            and selected_run == clean_runs[-1]
        )
    elif outcome == "confirmed-regression":
        valid = (
            len(parsed_runs) == required_runs
            and bool(initial_ids)
            and bool(confirmed_ids)
            and selected_run is None
        )
    elif outcome == "inconclusive":
        valid = (
            len(parsed_runs) == required_runs
            and bool(initial_ids)
            and not confirmed_ids
            and not clean_runs
            and selected_run is None
        )
    if not valid:
        raise CandidateAutomationError(
            "performance confirmation outcome is inconsistent with its runs"
        )
    return receipt


def publish_performance_run(
    selected_root: Path,
    performance_root: Path,
    confirmation_path: Path,
) -> None:
    if performance_root.exists():
        raise CandidateAutomationError("canonical performance output already exists")
    staging = performance_root.with_name(
        f".{performance_root.name}.partial-{os.getpid()}"
    )
    if staging.exists():
        raise CandidateAutomationError("partial performance output already exists")
    staging.mkdir(mode=0o700)
    os.chmod(staging, 0o700)
    try:
        sources = [selected_root / name for name in EXPECTED_PERFORMANCE_ARTIFACTS]
        sources.append(confirmation_path)
        for source in sources:
            label = f"selected performance artifact {source.name}"
            source_digest = sha256_file(source, label)
            destination_name = (
                "confirmation.json"
                if source == confirmation_path
                else source.name
            )
            destination = staging / destination_name
            shutil.copyfile(source, destination, follow_symlinks=False)
            os.chmod(destination, 0o600)
            if sha256_file(destination, label) != source_digest:
                raise CandidateAutomationError(
                    f"{label} changed while it was published"
                )
        os.replace(staging, performance_root)
    finally:
        if staging.exists():
            shutil.rmtree(staging, ignore_errors=True)


def run_candidate_performance_gate(
    root: Path,
    expected_commit: str,
    performance_root: Path,
    contract: dict[str, Any],
    *,
    binary_path: Path,
    binary_sha256: str,
    build_wall_milliseconds: float,
    environment: dict[str, str | None],
) -> None:
    if binary_path != root / ".build" / "release" / "portavoz-cli":
        raise CandidateAutomationError(
            "candidate performance binary path is not the exact Release product"
        )
    if re.fullmatch(r"[0-9a-f]{64}", binary_sha256) is None:
        raise CandidateAutomationError("candidate performance binary SHA-256 is invalid")
    finite_nonnegative(
        build_wall_milliseconds,
        "candidate performance Release build duration",
    )
    readiness_policy = candidate_performance_readiness_policy(contract)
    required_runs = contract["performance"]["confirmationRuns"]
    runs_root = performance_root.with_name("performance-confirmation")
    if runs_root.exists():
        raise CandidateAutomationError(
            "performance confirmation output already exists"
        )
    runs_root.mkdir(mode=0o700)
    os.chmod(runs_root, 0o700)
    run_results: list[dict[str, Any]] = []
    expected_host: dict[str, Any] | None = None
    expected_toolchain: dict[str, Any] | None = None

    def execute(run_number: int) -> None:
        nonlocal expected_host, expected_toolchain
        run_root = runs_root / f"run-{run_number}"
        label = (
            "Authoritative performance ledger"
            if run_number == 1
            else f"PERF-008 confirmation {run_number}/{required_runs}"
        )
        exit_code = run_command(
            root,
            expected_commit,
            label,
            ["scripts/run-perf-ledger.sh", str(run_root)],
            environment={
                **environment,
                "PORTAVOZ_PERF_BINARY": str(binary_path),
                "PORTAVOZ_PERF_BINARY_SHA256": binary_sha256,
                "PORTAVOZ_PERF_BUILD_WALL_MS": str(build_wall_milliseconds),
                "PORTAVOZ_PERF_SOURCE_COMMIT": expected_commit,
                "PORTAVOZ_PERF_HOST_MAXIMUM_WAIT_SECONDS": str(
                    readiness_policy.maximum_wait_seconds
                ),
                "PORTAVOZ_PERF_HOST_SAMPLE_INTERVAL_SECONDS": str(
                    readiness_policy.sample_interval_seconds
                ),
                "PORTAVOZ_PERF_HOST_REQUIRED_CONSECUTIVE_SAMPLES": str(
                    readiness_policy.required_consecutive_samples
                ),
                "PORTAVOZ_PERF_HOST_MAXIMUM_CPU_CAPACITY_FRACTION": str(
                    readiness_policy.maximum_cpu_capacity_fraction
                ),
                "PORTAVOZ_PERF_HOST_MAXIMUM_LOAD_PER_PROCESSOR": str(
                    readiness_policy.maximum_load_per_processor
                ),
                "PORTAVOZ_PERF_HOST_MAXIMUM_INTERFERENCE_CPU_PERCENT": str(
                    readiness_policy.maximum_interference_cpu_percent
                ),
                "PORTAVOZ_PERF_HOST_CALIBRATION_SAMPLE_COUNT": str(
                    readiness_policy.calibration_sample_count
                ),
                "PORTAVOZ_PERF_HOST_CALIBRATION_BYTES_PER_SAMPLE": str(
                    readiness_policy.calibration_bytes_per_sample
                ),
                "PORTAVOZ_PERF_HOST_MAXIMUM_CALIBRATION_WALL_MILLISECONDS": str(
                    readiness_policy.maximum_calibration_wall_milliseconds
                ),
                "PORTAVOZ_PERF_HOST_MAXIMUM_CALIBRATION_CPU_MILLISECONDS": str(
                    readiness_policy.maximum_calibration_cpu_milliseconds
                ),
                "PORTAVOZ_PERF_HOST_MAXIMUM_CALIBRATION_DISPERSION_RATIO": str(
                    readiness_policy.maximum_calibration_dispersion_ratio
                ),
                "PORTAVOZ_PERF_STRICT": "0",
                "PORTAVOZ_PERF_WAVEFORM_MIC": None,
                "PORTAVOZ_PERF_WAVEFORM_SYSTEM": None,
                "PORTAVOZ_PERF_INCLUDE_DETAIL_UI": "0",
            },
            accepted_exit_codes=(0, 2),
        )
        ledger_path = run_root / "ledger.json"
        ledger, candidate_ids = validate_performance_run(
            ledger_path,
            contract,
            exit_code=exit_code,
            expected_commit=expected_commit,
            expected_binary_sha256=binary_sha256,
            expected_host=expected_host,
            expected_toolchain=expected_toolchain,
        )
        expected_host = ledger["host"]
        expected_toolchain = ledger["toolchain"]
        run_results.append({
            "run": run_number,
            "exitCode": exit_code,
            "ledgerSHA256": sha256_file(
                ledger_path,
                f"performance confirmation run {run_number} ledger",
            ),
            "candidateMetricIDs": candidate_ids,
            "root": run_root,
        })

    execute(1)
    if run_results[0]["candidateMetricIDs"]:
        for run_number in range(2, required_runs + 1):
            execute(run_number)

    candidate_sets = [set(run["candidateMetricIDs"]) for run in run_results]
    confirmed = (
        set.intersection(*candidate_sets)
        if len(candidate_sets) == required_runs
        else set()
    )
    clean_runs = [run for run in run_results if not run["candidateMetricIDs"]]
    selected = clean_runs[-1] if clean_runs else None
    if len(run_results) == 1:
        outcome = "clean-first-run"
    elif confirmed:
        outcome = "confirmed-regression"
        selected = None
    elif selected is None:
        outcome = "inconclusive"
    else:
        outcome = "unconfirmed-regression"

    confirmation = performance_confirmation_document(
        run_results,
        required_runs=required_runs,
        outcome=outcome,
        selected_run=selected["run"] if selected is not None else None,
        source_commit=expected_commit,
        binary_sha256=binary_sha256,
        build_wall_milliseconds=build_wall_milliseconds,
    )
    confirmation_path = runs_root / "confirmation.json"
    release_reliability.write_json(confirmation_path, confirmation)
    validate_performance_confirmation(
        confirmation_path,
        contract,
        runs_root=runs_root,
    )
    if selected is None:
        if confirmed:
            detail = ", ".join(sorted(confirmed))
            raise CandidateAutomationError(
                f"performance regression confirmed across three runs: {detail}"
            )
        raise CandidateAutomationError(
            "performance confirmation is inconclusive: no clean run in the "
            "fixed three-run set"
        )

    publish_performance_run(selected["root"], performance_root, confirmation_path)
    validate_performance_ledger(performance_root / "ledger.json", contract)
    for readiness_name in (
        "host-readiness.json",
        "host-readiness-semantic.json",
        "host-readiness-spotlight.json",
    ):
        try:
            perf_host_readiness.validate_receipt(
                load_json(
                    performance_root / readiness_name,
                    f"canonical performance {readiness_name}",
                ),
                policy=readiness_policy,
                expected_commit=expected_commit,
                expected_binary_sha256=binary_sha256,
            )
        except perf_host_readiness.ReadinessError as error:
            raise CandidateAutomationError(str(error)) from error
    validate_performance_confirmation(
        performance_root / "confirmation.json",
        contract,
        runs_root=runs_root,
    )
    print(
        "Performance confirmation: "
        f"{outcome}; selected run {selected['run']} of {len(run_results)}.",
        flush=True,
    )


def test_summary(output: str) -> tuple[int, int]:
    summaries = [line for line in output.splitlines() if EXECUTED_PATTERN.search(line)]
    if not summaries:
        raise CandidateAutomationError("Swift test output has no XCTest summary")
    summary = summaries[-1]
    executed_match = EXECUTED_PATTERN.search(summary)
    if executed_match is None:
        raise CandidateAutomationError("Swift test output has no XCTest summary")
    skipped_match = SKIPPED_PATTERN.search(summary)
    return int(executed_match.group(1)), (
        int(skipped_match.group(1)) if skipped_match else 0
    )


def run_swift_test_classes(
    root: Path,
    expected_commit: str,
    label: str,
    classes: Sequence[str],
    *,
    environment: dict[str, str | None] | None = None,
) -> None:
    test_environment = developer_environment()
    if environment:
        for key, value in environment.items():
            if value is None:
                test_environment.pop(key, None)
            else:
                test_environment[key] = value
    for class_name in classes:
        exact_checkout(root, expected_commit)
        print(f"==> {label}: {class_name}", flush=True)
        try:
            result = subprocess.run(
                [
                    "swift",
                    "test",
                    "--configuration",
                    "release",
                    "--filter",
                    class_name,
                ],
                cwd=root,
                env=test_environment,
                check=False,
                capture_output=True,
                text=True,
            )
        except OSError as error:
            raise CandidateAutomationError(
                f"{label} class {class_name} could not start"
            ) from error
        combined = result.stdout + "\n" + result.stderr
        try:
            executed, skipped = test_summary(combined)
        except CandidateAutomationError as error:
            raise CandidateAutomationError(
                f"{label} class {class_name} produced no valid test summary"
            ) from error
        print(f"{class_name}: executed={executed} skipped={skipped}", flush=True)
        if result.returncode != 0:
            raise CandidateAutomationError(
                f"{label} class {class_name} failed (private log withheld)"
            )
        if "[DEBUG] [FluidAudio." in combined:
            raise CandidateAutomationError(
                f"{label} class {class_name} emitted FluidAudio DEBUG output"
            )
        if executed <= 0:
            raise CandidateAutomationError(
                f"{label} class {class_name} matched no tests"
            )
        if skipped >= executed:
            raise CandidateAutomationError(
                f"{label} class {class_name} skipped every test"
            )
        exact_checkout(root, expected_commit)


def validate_public_model_fixture(
    path: Path,
    *,
    minimum_duration_seconds: float = 1,
    maximum_duration_seconds: float = 600,
) -> None:
    if (
        not math.isfinite(minimum_duration_seconds)
        or not math.isfinite(maximum_duration_seconds)
        or minimum_duration_seconds <= 0
        or maximum_duration_seconds < minimum_duration_seconds
        or maximum_duration_seconds > 600
    ):
        raise CandidateAutomationError(
            "public model audio fixture duration bounds are invalid"
        )
    if not path.is_file():
        raise CandidateAutomationError("public model audio fixture was not produced")
    size = path.stat().st_size
    if not 4_096 < size <= 64 * 1024 * 1024:
        raise CandidateAutomationError(
            "public model audio fixture is empty or outside its bounded size"
        )
    try:
        result = subprocess.run(
            ["afinfo", "-x", str(path)],
            check=True,
            capture_output=True,
            text=True,
        )
        document = ET.fromstring(result.stdout)
        channel_text = document.findtext(".//{*}num_channels")
        sample_rate_text = document.findtext(".//{*}sample_rate")
        audio_bytes_text = document.findtext(".//{*}audio_bytes")
        duration_text = document.findtext(".//{*}duration")
        channels = int(channel_text or "")
        sample_rate = float(sample_rate_text or "")
        audio_bytes = int(audio_bytes_text or "")
        duration = float(duration_text or "")
    except (
        OSError,
        subprocess.CalledProcessError,
        ET.ParseError,
        TypeError,
        ValueError,
    ) as error:
        raise CandidateAutomationError(
            "public model audio fixture metadata is unreadable"
        ) from error
    if (
        channels != 1
        or not math.isfinite(sample_rate)
        or sample_rate < 10
        or audio_bytes <= 4_096
        or not math.isfinite(duration)
        or not minimum_duration_seconds
        <= duration
        <= maximum_duration_seconds
    ):
        raise CandidateAutomationError(
            "public model audio fixture has empty or unbounded PCM metadata"
        )


def concatenate_public_wave_segments(
    segment_paths: Sequence[Path],
    output_path: Path,
    *,
    silence_milliseconds: int,
) -> None:
    if len(segment_paths) != len(EXPECTED_CONVERSATION_SEQUENCE):
        raise CandidateAutomationError(
            "public conversation requires exactly four rendered segments"
        )
    if silence_milliseconds != EXPECTED_CONVERSATION_SILENCE_MILLISECONDS:
        raise CandidateAutomationError(
            "public conversation silence duration drifted"
        )
    if output_path.exists():
        raise CandidateAutomationError(
            "public conversation output already exists"
        )

    expected_shape = (1, 2, 16_000, "NONE")
    chunks: list[bytes] = []
    try:
        for path in segment_paths:
            if (
                not path.is_file()
                or not 4_096 < path.stat().st_size <= 16 * 1024 * 1024
            ):
                raise CandidateAutomationError(
                    "public conversation segment is empty or outside its size bound"
                )
            with wave.open(str(path), "rb") as reader:
                shape = (
                    reader.getnchannels(),
                    reader.getsampwidth(),
                    reader.getframerate(),
                    reader.getcomptype(),
                )
                if shape != expected_shape:
                    raise CandidateAutomationError(
                        "public conversation segment is not mono 16 kHz Int16 PCM"
                    )
                frame_count = reader.getnframes()
                if not 16_000 <= frame_count <= 16_000 * 180:
                    raise CandidateAutomationError(
                        "public conversation segment duration is outside its bound"
                    )
                chunk = reader.readframes(frame_count)
                if len(chunk) != frame_count * expected_shape[1]:
                    raise CandidateAutomationError(
                        "public conversation segment PCM is truncated"
                    )
                chunks.append(chunk)
    except (OSError, wave.Error) as error:
        raise CandidateAutomationError(
            "public conversation segment is unreadable"
        ) from error

    temporary = output_path.with_name(f".{output_path.name}.tmp")
    silence_frames = round(
        expected_shape[2] * silence_milliseconds / 1_000
    )
    silence = b"\0" * (silence_frames * expected_shape[1])
    try:
        descriptor = os.open(
            temporary,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL,
            0o600,
        )
        with os.fdopen(descriptor, "wb") as raw_output:
            with wave.open(raw_output, "wb") as writer:
                writer.setnchannels(expected_shape[0])
                writer.setsampwidth(expected_shape[1])
                writer.setframerate(expected_shape[2])
                writer.setcomptype(expected_shape[3], "not compressed")
                for index, chunk in enumerate(chunks):
                    if index:
                        writer.writeframesraw(silence)
                    writer.writeframesraw(chunk)
            raw_output.flush()
            os.fsync(raw_output.fileno())
        os.replace(temporary, output_path)
        os.chmod(output_path, 0o600)
    except (OSError, wave.Error) as error:
        temporary.unlink(missing_ok=True)
        output_path.unlink(missing_ok=True)
        raise CandidateAutomationError(
            "public conversation fixture could not be published"
        ) from error


def render_public_conversation(
    root: Path,
    expected_commit: str,
    fixture: dict[str, Any],
    output_path: Path,
    *,
    environment: dict[str, str | None],
) -> None:
    turns = fixture["conversationTurns"]
    if tuple(voice for voice, _ in turns) != EXPECTED_CONVERSATION_SEQUENCE:
        raise CandidateAutomationError("public conversation turn sequence drifted")
    segments = tuple(
        output_path.with_name(f".{output_path.stem}-turn-{index}.wav")
        for index in range(len(turns))
    )
    if output_path.exists() or any(segment.exists() for segment in segments):
        raise CandidateAutomationError(
            "public conversation scratch paths must start empty"
        )
    try:
        for index, ((voice, text), segment) in enumerate(zip(turns, segments)):
            run_command(
                root,
                expected_commit,
                f"Public bilingual model fixture turn {index + 1}",
                [
                    "say",
                    "-v",
                    voice,
                    "-r",
                    str(fixture["rateWordsPerMinute"]),
                    "-o",
                    str(segment),
                    "--file-format=WAVE",
                    "--data-format=LEI16@16000",
                    text,
                ],
                environment=environment,
            )
            validate_public_model_fixture(
                segment,
                minimum_duration_seconds=10,
                maximum_duration_seconds=180,
            )
        concatenate_public_wave_segments(
            segments,
            output_path,
            silence_milliseconds=fixture["conversationSilenceMilliseconds"],
        )
        exact_checkout(root, expected_commit)
    finally:
        for segment in segments:
            segment.unlink(missing_ok=True)


def candidate_receipt(
    *, version: str, build: str, commit: str, proofs: Sequence[str]
) -> dict[str, Any]:
    expected = tuple(
        release_reliability.QUALIFICATION_RECEIPTS["candidate-automation"][
            "proofs"
        ]
    )
    if tuple(proofs) != expected:
        raise CandidateAutomationError(
            "candidate receipt requires every proof in the canonical order"
        )
    try:
        release = {
            "version": release_reliability.safe_string(
                version, "release.version", release_reliability.VERSION_PATTERN
            ),
            "build": release_reliability.safe_string(
                build, "release.build", release_reliability.BUILD_PATTERN
            ),
            "commit": release_reliability.safe_string(
                commit, "release.commit", release_reliability.COMMIT_PATTERN
            ),
        }
    except release_reliability.ReliabilityError as error:
        raise CandidateAutomationError(str(error)) from error
    receipt = {
        "schemaVersion": release_reliability.RECEIPT_SCHEMA_VERSION,
        "kind": "qualification",
        "scope": "candidate-automation",
        "collectedAt": utc_now(),
        "release": release,
        "proofs": [
            {"id": identifier, "state": "pass"} for identifier in expected
        ],
    }
    try:
        release_reliability.validate_qualification_receipt(
            receipt, "candidate qualification receipt"
        )
    except release_reliability.ReliabilityError as error:
        raise CandidateAutomationError(str(error)) from error
    return receipt


def prepare_output(path: Path) -> Path:
    output = path.expanduser().resolve()
    if output.exists():
        raise CandidateAutomationError(f"candidate output already exists: {output}")
    output.mkdir(parents=True, mode=0o700)
    os.chmod(output, 0o700)
    return output


def default_output(commit: str) -> Path:
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    return DEFAULT_OUTPUT_PARENT / f"candidate-{commit[:12]}-{stamp}"


def _run_candidate(
    *,
    version: str,
    build: str,
    contract_path: Path = DEFAULT_CONTRACT,
    output_path: Path | None = None,
    root: Path = ROOT,
) -> Path:
    commit = exact_checkout(root)
    try:
        version = release_reliability.safe_string(
            version, "release.version", release_reliability.VERSION_PATTERN
        )
        build = release_reliability.safe_string(
            build, "release.build", release_reliability.BUILD_PATTERN
        )
    except release_reliability.ReliabilityError as error:
        raise CandidateAutomationError(str(error)) from error
    contract = load_contract(contract_path, root)
    profile = detect_profile(contract, physical_memory_bytes())
    output = prepare_output(output_path or default_output(commit))
    deterministic = output / "deterministic.json"
    performance_root = output / "performance"
    resource_root = output / "resource"
    memory_leak_root = output / "memory-leaks"
    long_capture = output / "long-capture.json"
    ui_root = output / "ui"
    model_audio = output / "public-model-lane.aiff"
    model_conversation = output / "public-diarization-lane.wav"

    private_fixture_environment: dict[str, str | None] = {
        "PORTAVOZ_MODEL_TESTS": None,
        "PORTAVOZ_TEST_WAV": None,
        "PORTAVOZ_TEST_CONVERSATION_WAV": None,
        "PORTAVOZ_TEST_AUDIO_ROOT": None,
        "TEST_RUNNER_PORTAVOZ_TEST_AUDIO_ROOT": None,
    }

    # Build the latency-sensitive CLI exactly once before XCTest, model
    # execution, Apple's leak instrumentation, or resource collection can
    # leave unrelated compiler, symbolication, or model work competing with
    # the fixed PERF-008 observation set. The performance runner then waits on
    # its bounded host predicate and every harness validates this one SHA-256.
    performance_build = build_candidate_performance_binary(
        root,
        commit,
        environment=private_fixture_environment,
    )

    # Measure latency-sensitive evidence before XCTest, model execution,
    # Apple's leak instrumentation, or resource collection can leave unrelated
    # compiler, symbolication, or model work competing with the fixed PERF-008
    # observation set. The ledger still rejects external host contention; this
    # ordering only prevents the candidate runner from creating that contention
    # itself and makes a noisy-host failure happen before the expensive gates.
    run_candidate_performance_gate(
        root,
        commit,
        performance_root,
        contract,
        binary_path=performance_build["path"],
        binary_sha256=performance_build["sha256"],
        build_wall_milliseconds=performance_build["wallMilliseconds"],
        environment=private_fixture_environment,
    )
    if sha256_file(
        performance_build["path"],
        "exact performance Release binary after measurement",
        maximum_bytes=512 * 1024 * 1024,
    ) != performance_build["sha256"]:
        raise CandidateAutomationError(
            "exact performance Release binary changed during measurement"
        )

    run_command(
        root,
        commit,
        "Finite deterministic release scope",
        ["scripts/run-release-reliability-gates.sh"],
        environment={
            "PORTAVOZ_RELEASE_VERSION": version,
            "PORTAVOZ_RELEASE_BUILD": build,
            "PORTAVOZ_RELIABILITY_RECEIPT": str(deterministic),
            **private_fixture_environment,
        },
    )
    validate_deterministic_receipt(
        deterministic, version=version, build=build, commit=commit
    )

    run_command(
        root,
        commit,
        "Public bilingual autonomous validation",
        ["make", "test-apuntador-validation"],
    )
    fixture = contract["modelFixture"]
    try:
        run_command(
            root,
            commit,
            "Public synthetic spoken model fixture",
            [
                "say",
                "-v",
                fixture["systemVoice"],
                "-r",
                str(fixture["rateWordsPerMinute"]),
                "-o",
                str(model_audio),
                "-f",
                str(fixture["textPath"]),
            ],
            environment=private_fixture_environment,
        )
        validate_public_model_fixture(model_audio)
        render_public_conversation(
            root,
            commit,
            fixture,
            model_conversation,
            environment=private_fixture_environment,
        )
        validate_public_model_fixture(
            model_conversation,
            minimum_duration_seconds=MINIMUM_CONVERSATION_DURATION_SECONDS,
        )
        run_swift_test_classes(
            root,
            commit,
            "Installed model/capability gate",
            contract["modelClasses"],
            environment={
                "PORTAVOZ_MODEL_TESTS": "1",
                "PORTAVOZ_TEST_WAV": str(model_audio),
                "PORTAVOZ_TEST_CONVERSATION_WAV": str(model_conversation),
                "PORTAVOZ_TEST_AUDIO_ROOT": None,
                "TEST_RUNNER_PORTAVOZ_TEST_AUDIO_ROOT": None,
            },
        )
    finally:
        model_audio.unlink(missing_ok=True)
        model_conversation.unlink(missing_ok=True)

    run_command(
        root,
        commit,
        "Content-free real-app Apuntador leak baseline",
        [
            "scripts/run-apuntador-leak-baseline.sh",
            "--version",
            version,
            "--build",
            build,
            "--live-assist-iterations",
            str(contract["memoryLeaks"]["scenarioIterations"][
                "live-assist-released"
            ]),
            "--output",
            str(memory_leak_root),
        ],
        environment={
            "PORTAVOZ_SIGN_IDENTITY": "-",
            **private_fixture_environment,
        },
    )
    validate_memory_leak_receipt(
        memory_leak_root / "receipt.json",
        contract,
        version=version,
        build=build,
        commit=commit,
    )

    run_command(
        root,
        commit,
        f"Release resource baseline ({profile})",
        [
            "scripts/run-resource-baseline.sh",
            "--profile",
            profile,
            "--version",
            version,
            "--build",
            build,
            "--runs",
            str(contract["resource"]["samplesPerScenario"]),
            "--output",
            str(resource_root),
        ],
        environment={
            "PORTAVOZ_SIGN_IDENTITY": "-",
            **private_fixture_environment,
        },
    )
    validate_resource_receipt(
        resource_root / "receipt.json",
        contract,
        version=version,
        build=build,
        commit=commit,
        profile=profile,
    )

    run_command(
        root,
        commit,
        "Accelerated canonical three-hour capture",
        ["scripts/run-long-capture-baseline.sh", str(long_capture)],
    )
    validate_long_capture(long_capture, commit)

    run_swift_test_classes(
        root,
        commit,
        "Upgrade and recovery gate",
        contract["upgradeRecoveryClasses"],
    )

    run_command(
        root,
        commit,
        "Complete bilingual real-app XCUITest",
        ["make", "test-ui-bilingual"],
        environment={
            "UI_TEST_RESULTS_DIR": str(ui_root),
            **private_fixture_environment,
        },
    )
    validate_ui_receipts(ui_root, contract)

    exact_checkout(root, commit)
    receipt = candidate_receipt(
        version=version,
        build=build,
        commit=commit,
        proofs=contract["proofs"],
    )
    receipt_path = output / "qualification.json"
    release_reliability.write_json(receipt_path, receipt)
    exact_checkout(root, commit)
    print(f"Candidate automation qualified: {receipt_path}", flush=True)
    return receipt_path


def run_candidate(
    *,
    version: str,
    build: str,
    contract_path: Path = DEFAULT_CONTRACT,
    output_path: Path | None = None,
    root: Path = ROOT,
) -> Path:
    previous_umask = os.umask(0o077)
    try:
        return _run_candidate(
            version=version,
            build=build,
            contract_path=contract_path,
            output_path=output_path,
            root=root,
        )
    finally:
        os.umask(previous_umask)


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    result.add_argument("--version", required=True)
    result.add_argument("--build", required=True)
    result.add_argument("--output", type=Path)
    return result


def main(argv: Iterable[str] | None = None) -> int:
    arguments = parser().parse_args(argv)
    try:
        run_candidate(
            version=arguments.version,
            build=arguments.build,
            output_path=arguments.output,
        )
    except (
        CandidateAutomationError,
        OSError,
        release_reliability.ReliabilityError,
        resource_baseline.ResourceBaselineError,
        long_capture_evidence.EvidenceError,
    ) as error:
        print(f"candidate automation error: {error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
