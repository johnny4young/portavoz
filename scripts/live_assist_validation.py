#!/usr/bin/env python3
"""Validate and score the public bilingual LIVE-0 assistance corpus.

Fixture text is public synthetic. Runtime observations and scorecards are
content-free: stable identities, closed outcomes, timings, and process counters.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import platform
import re
import sys
from collections import Counter
from datetime import datetime
from pathlib import Path
from typing import Any, Iterable, Sequence

SCHEMA_VERSION = 1
FIXTURE_KIND = "live-assist-validation-fixture"
BUDGET_KIND = "live-assist-validation-budget"
OBSERVATION_KIND = "live-assist-validation-observations"
SCORECARD_KIND = "live-assist-validation-scorecard"
GENERATION = "public-bilingual-v1"
CONTENT_SOURCE = "public-synthetic-only"
CANONICAL_FIXTURE_SHA256 = "287e77db9d9a277c3243c2ce3d7be37f1ada65379e8dae62bb1ed60aba466cb4"
CANONICAL_BUDGET_SHA256 = "a97350af7397db93e4556e3e1c002660585992e8dbfd1a17ecadd56bce3e3333"
SAFE_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._+-]{0,95}$")
COMMIT = re.compile(r"^[0-9a-f]{40}$")
SHA256 = re.compile(r"^[0-9a-f]{64}$")
UUID = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-5[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$")
PROFILES = {"en", "es", "codeSwitch", "noisyASR"}
DECISIONS = {"question", "nonQuestion", "abstain"}
OBSERVED_DECISIONS = {"prompt", "ignore", "abstain"}
CHANNELS = {"microphone", "system", "room"}
DOMAINS = {"questionDetection", "interview", "rollingSummary", "translation"}
FAULTS = {"cancelBeforeResult", "relaunch"}
FAULT_OUTCOMES = {"cancelBeforeResult": "cancelled", "relaunch": "recovered"}
THERMAL = ("nominal", "fair", "serious", "critical")
POWER = {"ac", "battery", "unknown"}
SOURCE_STATES = {"clean", "dirty"}


class LiveAssistValidationError(ValueError):
    pass


def reject_duplicate_keys(pairs: Sequence[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise LiveAssistValidationError(f"duplicate key: {key}")
        result[key] = value
    return result


def load_json(path: Path | str, label: str, maximum_bytes: int = 2_000_000) -> Any:
    source = Path(path)
    try:
        if not source.is_file():
            raise LiveAssistValidationError(f"{label} not found: {source}")
        if source.stat().st_size > maximum_bytes:
            raise LiveAssistValidationError(f"{label} exceeds the size limit")
        return json.loads(
            source.read_text(encoding="utf-8"),
            object_pairs_hook=reject_duplicate_keys,
        )
    except OSError as error:
        raise LiveAssistValidationError(f"{label} could not be read") from error
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise LiveAssistValidationError(f"{label} is not valid UTF-8 JSON") from error


def file_sha256(path: Path | str) -> str:
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def shape(value: Any, path: str, required: Iterable[str]) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise LiveAssistValidationError(f"{path} must be an object")
    expected = set(required)
    if set(value) != expected:
        missing = expected - set(value)
        extra = set(value) - expected
        detail = []
        if missing:
            detail.append("missing " + ", ".join(sorted(missing)))
        if extra:
            detail.append("forbidden " + ", ".join(sorted(extra)))
        raise LiveAssistValidationError(f"{path} shape differs: {'; '.join(detail)}")
    return value


def array(value: Any, path: str, minimum: int = 0, maximum: int = 512) -> list[Any]:
    if not isinstance(value, list) or not minimum <= len(value) <= maximum:
        raise LiveAssistValidationError(
            f"{path} must contain {minimum} to {maximum} values"
        )
    return value


def text(value: Any, path: str, maximum: int = 800) -> str:
    if (
        not isinstance(value, str)
        or not value
        or value != value.strip()
        or len(value) > maximum
        or "\x00" in value
    ):
        raise LiveAssistValidationError(f"{path} must be 1 to {maximum} trimmed characters")
    return value


def identifier(value: Any, path: str, pattern: re.Pattern[str] = SAFE_ID) -> str:
    if not isinstance(value, str) or pattern.fullmatch(value) is None:
        raise LiveAssistValidationError(f"{path} has an unsafe identity")
    return value


def enum(value: Any, path: str, allowed: set[str]) -> str:
    if not isinstance(value, str) or value not in allowed:
        raise LiveAssistValidationError(
            f"{path} must be one of: {', '.join(sorted(allowed))}"
        )
    return value


def integer(value: Any, path: str, minimum: int = 0, maximum: int | None = None) -> int:
    if isinstance(value, bool) or not isinstance(value, int):
        raise LiveAssistValidationError(f"{path} must be an integer")
    if value < minimum or (maximum is not None and value > maximum):
        raise LiveAssistValidationError(f"{path} is outside its accepted range")
    return value


def number(value: Any, path: str, minimum: float = 0, maximum: float | None = None) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise LiveAssistValidationError(f"{path} must be numeric")
    result = float(value)
    if not math.isfinite(result) or result < minimum or (maximum is not None and result > maximum):
        raise LiveAssistValidationError(f"{path} is outside its finite range")
    return result


def boolean(value: Any, path: str) -> bool:
    if not isinstance(value, bool):
        raise LiveAssistValidationError(f"{path} must be boolean")
    return value


def nullable(value: Any, validator, path: str):
    return None if value is None else validator(value, path)


def utc(value: Any, path: str) -> str:
    if not isinstance(value, str) or not value.endswith("Z"):
        raise LiveAssistValidationError(f"{path} must be an ISO-8601 UTC instant")
    try:
        datetime.fromisoformat(value[:-1] + "+00:00")
    except ValueError as error:
        raise LiveAssistValidationError(f"{path} must be an ISO-8601 UTC instant") from error
    return value


def unique_strings(value: Any, path: str, allowed: set[str] | None = None, maximum: int = 512) -> list[str]:
    values = [identifier(item, f"{path}[{index}]") for index, item in enumerate(array(value, path, maximum=maximum))]
    if len(values) != len(set(values)):
        raise LiveAssistValidationError(f"{path} contains duplicates")
    if allowed is not None and not set(values) <= allowed:
        raise LiveAssistValidationError(f"{path} contains an unknown identity")
    return values


def validate_segment(raw: Any, path: str) -> dict[str, Any]:
    item = shape(raw, path, (
        "id", "meetingID", "channel", "text", "language",
        "startSeconds", "endSeconds", "isFinal",
    ))
    segment_id = identifier(item["id"], f"{path}.id", UUID)
    meeting_id = identifier(item["meetingID"], f"{path}.meetingID", UUID)
    channel = enum(item["channel"], f"{path}.channel", CHANNELS)
    segment_text = text(item["text"], f"{path}.text", 2_000)
    language = enum(item["language"], f"{path}.language", {"en", "es"})
    start = number(item["startSeconds"], f"{path}.startSeconds", 0, 86_400)
    end = number(item["endSeconds"], f"{path}.endSeconds", 0, 86_400)
    if end < start:
        raise LiveAssistValidationError(f"{path} has a reversed interval")
    final = boolean(item["isFinal"], f"{path}.isFinal")
    return {
        "id": segment_id,
        "meetingID": meeting_id,
        "channel": channel,
        "text": segment_text,
        "language": language,
        "startSeconds": start,
        "endSeconds": end,
        "isFinal": final,
    }


def validate_fixture(document: Any) -> dict[str, Any]:
    root = shape(document, "fixture", (
        "schemaVersion", "kind", "generation", "contentSource", "frozenAt",
        "questionSessions", "interviewScenarios", "rollingSummaryScenarios",
        "translationScenarios", "faultScenarios",
    ))
    if integer(root["schemaVersion"], "fixture.schemaVersion") != SCHEMA_VERSION:
        raise LiveAssistValidationError("fixture.schemaVersion must be 1")
    if root["kind"] != FIXTURE_KIND or root["generation"] != GENERATION or root["contentSource"] != CONTENT_SOURCE:
        raise LiveAssistValidationError("fixture identity differs")
    utc(root["frozenAt"], "fixture.frozenAt")

    all_ids: set[str] = set()
    def admit(value: str, path: str) -> str:
        if value in all_ids:
            raise LiveAssistValidationError(f"duplicate fixture identity at {path}: {value}")
        all_ids.add(value)
        return value

    sessions: dict[str, Any] = {}
    profile_counts: Counter[str] = Counter()
    decision_counts: Counter[tuple[str, str]] = Counter()
    exposure = 0.0
    for index, raw in enumerate(array(root["questionSessions"], "fixture.questionSessions", 4, 4)):
        path = f"fixture.questionSessions[{index}]"
        item = shape(raw, path, ("id", "languageProfile", "durationSeconds", "ownerName", "events"))
        sid = admit(identifier(item["id"], f"{path}.id"), f"{path}.id")
        profile = enum(item["languageProfile"], f"{path}.languageProfile", PROFILES)
        profile_counts[profile] += 1
        duration = number(item["durationSeconds"], f"{path}.durationSeconds", 60, 14_400)
        exposure += duration
        owner = text(item["ownerName"], f"{path}.ownerName", 80)
        events: dict[str, Any] = {}
        prior_offset = -1.0
        for event_index, raw_event in enumerate(array(item["events"], f"{path}.events", 8, 8)):
            event_path = f"{path}.events[{event_index}]"
            event = shape(raw_event, event_path, ("id", "offsetSeconds", "channel", "confidence", "text", "expectedDecision"))
            eid = admit(identifier(event["id"], f"{event_path}.id", UUID), f"{event_path}.id")
            offset = number(event["offsetSeconds"], f"{event_path}.offsetSeconds", 0, duration)
            if offset <= prior_offset:
                raise LiveAssistValidationError(f"{path}.events must have increasing offsets")
            prior_offset = offset
            channel = enum(event["channel"], f"{event_path}.channel", CHANNELS)
            confidence = number(event["confidence"], f"{event_path}.confidence", 0, 1)
            body = text(event["text"], f"{event_path}.text", 600)
            expected = enum(event["expectedDecision"], f"{event_path}.expectedDecision", DECISIONS)
            decision_counts[(profile, expected)] += 1
            events[eid] = {"expectedDecision": expected, "channel": channel, "confidence": confidence, "text": body}
        sessions[sid] = {"profile": profile, "durationSeconds": duration, "ownerName": owner, "events": events}
    if profile_counts != Counter({profile: 1 for profile in PROFILES}):
        raise LiveAssistValidationError("fixture must contain each language profile exactly once")
    expected_decisions = Counter({(profile, decision): count for profile in PROFILES for decision, count in (("question", 3), ("nonQuestion", 3), ("abstain", 2))})
    if decision_counts != expected_decisions or exposure != 7_200:
        raise LiveAssistValidationError("question ground truth distribution differs")

    def scenario_segments(raw: Any, path: str) -> tuple[str, list[dict[str, Any]], set[str]]:
        scenario_id = admit(identifier(raw["id"], f"{path}.id"), f"{path}.id")
        segments = [validate_segment(item, f"{path}.segments[{i}]") for i, item in enumerate(array(raw["segments"], f"{path}.segments", 1, 64))]
        segment_ids: set[str] = set()
        for i, segment in enumerate(segments):
            admit(segment["id"], f"{path}.segments[{i}].id")
            segment_ids.add(segment["id"])
        return scenario_id, segments, segment_ids

    interviews: dict[str, Any] = {}
    for index, raw in enumerate(array(root["interviewScenarios"], "fixture.interviewScenarios", 7, 32)):
        path = f"fixture.interviewScenarios[{index}]"
        item = shape(raw, path, ("id", "segments", "expectedQuestionID", "expectedEvidenceIDs"))
        sid, segments, ids = scenario_segments(item, path)
        question_id = nullable(item["expectedQuestionID"], lambda value, item_path: identifier(value, item_path, UUID), f"{path}.expectedQuestionID")
        evidence = unique_strings(item["expectedEvidenceIDs"], f"{path}.expectedEvidenceIDs", ids)
        if question_id is not None and question_id not in ids:
            raise LiveAssistValidationError(f"{path}.expectedQuestionID is unknown")
        if question_id in evidence:
            raise LiveAssistValidationError(f"{path} question cannot be its own evidence")
        interviews[sid] = {"segments": segments, "questionID": question_id, "evidenceIDs": evidence}

    summaries: dict[str, Any] = {}
    for index, raw in enumerate(array(root["rollingSummaryScenarios"], "fixture.rollingSummaryScenarios", 5, 32)):
        path = f"fixture.rollingSummaryScenarios[{index}]"
        item = shape(raw, path, (
            "id", "language", "segments", "summarizedIDs", "maximumRows",
            "maximumCharacters", "expectedSelectedIDs", "expectedBacklog",
            "requiredFacts", "referenceSummary",
        ))
        sid, segments, ids = scenario_segments(item, path)
        language = enum(item["language"], f"{path}.language", {"en", "es"})
        summarized = unique_strings(item["summarizedIDs"], f"{path}.summarizedIDs", ids)
        maximum_rows = integer(item["maximumRows"], f"{path}.maximumRows", 1, 32)
        maximum_characters = integer(item["maximumCharacters"], f"{path}.maximumCharacters", 1, 6_000)
        selected = unique_strings(item["expectedSelectedIDs"], f"{path}.expectedSelectedIDs", ids)
        backlog = boolean(item["expectedBacklog"], f"{path}.expectedBacklog")
        facts: dict[str, Any] = {}
        for fact_index, raw_fact in enumerate(array(item["requiredFacts"], f"{path}.requiredFacts", 1, 64)):
            fact_path = f"{path}.requiredFacts[{fact_index}]"
            fact = shape(raw_fact, fact_path, ("id", "text", "sourceSegmentIDs"))
            fid = admit(identifier(fact["id"], f"{fact_path}.id"), f"{fact_path}.id")
            facts[fid] = {
                "text": text(fact["text"], f"{fact_path}.text", 600),
                "sourceIDs": unique_strings(fact["sourceSegmentIDs"], f"{fact_path}.sourceSegmentIDs", ids),
            }
        reference = text(item["referenceSummary"], f"{path}.referenceSummary", 4_000)
        summaries[sid] = {"language": language, "segments": segments, "summarizedIDs": summarized, "maximumRows": maximum_rows, "maximumCharacters": maximum_characters, "selectedIDs": selected, "backlog": backlog, "facts": facts, "referenceSummary": reference}

    translations: dict[str, Any] = {}
    for index, raw in enumerate(array(root["translationScenarios"], "fixture.translationScenarios", 6, 32)):
        path = f"fixture.translationScenarios[{index}]"
        item = shape(raw, path, ("id", "targetLanguage", "segments", "translatedSourceTexts", "unsupportedIDs", "expectedPair", "expectedPendingIDs"))
        sid, segments, ids = scenario_segments(item, path)
        target = enum(item["targetLanguage"], f"{path}.targetLanguage", {"en", "es"})
        translated_raw = item["translatedSourceTexts"]
        if not isinstance(translated_raw, dict) or not set(translated_raw) <= ids:
            raise LiveAssistValidationError(f"{path}.translatedSourceTexts contains unknown identity")
        translated = {key: text(value, f"{path}.translatedSourceTexts.{key}", 2_000) for key, value in translated_raw.items()}
        unsupported = unique_strings(item["unsupportedIDs"], f"{path}.unsupportedIDs", ids)
        pair_raw = item["expectedPair"]
        if pair_raw is None:
            pair = None
        else:
            pair_item = shape(pair_raw, f"{path}.expectedPair", ("source", "target"))
            pair = {"source": enum(pair_item["source"], f"{path}.expectedPair.source", {"en", "es"}), "target": enum(pair_item["target"], f"{path}.expectedPair.target", {"en", "es"})}
            if pair["source"] == pair["target"] or pair["target"] != target:
                raise LiveAssistValidationError(f"{path}.expectedPair is invalid")
        pending = unique_strings(item["expectedPendingIDs"], f"{path}.expectedPendingIDs", ids)
        if pair is None and pending:
            raise LiveAssistValidationError(f"{path} cannot expect pending rows without a pair")
        translations[sid] = {"target": target, "segments": segments, "translated": translated, "unsupported": unsupported, "pair": pair, "pendingIDs": pending}

    faults: dict[str, Any] = {}
    distribution: Counter[tuple[str, str]] = Counter()
    for index, raw in enumerate(array(root["faultScenarios"], "fixture.faultScenarios", 8, 8)):
        path = f"fixture.faultScenarios[{index}]"
        item = shape(raw, path, ("id", "domain", "fault", "expectedOutcome", "maximumLatePublications"))
        sid = admit(identifier(item["id"], f"{path}.id"), f"{path}.id")
        domain = enum(item["domain"], f"{path}.domain", DOMAINS)
        fault = enum(item["fault"], f"{path}.fault", FAULTS)
        outcome = enum(item["expectedOutcome"], f"{path}.expectedOutcome", set(FAULT_OUTCOMES.values()))
        if outcome != FAULT_OUTCOMES[fault]:
            raise LiveAssistValidationError(f"{path}.expectedOutcome differs")
        maximum_late = integer(item["maximumLatePublications"], f"{path}.maximumLatePublications", 0, 0)
        distribution[(domain, fault)] += 1
        faults[sid] = {"domain": domain, "fault": fault, "outcome": outcome, "maximumLate": maximum_late}
    if distribution != Counter({(domain, fault): 1 for domain in DOMAINS for fault in FAULTS}):
        raise LiveAssistValidationError("fault matrix differs")

    return {"sessions": sessions, "interviews": interviews, "summaries": summaries, "translations": translations, "faults": faults, "exposureSeconds": exposure}


def validate_budget(document: Any, fixture_checksum: str) -> dict[str, Any]:
    root = shape(document, "budget", ("schemaVersion", "kind", "fixtureGeneration", "fixtureChecksum", "quality", "latency", "resources"))
    if integer(root["schemaVersion"], "budget.schemaVersion") != 1 or root["kind"] != BUDGET_KIND or root["fixtureGeneration"] != GENERATION:
        raise LiveAssistValidationError("budget identity differs")
    if identifier(root["fixtureChecksum"], "budget.fixtureChecksum", SHA256) != fixture_checksum:
        raise LiveAssistValidationError("budget.fixtureChecksum is stale")
    quality = shape(root["quality"], "budget.quality", ("minimumPrecision", "minimumRecall", "maximumFalsePromptsPerHour", "minimumAbstentionAccuracy", "minimumInterviewExactAccuracy", "minimumSummaryPolicyExactAccuracy", "minimumTranslationPolicyExactAccuracy", "minimumFaultOutcomeAccuracy", "maximumLatePublications"))
    latency = shape(root["latency"], "budget.latency", ("maximumFirstResultMilliseconds", "maximumSteadyStateP95Milliseconds"))
    resources = shape(root["resources"], "budget.resources", ("maximumFootprintGrowthBytes", "maximumThermalState", "energyPolicy"))
    return {
        "quality": {
            "precision": number(quality["minimumPrecision"], "budget.quality.minimumPrecision", 0, 1),
            "recall": number(quality["minimumRecall"], "budget.quality.minimumRecall", 0, 1),
            "falsePromptsPerHour": number(quality["maximumFalsePromptsPerHour"], "budget.quality.maximumFalsePromptsPerHour", 0, 100),
            "abstention": number(quality["minimumAbstentionAccuracy"], "budget.quality.minimumAbstentionAccuracy", 0, 1),
            "interview": number(quality["minimumInterviewExactAccuracy"], "budget.quality.minimumInterviewExactAccuracy", 0, 1),
            "summary": number(quality["minimumSummaryPolicyExactAccuracy"], "budget.quality.minimumSummaryPolicyExactAccuracy", 0, 1),
            "translation": number(quality["minimumTranslationPolicyExactAccuracy"], "budget.quality.minimumTranslationPolicyExactAccuracy", 0, 1),
            "fault": number(quality["minimumFaultOutcomeAccuracy"], "budget.quality.minimumFaultOutcomeAccuracy", 0, 1),
            "late": integer(quality["maximumLatePublications"], "budget.quality.maximumLatePublications", 0, 0),
        },
        "latency": {
            "first": {key: number(value, f"budget.latency.maximumFirstResultMilliseconds.{key}", 0.001, 60_000) for key, value in shape(latency["maximumFirstResultMilliseconds"], "budget.latency.maximumFirstResultMilliseconds", DOMAINS).items()},
            "steady": {key: number(value, f"budget.latency.maximumSteadyStateP95Milliseconds.{key}", 0.001, 60_000) for key, value in shape(latency["maximumSteadyStateP95Milliseconds"], "budget.latency.maximumSteadyStateP95Milliseconds", DOMAINS).items()},
        },
        "resources": {
            "growth": integer(resources["maximumFootprintGrowthBytes"], "budget.resources.maximumFootprintGrowthBytes", 0, 2**40),
            "thermal": enum(resources["maximumThermalState"], "budget.resources.maximumThermalState", set(THERMAL)),
            "energyPolicy": enum(resources["energyPolicy"], "budget.resources.energyPolicy", {"measure-only"}),
        },
    }


def validate_observations(document: Any, fixture: dict[str, Any], fixture_checksum: str) -> dict[str, Any]:
    root = shape(document, "observations", ("schemaVersion", "kind", "fixtureGeneration", "fixtureChecksum", "adapter", "run", "questionEvents", "interviewScenarios", "rollingSummaryScenarios", "translationScenarios", "faultScenarios", "timings", "resources"))
    if integer(root["schemaVersion"], "observations.schemaVersion") != 1 or root["kind"] != OBSERVATION_KIND or root["fixtureGeneration"] != GENERATION or root["fixtureChecksum"] != fixture_checksum:
        raise LiveAssistValidationError("observations identity differs")
    adapter = shape(root["adapter"], "observations.adapter", ("id", "version", "class", "installedModel"))
    adapter_value = {
        "id": identifier(adapter["id"], "observations.adapter.id"),
        "version": identifier(adapter["version"], "observations.adapter.version"),
        "class": enum(adapter["class"], "observations.adapter.class", {"released-prefilter", "installed-model"}),
        "installedModel": boolean(adapter["installedModel"], "observations.adapter.installedModel"),
    }
    if (adapter_value["class"] == "installed-model") != adapter_value["installedModel"]:
        raise LiveAssistValidationError("observations adapter model identity differs")
    run = shape(root["run"], "observations.run", ("commit", "build", "platform", "osVersion", "architecture", "sourceState"))
    run_value = {
        "commit": identifier(run["commit"], "observations.run.commit", COMMIT),
        "build": identifier(run["build"], "observations.run.build"),
        "platform": enum(run["platform"], "observations.run.platform", {"macos"}),
        "osVersion": identifier(run["osVersion"], "observations.run.osVersion"),
        "architecture": identifier(run["architecture"], "observations.run.architecture"),
        "sourceState": enum(run["sourceState"], "observations.run.sourceState", SOURCE_STATES),
    }

    expected_events = {event_id for session in fixture["sessions"].values() for event_id in session["events"]}
    question: dict[str, str] = {}
    for index, raw in enumerate(array(root["questionEvents"], "observations.questionEvents", len(expected_events), len(expected_events))):
        path = f"observations.questionEvents[{index}]"
        item = shape(raw, path, ("eventID", "decision"))
        eid = identifier(item["eventID"], f"{path}.eventID", UUID)
        if eid in question or eid not in expected_events:
            raise LiveAssistValidationError(f"{path}.eventID is duplicate or unknown")
        question[eid] = enum(item["decision"], f"{path}.decision", OBSERVED_DECISIONS)
    if set(question) != expected_events:
        raise LiveAssistValidationError("observations.questionEvents is incomplete")

    def exact_scenarios(raw_rows: Any, label: str, expected: set[str], required: tuple[str, ...], parse):
        result = {}
        for index, raw in enumerate(array(raw_rows, label, len(expected), len(expected))):
            path = f"{label}[{index}]"
            item = shape(raw, path, required)
            sid = identifier(item["scenarioID"], f"{path}.scenarioID")
            if sid in result or sid not in expected:
                raise LiveAssistValidationError(f"{path}.scenarioID is duplicate or unknown")
            result[sid] = parse(item, path)
        if set(result) != expected:
            raise LiveAssistValidationError(f"{label} is incomplete")
        return result

    interviews = exact_scenarios(root["interviewScenarios"], "observations.interviewScenarios", set(fixture["interviews"]), ("scenarioID", "questionID", "evidenceIDs"), lambda item, path: {
        "questionID": nullable(item["questionID"], lambda value, p: identifier(value, p, UUID), f"{path}.questionID"),
        "evidenceIDs": unique_strings(item["evidenceIDs"], f"{path}.evidenceIDs"),
    })
    summaries = exact_scenarios(root["rollingSummaryScenarios"], "observations.rollingSummaryScenarios", set(fixture["summaries"]), ("scenarioID", "selectedIDs", "hasBacklog"), lambda item, path: {
        "selectedIDs": unique_strings(item["selectedIDs"], f"{path}.selectedIDs"),
        "hasBacklog": boolean(item["hasBacklog"], f"{path}.hasBacklog"),
    })
    translations = exact_scenarios(root["translationScenarios"], "observations.translationScenarios", set(fixture["translations"]), ("scenarioID", "pair", "pendingIDs"), lambda item, path: {
        "pair": None if item["pair"] is None else {key: enum(value, f"{path}.pair.{key}", {"en", "es"}) for key, value in shape(item["pair"], f"{path}.pair", ("source", "target")).items()},
        "pendingIDs": unique_strings(item["pendingIDs"], f"{path}.pendingIDs"),
    })
    faults = exact_scenarios(root["faultScenarios"], "observations.faultScenarios", set(fixture["faults"]), ("scenarioID", "outcome", "latePublicationCount"), lambda item, path: {
        "outcome": enum(item["outcome"], f"{path}.outcome", set(FAULT_OUTCOMES.values())),
        "late": integer(item["latePublicationCount"], f"{path}.latePublicationCount", 0, 1_000),
    })

    timing_root = shape(root["timings"], "observations.timings", DOMAINS)
    timings: dict[str, Any] = {}
    for domain, raw in timing_root.items():
        item = shape(raw, f"observations.timings.{domain}", ("firstResultMilliseconds", "steadyStateMilliseconds"))
        samples = [number(value, f"observations.timings.{domain}.steadyStateMilliseconds[{index}]", 0, 60_000) for index, value in enumerate(array(item["steadyStateMilliseconds"], f"observations.timings.{domain}.steadyStateMilliseconds", 5, 512))]
        timings[domain] = {"first": number(item["firstResultMilliseconds"], f"observations.timings.{domain}.firstResultMilliseconds", 0, 60_000), "samples": samples}

    resource = shape(root["resources"], "observations.resources", ("iterations", "wallDurationMilliseconds", "cpuTimeMilliseconds", "initialPhysicalFootprintBytes", "finalPhysicalFootprintBytes", "peakPhysicalFootprintBytes", "energyNanojoules", "maximumThermalState", "powerSource", "lowPowerModeEnabled"))
    resources = {
        "iterations": integer(resource["iterations"], "observations.resources.iterations", 5, 100),
        "wall": number(resource["wallDurationMilliseconds"], "observations.resources.wallDurationMilliseconds", 0),
        "cpu": number(resource["cpuTimeMilliseconds"], "observations.resources.cpuTimeMilliseconds", 0),
        "initial": integer(resource["initialPhysicalFootprintBytes"], "observations.resources.initialPhysicalFootprintBytes", 1),
        "final": integer(resource["finalPhysicalFootprintBytes"], "observations.resources.finalPhysicalFootprintBytes", 1),
        "peak": integer(resource["peakPhysicalFootprintBytes"], "observations.resources.peakPhysicalFootprintBytes", 1),
        "energy": integer(resource["energyNanojoules"], "observations.resources.energyNanojoules", 0),
        "thermal": enum(resource["maximumThermalState"], "observations.resources.maximumThermalState", set(THERMAL)),
        "power": enum(resource["powerSource"], "observations.resources.powerSource", POWER),
        "lowPower": boolean(resource["lowPowerModeEnabled"], "observations.resources.lowPowerModeEnabled"),
    }
    if resources["peak"] < max(resources["initial"], resources["final"]):
        raise LiveAssistValidationError("observations.resources peak is inconsistent")
    for domain, timing in timings.items():
        if len(timing["samples"]) != resources["iterations"]:
            raise LiveAssistValidationError(
                f"observations.timings.{domain} sample count differs from iterations"
            )
    return {"adapter": adapter_value, "run": run_value, "question": question, "interviews": interviews, "summaries": summaries, "translations": translations, "faults": faults, "timings": timings, "resources": resources}


def ratio(numerator: int, denominator: int) -> float:
    return 1.0 if denominator == 0 else numerator / denominator


def nearest_rank(values: Sequence[float], percentile: float) -> float:
    ordered = sorted(values)
    return ordered[max(0, math.ceil(percentile * len(ordered)) - 1)]


def evaluate(fixture: dict[str, Any], checksum: str, observations: dict[str, Any], budget: dict[str, Any]) -> dict[str, Any]:
    expected_by_event = {event_id: event["expectedDecision"] for session in fixture["sessions"].values() for event_id, event in session["events"].items()}
    true_positive = sum(expected == "question" and observations["question"][event_id] == "prompt" for event_id, expected in expected_by_event.items())
    false_positive = sum(expected != "question" and observations["question"][event_id] == "prompt" for event_id, expected in expected_by_event.items())
    false_negative = sum(expected == "question" and observations["question"][event_id] != "prompt" for event_id, expected in expected_by_event.items())
    abstentions = sum(expected == "abstain" for expected in expected_by_event.values())
    correct_abstentions = sum(expected == "abstain" and observations["question"][event_id] == "abstain" for event_id, expected in expected_by_event.items())
    precision = ratio(true_positive, true_positive + false_positive)
    recall = ratio(true_positive, true_positive + false_negative)
    abstention = ratio(correct_abstentions, abstentions)
    false_per_hour = false_positive / (fixture["exposureSeconds"] / 3_600)

    interview_correct = sum(
        observations["interviews"][sid]["questionID"] == expected["questionID"]
        and observations["interviews"][sid]["evidenceIDs"] == expected["evidenceIDs"]
        for sid, expected in fixture["interviews"].items()
    )
    summary_correct = sum(
        observations["summaries"][sid]["selectedIDs"] == expected["selectedIDs"]
        and observations["summaries"][sid]["hasBacklog"] == expected["backlog"]
        for sid, expected in fixture["summaries"].items()
    )
    translation_correct = sum(
        observations["translations"][sid]["pair"] == expected["pair"]
        and observations["translations"][sid]["pendingIDs"] == expected["pendingIDs"]
        for sid, expected in fixture["translations"].items()
    )
    fault_correct = sum(observations["faults"][sid]["outcome"] == expected["outcome"] for sid, expected in fixture["faults"].items())
    late = sum(item["late"] for item in observations["faults"].values())
    metrics = {
        "questionPrecision": round(precision, 6),
        "questionRecall": round(recall, 6),
        "falsePromptsPerHour": round(false_per_hour, 6),
        "abstentionAccuracy": round(abstention, 6),
        "interviewExactAccuracy": round(ratio(interview_correct, len(fixture["interviews"])), 6),
        "summaryPolicyExactAccuracy": round(ratio(summary_correct, len(fixture["summaries"])), 6),
        "translationPolicyExactAccuracy": round(ratio(translation_correct, len(fixture["translations"])), 6),
        "faultOutcomeAccuracy": round(ratio(fault_correct, len(fixture["faults"])), 6),
        "latePublicationCount": late,
        "timing": {domain: {"firstResultMilliseconds": round(value["first"], 6), "steadyStateP50Milliseconds": round(nearest_rank(value["samples"], .5), 6), "steadyStateP95Milliseconds": round(nearest_rank(value["samples"], .95), 6), "sampleCount": len(value["samples"])} for domain, value in observations["timings"].items()},
        "resources": {
            "iterations": observations["resources"]["iterations"],
            "wallDurationMilliseconds": round(observations["resources"]["wall"], 6),
            "cpuTimeMilliseconds": round(observations["resources"]["cpu"], 6),
            "initialPhysicalFootprintBytes": observations["resources"]["initial"],
            "finalPhysicalFootprintBytes": observations["resources"]["final"],
            "peakPhysicalFootprintBytes": observations["resources"]["peak"],
            "footprintGrowthBytes": max(0, observations["resources"]["final"] - observations["resources"]["initial"]),
            "energyNanojoules": observations["resources"]["energy"],
            "maximumThermalState": observations["resources"]["thermal"],
            "powerSource": observations["resources"]["power"],
            "lowPowerModeEnabled": observations["resources"]["lowPower"],
        },
    }
    quality = budget["quality"]
    gates = {
        "questionPrecision": precision >= quality["precision"],
        "questionRecall": recall >= quality["recall"],
        "falsePromptsPerHour": false_per_hour <= quality["falsePromptsPerHour"],
        "abstentionAccuracy": abstention >= quality["abstention"],
        "interviewExactAccuracy": metrics["interviewExactAccuracy"] >= quality["interview"],
        "summaryPolicyExactAccuracy": metrics["summaryPolicyExactAccuracy"] >= quality["summary"],
        "translationPolicyExactAccuracy": metrics["translationPolicyExactAccuracy"] >= quality["translation"],
        "faultOutcomeAccuracy": metrics["faultOutcomeAccuracy"] >= quality["fault"],
        "noLatePublication": late <= quality["late"],
    }
    for domain in DOMAINS:
        gates[f"{domain}FirstResultLatency"] = observations["timings"][domain]["first"] <= budget["latency"]["first"][domain]
        gates[f"{domain}SteadyStateLatency"] = nearest_rank(observations["timings"][domain]["samples"], .95) <= budget["latency"]["steady"][domain]
    maximum_thermal_rank = THERMAL.index(budget["resources"]["thermal"])
    gates["footprintGrowth"] = metrics["resources"]["footprintGrowthBytes"] <= budget["resources"]["growth"]
    gates["thermalState"] = THERMAL.index(observations["resources"]["thermal"]) <= maximum_thermal_rank
    target = "pass" if all(gates.values()) else "belowTarget"
    authority = (
        "controlled-local"
        if observations["run"]["sourceState"] == "clean"
        and observations["resources"]["thermal"] == "nominal"
        and observations["resources"]["power"] == "ac"
        and not observations["resources"]["lowPower"]
        else "informational"
    )
    return {
        "schemaVersion": 1,
        "kind": SCORECARD_KIND,
        "fixture": {"generation": GENERATION, "sha256": checksum, "questionEventCount": len(expected_by_event), "exposureSeconds": fixture["exposureSeconds"], "interviewScenarioCount": len(fixture["interviews"]), "summaryScenarioCount": len(fixture["summaries"]), "translationScenarioCount": len(fixture["translations"]), "faultScenarioCount": len(fixture["faults"])},
        "adapter": observations["adapter"],
        "run": observations["run"],
        "measurementStatus": "complete",
        "servingCandidateStatus": target,
        "authority": authority,
        "gates": gates,
        "metrics": metrics,
        "energyBudget": "measureOnly",
        "summaryContentQuality": "separateInstalledModelLaneRequired",
        "translationContentQuality": "separateInstalledModelLaneRequired",
        "fieldEvidence": "notEvaluated",
    }


def write_json(path: Path, document: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    path.parent.chmod(0o700)
    if path.exists():
        raise LiveAssistValidationError(f"output already exists: {path}")
    encoded = (json.dumps(document, ensure_ascii=False, sort_keys=True, indent=2) + "\n").encode()
    temporary = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    try:
        descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(descriptor, "wb") as output:
            output.write(encoded)
            output.flush()
            os.fsync(output.fileno())
        try:
            os.link(temporary, path)
        except FileExistsError as error:
            raise LiveAssistValidationError(
                f"output already exists: {path}"
            ) from error
        directory = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass


def parse(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    verify = sub.add_parser("verify-public")
    verify.add_argument("--fixture", type=Path, required=True)
    verify.add_argument("--budget", type=Path, required=True)
    score = sub.add_parser("score")
    score.add_argument("--fixture", type=Path, required=True)
    score.add_argument("--budget", type=Path, required=True)
    score.add_argument("--observations", type=Path, required=True)
    score.add_argument("--output", type=Path, required=True)
    score.add_argument("--require-targets", action="store_true")
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    arguments = parse(argv)
    try:
        fixture_checksum = file_sha256(arguments.fixture)
        fixture = validate_fixture(load_json(arguments.fixture, "fixture"))
        budget = validate_budget(load_json(arguments.budget, "budget"), fixture_checksum)
        if arguments.command == "verify-public":
            if fixture_checksum != CANONICAL_FIXTURE_SHA256:
                raise LiveAssistValidationError("canonical fixture checksum differs")
            budget_checksum = file_sha256(arguments.budget)
            if CANONICAL_BUDGET_SHA256 != "TO_BE_FILLED" and budget_checksum != CANONICAL_BUDGET_SHA256:
                raise LiveAssistValidationError("canonical budget checksum differs")
            print(json.dumps({"kind": FIXTURE_KIND, "generation": GENERATION, "sha256": fixture_checksum, "questionEvents": sum(len(item["events"]) for item in fixture["sessions"].values()), "interviews": len(fixture["interviews"]), "summaries": len(fixture["summaries"]), "translations": len(fixture["translations"]), "faults": len(fixture["faults"])}, sort_keys=True))
            return 0
        observations = validate_observations(load_json(arguments.observations, "observations"), fixture, fixture_checksum)
        scorecard = evaluate(fixture, fixture_checksum, observations, budget)
        write_json(arguments.output, scorecard)
        print(f"{scorecard['measurementStatus']} / {scorecard['servingCandidateStatus']} -> {arguments.output}")
        return int(arguments.require_targets and scorecard["servingCandidateStatus"] != "pass")
    except LiveAssistValidationError as error:
        print(f"live-assist-validation: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
