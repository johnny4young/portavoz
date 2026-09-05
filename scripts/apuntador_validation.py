#!/usr/bin/env python3
"""Validate and score the public bilingual Apuntador 1.0 scenario corpus.

The corpus contains public synthetic text. Runtime observations and scorecards
are deliberately content-free: they retain only stable identities, outcomes,
timings, and aggregate quality verdicts.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import re
import sys
from collections import Counter
from datetime import datetime
from pathlib import Path
from typing import Any, Iterable, Sequence


SCHEMA_VERSION = 1
FIXTURE_KIND = "apuntador-validation-fixture"
BUDGET_KIND = "apuntador-validation-budget"
OBSERVATION_KIND = "apuntador-validation-observations"
SCORECARD_KIND = "apuntador-validation-scorecard"
GENERATION = "public-bilingual-v1"
CONTENT_SOURCE = "public-synthetic-only"
CANONICAL_FIXTURE_SHA256 = (
    "4677098f8bb0a49424936ba602d53147346663b802e897de9a9418a9ab743e0e"
)
CANONICAL_BUDGET_SHA256 = (
    "eb7631cd3bc889dee56750a789641f0c3e1a64f240116f9dae7e9f111d8cd2da"
)

SOURCE_KINDS = {"meeting", "interview", "note"}
LANGUAGES = {"en", "es"}
CLAIM_STATUSES = {"supported", "forbidden"}
FAULTS = {
    "none",
    "cancelBeforeEvidence",
    "timeout",
    "offline",
    "providerDown",
    "corruptedState",
    "relaunch",
}
OUTCOMES = {
    "answered",
    "abstained",
    "cancelled",
    "timedOut",
    "unavailable",
    "recovered",
}
EXPECTED_FAULT_OUTCOMES = {
    "cancelBeforeEvidence": "cancelled",
    "timeout": "timedOut",
    "offline": "unavailable",
    "providerDown": "unavailable",
    "corruptedState": "unavailable",
    "relaunch": "recovered",
}
SAFE_ID = re.compile(r"^[a-z0-9][a-z0-9.-]{0,79}$")
SAFE_VERSION = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._+-]{0,79}$")
COMMIT = re.compile(r"^[0-9a-f]{40}$")
SHA256 = re.compile(r"^[0-9a-f]{64}$")


class ApuntadorValidationError(ValueError):
    """Fail-closed corpus, observation, or budget error."""


def reject_duplicate_keys(pairs: Sequence[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise ApuntadorValidationError(f"duplicate key: {key}")
        result[key] = value
    return result


def load_json(path: Path | str, label: str, maximum_bytes: int = 2_000_000) -> Any:
    source = Path(path)
    try:
        if not source.is_file():
            raise ApuntadorValidationError(f"{label} not found: {source}")
        if source.stat().st_size > maximum_bytes:
            raise ApuntadorValidationError(f"{label} exceeds the size limit")
        return json.loads(
            source.read_text(encoding="utf-8"),
            object_pairs_hook=reject_duplicate_keys,
        )
    except OSError as error:
        raise ApuntadorValidationError(f"{label} could not be read") from error
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ApuntadorValidationError(
            f"{label} is not valid UTF-8 JSON"
        ) from error


def file_sha256(path: Path | str) -> str:
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def object_shape(
    value: Any,
    path: str,
    required: Iterable[str],
    optional: Iterable[str] = (),
) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise ApuntadorValidationError(f"{path} must be an object")
    required_keys = set(required)
    allowed = required_keys | set(optional)
    missing = required_keys - value.keys()
    extra = value.keys() - allowed
    if missing:
        raise ApuntadorValidationError(
            f"{path} is missing keys: {', '.join(sorted(missing))}"
        )
    if extra:
        raise ApuntadorValidationError(
            f"{path} contains forbidden keys: {', '.join(sorted(extra))}"
        )
    return value


def safe_string(value: Any, path: str, pattern: re.Pattern[str] = SAFE_ID) -> str:
    if not isinstance(value, str) or pattern.fullmatch(value) is None:
        raise ApuntadorValidationError(f"{path} has an unsafe value")
    return value


def bounded_text(value: Any, path: str, maximum: int) -> str:
    if not isinstance(value, str):
        raise ApuntadorValidationError(f"{path} must be text")
    if value != value.strip() or not value or len(value) > maximum or "\x00" in value:
        raise ApuntadorValidationError(
            f"{path} must contain 1 to {maximum} trimmed safe characters"
        )
    return value


def enum_value(value: Any, path: str, allowed: set[str]) -> str:
    if not isinstance(value, str) or value not in allowed:
        raise ApuntadorValidationError(
            f"{path} must be one of: {', '.join(sorted(allowed))}"
        )
    return value


def integer(value: Any, path: str, minimum: int = 0, maximum: int | None = None) -> int:
    if isinstance(value, bool) or not isinstance(value, int):
        raise ApuntadorValidationError(f"{path} must be an integer")
    if value < minimum or (maximum is not None and value > maximum):
        raise ApuntadorValidationError(f"{path} is outside its accepted range")
    return value


def number(
    value: Any,
    path: str,
    minimum: float = 0,
    maximum: float | None = None,
) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise ApuntadorValidationError(f"{path} must be numeric")
    result = float(value)
    if (
        not math.isfinite(result)
        or result < minimum
        or (maximum is not None and result > maximum)
    ):
        raise ApuntadorValidationError(f"{path} is outside its finite range")
    return result


def iso8601(value: Any, path: str) -> str:
    if not isinstance(value, str) or not value.endswith("Z"):
        raise ApuntadorValidationError(f"{path} must be an ISO-8601 UTC instant")
    try:
        datetime.fromisoformat(value.removesuffix("Z") + "+00:00")
    except ValueError as error:
        raise ApuntadorValidationError(
            f"{path} must be an ISO-8601 UTC instant"
        ) from error
    return value


def string_array(
    value: Any,
    path: str,
    *,
    maximum: int = 20,
    allowed: set[str] | None = None,
) -> list[str]:
    if not isinstance(value, list) or len(value) > maximum:
        raise ApuntadorValidationError(
            f"{path} must be an array with at most {maximum} values"
        )
    result = [safe_string(item, f"{path}[{index}]") for index, item in enumerate(value)]
    if len(result) != len(set(result)):
        raise ApuntadorValidationError(f"{path} must not contain duplicates")
    if allowed is not None and not set(result) <= allowed:
        raise ApuntadorValidationError(f"{path} contains an unknown value")
    return result


def validate_fixture(document: Any) -> dict[str, Any]:
    root = object_shape(
        document,
        "fixture",
        (
            "schemaVersion",
            "kind",
            "generation",
            "contentSource",
            "frozenAt",
            "sources",
            "claims",
            "scenarios",
        ),
    )
    if integer(root["schemaVersion"], "fixture.schemaVersion") != SCHEMA_VERSION:
        raise ApuntadorValidationError("fixture.schemaVersion must be 1")
    if root["kind"] != FIXTURE_KIND:
        raise ApuntadorValidationError(f"fixture.kind must be {FIXTURE_KIND}")
    if root["generation"] != GENERATION:
        raise ApuntadorValidationError(f"fixture.generation must be {GENERATION}")
    if root["contentSource"] != CONTENT_SOURCE:
        raise ApuntadorValidationError(
            f"fixture.contentSource must be {CONTENT_SOURCE}"
        )
    iso8601(root["frozenAt"], "fixture.frozenAt")

    if not isinstance(root["sources"], list) or not root["sources"]:
        raise ApuntadorValidationError("fixture.sources must be nonempty")
    sources: dict[str, dict[str, Any]] = {}
    evidence: dict[str, dict[str, Any]] = {}
    source_distribution: Counter[tuple[str, str]] = Counter()
    for index, raw_source in enumerate(root["sources"]):
        path = f"fixture.sources[{index}]"
        source = object_shape(
            raw_source,
            path,
            (
                "id",
                "kind",
                "language",
                "title",
                "occurredAt",
                "author",
                "participants",
                "objective",
                "passages",
            ),
        )
        source_id = safe_string(source["id"], f"{path}.id")
        if source_id in sources:
            raise ApuntadorValidationError(f"duplicate source: {source_id}")
        kind = enum_value(source["kind"], f"{path}.kind", SOURCE_KINDS)
        language = enum_value(source["language"], f"{path}.language", LANGUAGES)
        bounded_text(source["title"], f"{path}.title", 160)
        iso8601(source["occurredAt"], f"{path}.occurredAt")
        participants = source["participants"]
        if not isinstance(participants, list) or len(participants) > 12:
            raise ApuntadorValidationError(f"{path}.participants has invalid shape")
        for participant_index, participant in enumerate(participants):
            bounded_text(
                participant,
                f"{path}.participants[{participant_index}]",
                80,
            )
        if len(set(participants)) != len(participants):
            raise ApuntadorValidationError(f"{path}.participants repeats a person")
        if kind == "note":
            bounded_text(source["author"], f"{path}.author", 80)
            if participants or source["objective"] is not None:
                raise ApuntadorValidationError(
                    f"{path} note provenance must be author-only"
                )
        else:
            if source["author"] is not None or len(participants) < 2:
                raise ApuntadorValidationError(
                    f"{path} spoken source must have participants and no author"
                )
            if kind == "interview":
                bounded_text(source["objective"], f"{path}.objective", 240)
            elif source["objective"] is not None:
                raise ApuntadorValidationError(
                    f"{path} meeting must not invent an interview objective"
                )
        if not isinstance(source["passages"], list) or len(source["passages"]) != 2:
            raise ApuntadorValidationError(
                f"{path}.passages must contain one fact and one distractor"
            )
        for passage_index, raw_passage in enumerate(source["passages"]):
            passage_path = f"{path}.passages[{passage_index}]"
            passage = object_shape(
                raw_passage,
                passage_path,
                ("id", "ordinal", "timestampMilliseconds", "text"),
            )
            passage_id = safe_string(passage["id"], f"{passage_path}.id")
            if passage_id in evidence:
                raise ApuntadorValidationError(f"duplicate evidence: {passage_id}")
            if integer(passage["ordinal"], f"{passage_path}.ordinal", 0, 1) != passage_index:
                raise ApuntadorValidationError(
                    f"{passage_path}.ordinal must match array order"
                )
            timestamp = passage["timestampMilliseconds"]
            if kind == "note":
                if timestamp is not None:
                    raise ApuntadorValidationError(
                        f"{passage_path} note passage must not invent audio time"
                    )
            else:
                integer(timestamp, f"{passage_path}.timestampMilliseconds", 0, 86_400_000)
            bounded_text(passage["text"], f"{passage_path}.text", 500)
            evidence[passage_id] = {
                "sourceID": source_id,
                "kind": kind,
                "language": language,
            }
        sources[source_id] = {"kind": kind, "language": language}
        source_distribution[(kind, language)] += 1
    expected_source_distribution = Counter(
        {(kind, language): 1 for kind in SOURCE_KINDS for language in LANGUAGES}
    )
    if source_distribution != expected_source_distribution:
        raise ApuntadorValidationError(
            "fixture source distribution must be exactly one source per kind/language"
        )

    if not isinstance(root["claims"], list) or not root["claims"]:
        raise ApuntadorValidationError("fixture.claims must be nonempty")
    claims: dict[str, dict[str, Any]] = {}
    claim_distribution: Counter[tuple[str, str, str]] = Counter()
    for index, raw_claim in enumerate(root["claims"]):
        path = f"fixture.claims[{index}]"
        claim = object_shape(
            raw_claim,
            path,
            ("id", "language", "status", "text", "evidenceIDs"),
        )
        claim_id = safe_string(claim["id"], f"{path}.id")
        if claim_id in claims:
            raise ApuntadorValidationError(f"duplicate claim: {claim_id}")
        language = enum_value(claim["language"], f"{path}.language", LANGUAGES)
        status = enum_value(claim["status"], f"{path}.status", CLAIM_STATUSES)
        bounded_text(claim["text"], f"{path}.text", 500)
        evidence_ids = string_array(
            claim["evidenceIDs"],
            f"{path}.evidenceIDs",
            maximum=4,
            allowed=set(evidence),
        )
        if not evidence_ids:
            raise ApuntadorValidationError(f"{path}.evidenceIDs must be nonempty")
        evidence_kinds = {evidence[item]["kind"] for item in evidence_ids}
        evidence_languages = {evidence[item]["language"] for item in evidence_ids}
        if len(evidence_kinds) != 1 or evidence_languages != {language}:
            raise ApuntadorValidationError(
                f"{path} must preserve one typed same-language source"
            )
        source_kind = next(iter(evidence_kinds))
        claims[claim_id] = {
            "status": status,
            "language": language,
            "evidenceIDs": set(evidence_ids),
            "kind": source_kind,
        }
        claim_distribution[(source_kind, language, status)] += 1
    expected_claim_distribution = Counter({
        (kind, language, status): 1
        for kind in SOURCE_KINDS
        for language in LANGUAGES
        for status in CLAIM_STATUSES
    })
    if claim_distribution != expected_claim_distribution:
        raise ApuntadorValidationError(
            "fixture claim distribution must be exactly supported/forbidden per kind/language"
        )

    if not isinstance(root["scenarios"], list) or not root["scenarios"]:
        raise ApuntadorValidationError("fixture.scenarios must be nonempty")
    scenarios: dict[str, dict[str, Any]] = {}
    scenario_distribution: Counter[tuple[str, str, str]] = Counter()
    normal_outcome_distribution: Counter[tuple[str, str, str]] = Counter()
    for index, raw_scenario in enumerate(root["scenarios"]):
        path = f"fixture.scenarios[{index}]"
        scenario = object_shape(
            raw_scenario,
            path,
            (
                "id",
                "language",
                "sourceKinds",
                "question",
                "fault",
                "expectedOutcome",
                "expectedClaimIDs",
                "expectedEvidenceIDs",
                "hardNegativeEvidenceIDs",
                "forbiddenClaimIDs",
            ),
        )
        scenario_id = safe_string(scenario["id"], f"{path}.id")
        if scenario_id in scenarios:
            raise ApuntadorValidationError(f"duplicate scenario: {scenario_id}")
        language = enum_value(scenario["language"], f"{path}.language", LANGUAGES)
        source_kinds = string_array(
            scenario["sourceKinds"],
            f"{path}.sourceKinds",
            maximum=3,
            allowed=SOURCE_KINDS,
        )
        if len(source_kinds) != 1:
            raise ApuntadorValidationError(
                f"{path}.sourceKinds must declare one exact source kind"
            )
        bounded_text(scenario["question"], f"{path}.question", 300)
        fault = enum_value(scenario["fault"], f"{path}.fault", FAULTS)
        outcome = enum_value(
            scenario["expectedOutcome"], f"{path}.expectedOutcome", OUTCOMES
        )
        if fault == "none":
            if outcome not in {"answered", "abstained"}:
                raise ApuntadorValidationError(
                    f"{path} normal scenario must answer or abstain"
                )
        elif outcome != EXPECTED_FAULT_OUTCOMES[fault]:
            raise ApuntadorValidationError(
                f"{path} outcome does not match its declared fault"
            )
        expected_claims = string_array(
            scenario["expectedClaimIDs"],
            f"{path}.expectedClaimIDs",
            maximum=4,
            allowed=set(claims),
        )
        expected_evidence = string_array(
            scenario["expectedEvidenceIDs"],
            f"{path}.expectedEvidenceIDs",
            maximum=8,
            allowed=set(evidence),
        )
        hard_negatives = string_array(
            scenario["hardNegativeEvidenceIDs"],
            f"{path}.hardNegativeEvidenceIDs",
            maximum=8,
            allowed=set(evidence),
        )
        forbidden_claims = string_array(
            scenario["forbiddenClaimIDs"],
            f"{path}.forbiddenClaimIDs",
            maximum=4,
            allowed=set(claims),
        )
        if not hard_negatives or not forbidden_claims:
            raise ApuntadorValidationError(
                f"{path} must retain adversarial distractor ground truth"
            )
        if set(expected_evidence) & set(hard_negatives):
            raise ApuntadorValidationError(
                f"{path} expected and hard-negative evidence overlap"
            )
        if set(expected_claims) & set(forbidden_claims):
            raise ApuntadorValidationError(
                f"{path} expected and forbidden claims overlap"
            )
        all_evidence = expected_evidence + hard_negatives
        if any(
            evidence[item]["language"] != language
            or evidence[item]["kind"] not in source_kinds
            for item in all_evidence
        ):
            raise ApuntadorValidationError(
                f"{path} evidence escapes its declared language/source scope"
            )
        if any(
            claims[item]["language"] != language
            or claims[item]["kind"] not in source_kinds
            or claims[item]["status"] != "supported"
            for item in expected_claims
        ):
            raise ApuntadorValidationError(
                f"{path} expected claims are not supported in scope"
            )
        if any(claims[item]["status"] != "forbidden" for item in forbidden_claims):
            raise ApuntadorValidationError(
                f"{path} forbiddenClaimIDs must name forbidden claims"
            )
        if any(
            claims[item]["language"] != language
            or claims[item]["kind"] not in source_kinds
            for item in forbidden_claims
        ):
            raise ApuntadorValidationError(
                f"{path} forbidden claims escape their declared language/source scope"
            )
        output_expected = outcome in {"answered", "recovered"}
        if output_expected != bool(expected_claims) or output_expected != bool(expected_evidence):
            raise ApuntadorValidationError(
                f"{path} output ground truth does not match expected outcome"
            )
        if any(
            not claims[claim_id]["evidenceIDs"] <= set(expected_evidence)
            for claim_id in expected_claims
        ):
            raise ApuntadorValidationError(
                f"{path} claim evidence is absent from expected citations"
            )
        kind = source_kinds[0]
        scenarios[scenario_id] = {
            "language": language,
            "kind": kind,
            "fault": fault,
            "expectedOutcome": outcome,
            "expectedClaims": set(expected_claims),
            "expectedEvidence": set(expected_evidence),
            "hardNegatives": set(hard_negatives),
            "forbiddenClaims": set(forbidden_claims),
        }
        scenario_distribution[(kind, language, fault)] += 1
        if fault == "none":
            normal_outcome_distribution[(kind, language, outcome)] += 1

    if len(scenarios) != 24:
        raise ApuntadorValidationError("fixture must contain exactly 24 scenarios")
    for kind in SOURCE_KINDS:
        for language in LANGUAGES:
            if (
                scenario_distribution[(kind, language, "none")] != 2
                or normal_outcome_distribution[(kind, language, "answered")] != 1
                or normal_outcome_distribution[(kind, language, "abstained")] != 1
            ):
                raise ApuntadorValidationError(
                    "fixture must contain answer and abstention per kind/language"
                )
    for fault in EXPECTED_FAULT_OUTCOMES:
        for language in LANGUAGES:
            matching = sum(
                count
                for (kind, item_language, item_fault), count in scenario_distribution.items()
                if item_language == language and item_fault == fault
            )
            if matching != 1:
                raise ApuntadorValidationError(
                    f"fixture must contain one {fault} scenario per language"
                )
    return {
        "generation": GENERATION,
        "contentSource": CONTENT_SOURCE,
        "sources": sources,
        "evidence": evidence,
        "claims": claims,
        "scenarios": scenarios,
    }


def validate_budget(document: Any, fixture_checksum: str) -> dict[str, Any]:
    root = object_shape(
        document,
        "budget",
        (
            "schemaVersion",
            "kind",
            "fixtureGeneration",
            "fixtureChecksum",
            "quality",
            "timing",
        ),
    )
    if integer(root["schemaVersion"], "budget.schemaVersion") != SCHEMA_VERSION:
        raise ApuntadorValidationError("budget.schemaVersion must be 1")
    if root["kind"] != BUDGET_KIND:
        raise ApuntadorValidationError(f"budget.kind must be {BUDGET_KIND}")
    if root["fixtureGeneration"] != GENERATION:
        raise ApuntadorValidationError("budget.fixtureGeneration is stale")
    if root["fixtureChecksum"] != fixture_checksum:
        raise ApuntadorValidationError("budget.fixtureChecksum is stale")
    quality = object_shape(
        root["quality"],
        "budget.quality",
        (
            "expectedScenarioCount",
            "minimumOutcomeAccuracy",
            "minimumCitationPrecision",
            "minimumEvidenceRecall",
            "minimumClaimPrecision",
            "minimumClaimRecall",
            "maximumHardNegativeCitations",
            "maximumForbiddenClaims",
            "maximumLatePublicationsAfterTerminal",
        ),
    )
    timing = object_shape(
        root["timing"],
        "budget.timing",
        (
            "maximumFirstEvidenceMilliseconds",
            "maximumCompletionMilliseconds",
            "maximumP95CompletionMilliseconds",
        ),
    )
    expected_scenario_count = integer(
            quality["expectedScenarioCount"],
            "budget.quality.expectedScenarioCount",
            1,
        )
    if expected_scenario_count != 24:
        raise ApuntadorValidationError(
            "budget.quality.expectedScenarioCount must match the 24-case fixture"
        )
    return {
        "expectedScenarioCount": expected_scenario_count,
        "minimumOutcomeAccuracy": number(
            quality["minimumOutcomeAccuracy"],
            "budget.quality.minimumOutcomeAccuracy",
            maximum=1,
        ),
        "minimumCitationPrecision": number(
            quality["minimumCitationPrecision"],
            "budget.quality.minimumCitationPrecision",
            maximum=1,
        ),
        "minimumEvidenceRecall": number(
            quality["minimumEvidenceRecall"],
            "budget.quality.minimumEvidenceRecall",
            maximum=1,
        ),
        "minimumClaimPrecision": number(
            quality["minimumClaimPrecision"],
            "budget.quality.minimumClaimPrecision",
            maximum=1,
        ),
        "minimumClaimRecall": number(
            quality["minimumClaimRecall"],
            "budget.quality.minimumClaimRecall",
            maximum=1,
        ),
        "maximumHardNegativeCitations": integer(
            quality["maximumHardNegativeCitations"],
            "budget.quality.maximumHardNegativeCitations",
        ),
        "maximumForbiddenClaims": integer(
            quality["maximumForbiddenClaims"],
            "budget.quality.maximumForbiddenClaims",
        ),
        "maximumLatePublicationsAfterTerminal": integer(
            quality["maximumLatePublicationsAfterTerminal"],
            "budget.quality.maximumLatePublicationsAfterTerminal",
        ),
        "maximumFirstEvidenceMilliseconds": number(
            timing["maximumFirstEvidenceMilliseconds"],
            "budget.timing.maximumFirstEvidenceMilliseconds",
        ),
        "maximumCompletionMilliseconds": number(
            timing["maximumCompletionMilliseconds"],
            "budget.timing.maximumCompletionMilliseconds",
        ),
        "maximumP95CompletionMilliseconds": number(
            timing["maximumP95CompletionMilliseconds"],
            "budget.timing.maximumP95CompletionMilliseconds",
        ),
    }


def validate_observations(
    document: Any,
    fixture: dict[str, Any],
    fixture_checksum: str,
) -> dict[str, Any]:
    root = object_shape(
        document,
        "observations",
        (
            "schemaVersion",
            "kind",
            "fixtureGeneration",
            "fixtureChecksum",
            "adapter",
            "run",
            "scenarios",
        ),
    )
    if integer(root["schemaVersion"], "observations.schemaVersion") != SCHEMA_VERSION:
        raise ApuntadorValidationError("observations.schemaVersion must be 1")
    if root["kind"] != OBSERVATION_KIND:
        raise ApuntadorValidationError(
            f"observations.kind must be {OBSERVATION_KIND}"
        )
    if root["fixtureGeneration"] != GENERATION:
        raise ApuntadorValidationError("observations.fixtureGeneration is stale")
    if root["fixtureChecksum"] != fixture_checksum:
        raise ApuntadorValidationError("observations.fixtureChecksum is stale")
    adapter = object_shape(
        root["adapter"], "observations.adapter", ("id", "version")
    )
    subject = {
        "adapterID": safe_string(adapter["id"], "observations.adapter.id"),
        "adapterVersion": safe_string(
            adapter["version"], "observations.adapter.version", SAFE_VERSION
        ),
    }
    run = object_shape(
        root["run"],
        "observations.run",
        ("commit", "build", "platform", "osVersion", "architecture"),
    )
    subject.update({
        "commit": safe_string(run["commit"], "observations.run.commit", COMMIT),
        "build": safe_string(run["build"], "observations.run.build", SAFE_VERSION),
        "platform": safe_string(
            run["platform"], "observations.run.platform", SAFE_VERSION
        ),
        "osVersion": safe_string(
            run["osVersion"], "observations.run.osVersion", SAFE_VERSION
        ),
        "architecture": safe_string(
            run["architecture"], "observations.run.architecture", SAFE_VERSION
        ),
    })
    if not isinstance(root["scenarios"], list) or not root["scenarios"]:
        raise ApuntadorValidationError("observations.scenarios must be nonempty")
    observations: dict[str, dict[str, Any]] = {}
    for index, raw_observation in enumerate(root["scenarios"]):
        path = f"observations.scenarios[{index}]"
        observation = object_shape(
            raw_observation,
            path,
            (
                "scenarioID",
                "outcome",
                "claimIDs",
                "citedEvidenceIDs",
                "firstEvidenceMilliseconds",
                "completionMilliseconds",
                "latePublicationCount",
            ),
        )
        scenario_id = safe_string(observation["scenarioID"], f"{path}.scenarioID")
        if scenario_id not in fixture["scenarios"]:
            raise ApuntadorValidationError(f"{path} names an unknown scenario")
        if scenario_id in observations:
            raise ApuntadorValidationError(
                f"observations repeat scenario {scenario_id}"
            )
        outcome = enum_value(observation["outcome"], f"{path}.outcome", OUTCOMES)
        claim_ids = string_array(
            observation["claimIDs"],
            f"{path}.claimIDs",
            maximum=8,
            allowed=set(fixture["claims"]),
        )
        cited = string_array(
            observation["citedEvidenceIDs"],
            f"{path}.citedEvidenceIDs",
            maximum=12,
            allowed=set(fixture["evidence"]),
        )
        completion = number(
            observation["completionMilliseconds"],
            f"{path}.completionMilliseconds",
        )
        first_raw = observation["firstEvidenceMilliseconds"]
        first_evidence = (
            None
            if first_raw is None
            else number(first_raw, f"{path}.firstEvidenceMilliseconds")
        )
        late_publications = integer(
            observation["latePublicationCount"], f"{path}.latePublicationCount"
        )
        publishes_output = outcome in {"answered", "recovered"}
        if publishes_output:
            if not claim_ids or not cited or first_evidence is None:
                raise ApuntadorValidationError(
                    f"{path} output outcome requires claims, citations, and first evidence"
                )
            if first_evidence > completion:
                raise ApuntadorValidationError(
                    f"{path} first evidence cannot follow completion"
                )
        elif claim_ids or cited or first_evidence is not None:
            raise ApuntadorValidationError(
                f"{path} terminal non-answer must not publish content"
            )
        observations[scenario_id] = {
            "outcome": outcome,
            "claims": set(claim_ids),
            "cited": set(cited),
            "firstEvidenceMilliseconds": first_evidence,
            "completionMilliseconds": completion,
            "latePublicationCount": late_publications,
        }
    missing = sorted(set(fixture["scenarios"]) - set(observations))
    if missing:
        raise ApuntadorValidationError(
            f"observations never exercise scenario {missing[0]}"
        )
    return {"subject": subject, "scenarios": observations}


def ratio(numerator: int, denominator: int) -> float:
    return 1.0 if denominator == 0 else numerator / denominator


def percentile(values: Sequence[float], fraction: float) -> float:
    if not values:
        return 0.0
    ordered = sorted(values)
    index = math.ceil(len(ordered) * fraction) - 1
    return ordered[max(0, min(index, len(ordered) - 1))]


def evaluate(
    fixture: dict[str, Any],
    fixture_checksum: str,
    observations: dict[str, Any],
    budget: dict[str, Any],
) -> dict[str, Any]:
    expected_evidence_count = 0
    matched_evidence_count = 0
    emitted_evidence_count = 0
    expected_claim_count = 0
    matched_claim_count = 0
    emitted_claim_count = 0
    outcome_matches = 0
    hard_negative_citations = 0
    forbidden_claims = 0
    late_publications = 0
    first_evidence_times: list[float] = []
    completion_times: list[float] = []
    observed = observations["scenarios"]
    for scenario_id, scenario in fixture["scenarios"].items():
        result = observed[scenario_id]
        outcome_matches += int(result["outcome"] == scenario["expectedOutcome"])
        expected_evidence_count += len(scenario["expectedEvidence"])
        matched_evidence_count += len(result["cited"] & scenario["expectedEvidence"])
        emitted_evidence_count += len(result["cited"])
        expected_claim_count += len(scenario["expectedClaims"])
        matched_claim_count += len(result["claims"] & scenario["expectedClaims"])
        emitted_claim_count += len(result["claims"])
        hard_negative_citations += len(result["cited"] & scenario["hardNegatives"])
        forbidden_claims += len(result["claims"] & scenario["forbiddenClaims"])
        late_publications += result["latePublicationCount"]
        if result["firstEvidenceMilliseconds"] is not None:
            first_evidence_times.append(result["firstEvidenceMilliseconds"])
        completion_times.append(result["completionMilliseconds"])
    scenario_count = len(observed)
    metrics = {
        "scenarioCount": scenario_count,
        "outcomeAccuracy": ratio(outcome_matches, scenario_count),
        "citationPrecision": ratio(matched_evidence_count, emitted_evidence_count),
        "evidenceRecall": ratio(matched_evidence_count, expected_evidence_count),
        "claimPrecision": ratio(matched_claim_count, emitted_claim_count),
        "claimRecall": ratio(matched_claim_count, expected_claim_count),
        "hardNegativeCitationCount": hard_negative_citations,
        "forbiddenClaimCount": forbidden_claims,
        "latePublicationCount": late_publications,
        "maximumFirstEvidenceMilliseconds": max(first_evidence_times, default=0.0),
        "maximumCompletionMilliseconds": max(completion_times, default=0.0),
        "p95CompletionMilliseconds": percentile(completion_times, 0.95),
    }
    gates = {
        "completeScenarioSet": scenario_count == budget["expectedScenarioCount"],
        "outcomeAccuracy": metrics["outcomeAccuracy"] >= budget["minimumOutcomeAccuracy"],
        "citationPrecision": metrics["citationPrecision"] >= budget["minimumCitationPrecision"],
        "evidenceRecall": metrics["evidenceRecall"] >= budget["minimumEvidenceRecall"],
        "claimPrecision": metrics["claimPrecision"] >= budget["minimumClaimPrecision"],
        "claimRecall": metrics["claimRecall"] >= budget["minimumClaimRecall"],
        "hardNegativesExcluded": hard_negative_citations <= budget["maximumHardNegativeCitations"],
        "forbiddenClaimsExcluded": forbidden_claims <= budget["maximumForbiddenClaims"],
        "noLatePublication": late_publications <= budget["maximumLatePublicationsAfterTerminal"],
        "firstEvidenceBudget": metrics["maximumFirstEvidenceMilliseconds"] <= budget["maximumFirstEvidenceMilliseconds"],
        "completionBudget": metrics["maximumCompletionMilliseconds"] <= budget["maximumCompletionMilliseconds"],
        "p95CompletionBudget": metrics["p95CompletionMilliseconds"] <= budget["maximumP95CompletionMilliseconds"],
    }
    language_counts = Counter(
        scenario["language"] for scenario in fixture["scenarios"].values()
    )
    kind_counts = Counter(
        scenario["kind"] for scenario in fixture["scenarios"].values()
    )
    fault_counts = Counter(
        scenario["fault"] for scenario in fixture["scenarios"].values()
    )
    return {
        "schemaVersion": SCHEMA_VERSION,
        "kind": SCORECARD_KIND,
        "outcome": "pass" if all(gates.values()) else "blocked",
        "fixture": {
            "generation": fixture["generation"],
            "checksum": fixture_checksum,
            "contentSource": fixture["contentSource"],
            "sourceCount": len(fixture["sources"]),
            "scenarioCount": len(fixture["scenarios"]),
            "languageCounts": dict(sorted(language_counts.items())),
            "scenarioSourceKindCounts": dict(sorted(kind_counts.items())),
            "faultCounts": dict(sorted(fault_counts.items())),
        },
        "subject": observations["subject"],
        "metrics": metrics,
        "gates": gates,
        "proseQuality": "notEvaluated",
        "memoryAndLeakEvidence": "separateMeasuredLaneRequired",
        "physicalAndFieldEvidence": "notEvaluated",
    }


def write_json(path: Path, document: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps(document, indent=2, sort_keys=True, allow_nan=False) + "\n",
        encoding="utf-8",
    )


def main(argv: Iterable[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    verify = commands.add_parser("verify-public")
    verify.add_argument("--fixture", required=True, type=Path)
    verify.add_argument("--budget", required=True, type=Path)
    score = commands.add_parser("score")
    score.add_argument("--fixture", required=True, type=Path)
    score.add_argument("--budget", required=True, type=Path)
    score.add_argument("--observations", required=True, type=Path)
    score.add_argument("--output", type=Path)
    arguments = parser.parse_args(argv)
    try:
        fixture_document = load_json(arguments.fixture, "fixture")
        fixture = validate_fixture(fixture_document)
        fixture_checksum = file_sha256(arguments.fixture)
        budget_document = load_json(arguments.budget, "budget")
        budget = validate_budget(budget_document, fixture_checksum)
        if arguments.command == "verify-public":
            if fixture_checksum != CANONICAL_FIXTURE_SHA256:
                raise ApuntadorValidationError(
                    "public Apuntador fixture is not canonical"
                )
            if file_sha256(arguments.budget) != CANONICAL_BUDGET_SHA256:
                raise ApuntadorValidationError(
                    "public Apuntador budget is not canonical"
                )
            print(
                "Apuntador public fixture verified: "
                f"{len(fixture['sources'])} sources, "
                f"{len(fixture['scenarios'])} scenarios"
            )
            return 0
        observations = validate_observations(
            load_json(arguments.observations, "observations"),
            fixture,
            fixture_checksum,
        )
        scorecard = evaluate(fixture, fixture_checksum, observations, budget)
        if arguments.output is not None:
            write_json(arguments.output, scorecard)
        else:
            print(json.dumps(scorecard, indent=2, sort_keys=True, allow_nan=False))
        return 0 if scorecard["outcome"] == "pass" else 1
    except ApuntadorValidationError as error:
        print(f"Apuntador validation failed: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
