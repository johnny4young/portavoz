#!/usr/bin/env python3
"""Adapter-neutral, public-fixture scoring for commitment candidates."""

import argparse
import hashlib
import ipaddress
import json
import math
import os
import re
import stat
import sys
import time
import unicodedata
import urllib.error
import urllib.parse
import urllib.request
from collections import Counter
from pathlib import Path


SCHEMA_VERSION = 1
FIXTURE_KIND = "commitment-quality-fixture"
SCORECARD_KIND = "commitment-quality-scorecard"
COMPARISON_KIND = "commitment-quality-comparison"
PUBLIC_GENERATION = "public-synthetic-v1"
PUBLIC_SOURCE = "public-synthetic-only"
LANGUAGES = {"en", "es", "mixed"}
LABELS = {"commitment", "suggestion", "hypothetical", "status-report", "question"}
SAFE_ID = re.compile(r"^[a-z0-9][a-z0-9._-]{0,79}$")
SAFE_MODEL = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:/+-]{0,119}$")
ISO_DATE = re.compile(r"\b\d{4}-\d{2}-\d{2}\b")


class CommitmentQualityError(ValueError):
    """Fail-closed fixture, adapter, or scorecard error."""


def reject_duplicate_keys(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise CommitmentQualityError(f"duplicate key: {key}")
        result[key] = value
    return result


def load_json(path, label, maximum_bytes=2 * 1024 * 1024):
    path = Path(path).expanduser()
    try:
        if not path.is_file():
            raise CommitmentQualityError(f"{label} not found: {path}")
        if path.stat().st_size > maximum_bytes:
            raise CommitmentQualityError(f"{label} exceeds the size limit")
        return json.loads(
            path.read_text(encoding="utf-8"),
            object_pairs_hook=reject_duplicate_keys,
        )
    except OSError as error:
        raise CommitmentQualityError(f"{label} could not be read: {path}") from error
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise CommitmentQualityError(f"{label} is not valid UTF-8 JSON") from error


def exact_object(value, path, keys):
    if not isinstance(value, dict):
        raise CommitmentQualityError(f"{path} must be an object")
    expected = set(keys)
    if set(value) != expected:
        raise CommitmentQualityError(f"{path} must contain exactly: {', '.join(sorted(expected))}")
    return value


def safe_string(value, path, pattern=SAFE_ID):
    if not isinstance(value, str) or pattern.fullmatch(value) is None:
        raise CommitmentQualityError(f"{path} has an unsafe value")
    return value


def bounded_text(value, path, maximum=500):
    if not isinstance(value, str):
        raise CommitmentQualityError(f"{path} must be text")
    value = value.strip()
    if not value or len(value) > maximum or "\x00" in value:
        raise CommitmentQualityError(f"{path} must contain 1 to {maximum} safe characters")
    return value


def optional_text(value, path, maximum=120):
    if value is None:
        return None
    return bounded_text(value, path, maximum)


def string_list(value, path, maximum=8):
    if not isinstance(value, list) or len(value) > maximum:
        raise CommitmentQualityError(f"{path} must be a bounded array")
    result = [safe_string(item, f"{path}[{index}]") for index, item in enumerate(value)]
    if len(set(result)) != len(result):
        raise CommitmentQualityError(f"{path} contains duplicates")
    return result


def validate_fixture(document):
    exact_object(
        document,
        "fixture",
        {"schemaVersion", "kind", "generation", "contentSource", "cases"},
    )
    if document["schemaVersion"] != SCHEMA_VERSION:
        raise CommitmentQualityError("fixture schemaVersion is unsupported")
    if document["kind"] != FIXTURE_KIND:
        raise CommitmentQualityError("fixture kind is invalid")
    if document["generation"] != PUBLIC_GENERATION:
        raise CommitmentQualityError("fixture generation is not canonical")
    if document["contentSource"] != PUBLIC_SOURCE:
        raise CommitmentQualityError("fixture must contain only public synthetic material")
    cases = document["cases"]
    if not isinstance(cases, list) or len(cases) != 48:
        raise CommitmentQualityError("canonical fixture must contain exactly 48 cases")

    seen = set()
    language_counts = Counter()
    label_counts = Counter()
    for index, case in enumerate(cases):
        path = f"cases[{index}]"
        exact_object(
            case,
            path,
            {"id", "language", "label", "transcript", "actionItem", "expected"},
        )
        case_id = safe_string(case["id"], f"{path}.id")
        if case_id in seen:
            raise CommitmentQualityError(f"duplicate case id: {case_id}")
        seen.add(case_id)
        if case["language"] not in LANGUAGES:
            raise CommitmentQualityError(f"{path}.language is invalid")
        if case["label"] not in LABELS:
            raise CommitmentQualityError(f"{path}.label is invalid")
        language_counts[case["language"]] += 1
        label_counts[case["label"]] += 1

        transcript = case["transcript"]
        if not isinstance(transcript, list) or not 1 <= len(transcript) <= 4:
            raise CommitmentQualityError(f"{path}.transcript must contain 1 to 4 turns")
        turn_ids = set()
        for turn_index, turn in enumerate(transcript):
            turn_path = f"{path}.transcript[{turn_index}]"
            exact_object(turn, turn_path, {"id", "speaker", "language", "text"})
            turn_id = safe_string(turn["id"], f"{turn_path}.id")
            if turn_id in turn_ids:
                raise CommitmentQualityError(f"{path}.transcript contains duplicate ids")
            turn_ids.add(turn_id)
            bounded_text(turn["speaker"], f"{turn_path}.speaker", 80)
            if turn["language"] not in LANGUAGES:
                raise CommitmentQualityError(f"{turn_path}.language is invalid")
            bounded_text(turn["text"], f"{turn_path}.text")

        action = exact_object(
            case["actionItem"],
            f"{path}.actionItem",
            {"text", "owner", "evidenceIDs"},
        )
        bounded_text(action["text"], f"{path}.actionItem.text")
        if not isinstance(action["owner"], str) or len(action["owner"]) > 80:
            raise CommitmentQualityError(f"{path}.actionItem.owner is invalid")
        action_evidence = string_list(
            action["evidenceIDs"], f"{path}.actionItem.evidenceIDs")
        if not action_evidence or not set(action_evidence).issubset(turn_ids):
            raise CommitmentQualityError(f"{path}.actionItem evidence must reference transcript turns")

        expected = exact_object(
            case["expected"],
            f"{path}.expected",
            {"candidate", "owner", "deadline", "evidenceIDs"},
        )
        if not isinstance(expected["candidate"], bool):
            raise CommitmentQualityError(f"{path}.expected.candidate must be boolean")
        owner = optional_text(expected["owner"], f"{path}.expected.owner", 80)
        deadline = optional_text(expected["deadline"], f"{path}.expected.deadline", 40)
        expected_evidence = string_list(
            expected["evidenceIDs"], f"{path}.expected.evidenceIDs")
        should_be_candidate = case["label"] == "commitment"
        if expected["candidate"] != should_be_candidate:
            raise CommitmentQualityError(f"{path} label and candidate truth disagree")
        if expected["candidate"]:
            if not expected_evidence or not set(expected_evidence).issubset(action_evidence):
                raise CommitmentQualityError(f"{path} candidate must carry direct action evidence")
        elif owner is not None or deadline is not None or expected_evidence:
            raise CommitmentQualityError(f"{path} negative truth must not imply candidate fields")

    if language_counts != Counter({"en": 16, "es": 16, "mixed": 16}):
        raise CommitmentQualityError("fixture language distribution is invalid")
    if label_counts != Counter(
        {"commitment": 12, "suggestion": 9, "hypothetical": 9, "status-report": 9, "question": 9}
    ):
        raise CommitmentQualityError("fixture label distribution is invalid")
    return document


def fixture_digest(document):
    encoded = json.dumps(
        document,
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def folded(text):
    normalized = unicodedata.normalize("NFKD", text.casefold())
    return "".join(character for character in normalized if not unicodedata.combining(character))


def tokens(text):
    return re.findall(r"[a-z0-9]+", folded(text))


def has_pattern(text, patterns):
    return any(re.search(pattern, text) for pattern in patterns)


NEGATIVE_PATTERNS = [
    r"\b(?:should|could|maybe|perhaps|suggest|might)\b",
    r"\b(?:deberiamos|podriamos|quiza|quizas|sugiero|tal vez)\b",
    r"\bif\b|\bsi\b.*\b(?:falla|fallara|pasan|pasaran)\b",
    r"\b(?:would|prepararia|enviariamos|asumiria)\b",
    r"\b(?:already|completed|finished|was completed|is reviewing)\b",
    r"\b(?:ya|fue terminada|esta revisando|termine|envie)\b",
]
POSITIVE_PATTERNS = [
    r"\b(?:i will|we will|i['’]?ll|commit to)\b",
    r"\b(?:voy a|vamos a|me comprometo|yo me encargo)\b",
    r"\b(?:publicaremos|terminare|enviare|revisare|hare)\b",
]
STOP_WORDS = {
    "about", "after", "before", "consider", "para", "por", "report", "review",
    "the", "this", "that", "with", "will", "your", "revisar", "enviar",
}


def lexical_overlap(left, right):
    left_tokens = {token for token in tokens(left) if len(token) >= 4 and token not in STOP_WORDS}
    right_tokens = {token for token in tokens(right) if len(token) >= 4 and token not in STOP_WORDS}
    return bool(left_tokens & right_tokens)


def normalized_deadline(text):
    date = ISO_DATE.search(text)
    if date:
        return date.group(0)
    value = folded(text)
    for token, aliases in {
        "friday": ("friday", "viernes"),
        "monday": ("monday", "lunes"),
        "tomorrow": ("tomorrow", "manana"),
    }.items():
        if any(re.search(rf"\b{alias}\b", value) for alias in aliases):
            return token
    return None


def deterministic_observation(case):
    action = case["actionItem"]
    evidence_by_id = {turn["id"]: turn for turn in case["transcript"]}
    evidence = [evidence_by_id[item] for item in action["evidenceIDs"]]
    evidence_text = " ".join(turn["text"] for turn in evidence)
    normalized = folded(evidence_text)
    question = any("?" in turn["text"] or "\u00bf" in turn["text"] for turn in evidence)
    negative = question or has_pattern(normalized, NEGATIVE_PATTERNS)
    positive = has_pattern(normalized, POSITIVE_PATTERNS)
    grounded = lexical_overlap(action["text"], evidence_text)
    candidate = positive and grounded and not negative
    if not candidate:
        return observation(case["id"], False, None, None, [])

    owner = action["owner"].strip() or None
    if owner is not None:
        owner_turns = [turn for turn in evidence if turn["speaker"].casefold() == owner.casefold()]
        if not owner_turns or not has_pattern(folded(" ".join(turn["text"] for turn in owner_turns)), POSITIVE_PATTERNS):
            owner = None
    return observation(
        case["id"],
        True,
        owner,
        normalized_deadline(evidence_text),
        action["evidenceIDs"],
    )


def observation(case_id, candidate, owner, deadline, evidence_ids):
    return {
        "id": case_id,
        "candidate": candidate,
        "owner": owner,
        "deadline": deadline,
        "evidenceIDs": evidence_ids,
    }


def validate_observations(document, fixture):
    exact_object(document, "observations", {"observations"})
    values = document["observations"]
    if not isinstance(values, list) or len(values) != len(fixture["cases"]):
        raise CommitmentQualityError("adapter must return exactly one observation per case")
    expected_ids = {case["id"] for case in fixture["cases"]}
    seen = set()
    result = []
    for index, value in enumerate(values):
        path = f"observations[{index}]"
        exact_object(value, path, {"id", "candidate", "owner", "deadline", "evidenceIDs"})
        case_id = safe_string(value["id"], f"{path}.id")
        if case_id not in expected_ids or case_id in seen:
            raise CommitmentQualityError(f"{path}.id is missing, duplicate, or unknown")
        seen.add(case_id)
        if not isinstance(value["candidate"], bool):
            raise CommitmentQualityError(f"{path}.candidate must be boolean")
        owner = optional_text(value["owner"], f"{path}.owner", 80)
        deadline = optional_text(value["deadline"], f"{path}.deadline", 40)
        evidence_ids = string_list(value["evidenceIDs"], f"{path}.evidenceIDs")
        result.append(observation(case_id, value["candidate"], owner, deadline, evidence_ids))
    return result


def ratio(numerator, denominator):
    return round(numerator / denominator, 6) if denominator else None


def score(fixture, observations, adapter, model=None, elapsed_ms=None):
    observations = validate_observations({"observations": observations}, fixture)
    by_id = {item["id"]: item for item in observations}
    counters = Counter()
    language = {name: Counter() for name in sorted(LANGUAGES)}
    labels = {name: Counter() for name in sorted(LABELS)}
    details = []
    for case in fixture["cases"]:
        predicted = by_id[case["id"]]
        expected = case["expected"]
        transcript_ids = {turn["id"] for turn in case["transcript"]}
        action_ids = set(case["actionItem"]["evidenceIDs"])
        predicted_ids = set(predicted["evidenceIDs"])
        evidence_valid = bool(predicted_ids) and predicted_ids.issubset(transcript_ids & action_ids)
        admitted = predicted["candidate"] and evidence_valid
        truth = expected["candidate"]
        key = "tp" if admitted and truth else "fp" if admitted else "fn" if truth else "tn"
        counters[key] += 1
        language[case["language"]][key] += 1
        labels[case["label"]][key] += 1
        if predicted["candidate"] and not evidence_valid:
            counters["unsupported"] += 1
        if expected["owner"] is None and predicted["owner"] is not None:
            counters["ownerFalsePositive"] += 1
        if expected["deadline"] is None and predicted["deadline"] is not None:
            counters["deadlineFalsePositive"] += 1
        if expected["owner"] is not None:
            counters["ownerExpected"] += 1
            if admitted and predicted["owner"] == expected["owner"]:
                counters["ownerExact"] += 1
        if expected["deadline"] is not None:
            counters["deadlineExpected"] += 1
            if admitted and predicted["deadline"] == expected["deadline"]:
                counters["deadlineExact"] += 1
        if truth:
            counters["evidenceExpected"] += 1
            if admitted and predicted_ids == set(expected["evidenceIDs"]):
                counters["evidenceExact"] += 1
        details.append({
            "id": case["id"],
            "language": case["language"],
            "label": case["label"],
            "expected": expected,
            "observed": predicted,
            "evidenceValid": evidence_valid,
            "admittedCandidate": admitted,
        })

    positive = counters["tp"] + counters["fn"]
    negative = counters["tn"] + counters["fp"]
    predicted_positive = counters["tp"] + counters["fp"]
    precision = ratio(counters["tp"], predicted_positive)
    recall = ratio(counters["tp"], positive)
    f1 = None if precision is None or recall is None or precision + recall == 0 else round(
        2 * precision * recall / (precision + recall), 6
    )
    no_owner_truth = len(fixture["cases"]) - counters["ownerExpected"]
    no_deadline_truth = len(fixture["cases"]) - counters["deadlineExpected"]
    metrics = {
        "candidatePrecision": precision,
        "candidateRecall": recall,
        "candidateF1": f1,
        "falsePositiveRate": ratio(counters["fp"], negative),
        "unsupportedCandidateRate": ratio(counters["unsupported"], len(fixture["cases"])),
        "ownerExactRate": ratio(counters["ownerExact"], counters["ownerExpected"]),
        "ownerFalsePositiveRate": ratio(counters["ownerFalsePositive"], no_owner_truth),
        "deadlineExactRate": ratio(counters["deadlineExact"], counters["deadlineExpected"]),
        "deadlineFalsePositiveRate": ratio(counters["deadlineFalsePositive"], no_deadline_truth),
        "evidenceExactRate": ratio(counters["evidenceExact"], counters["evidenceExpected"]),
    }
    scorecard = {
        "schemaVersion": SCHEMA_VERSION,
        "kind": SCORECARD_KIND,
        "fixtureGeneration": fixture["generation"],
        "fixtureSHA256": fixture_digest(fixture),
        "adapter": adapter,
        "model": model,
        "qualityDecision": "review-required",
        "productDecision": "not-evaluated",
        "counts": {
            "caseCount": len(fixture["cases"]),
            "positiveCount": positive,
            "negativeCount": negative,
            "truePositive": counters["tp"],
            "falsePositive": counters["fp"],
            "falseNegative": counters["fn"],
            "trueNegative": counters["tn"],
            "unsupportedCandidate": counters["unsupported"],
            "ownerFalsePositive": counters["ownerFalsePositive"],
            "deadlineFalsePositive": counters["deadlineFalsePositive"],
        },
        "metrics": metrics,
        "byLanguage": grouped_metrics(language),
        "byLabel": grouped_metrics(labels),
        "elapsedMilliseconds": round(elapsed_ms, 3) if elapsed_ms is not None else None,
    }
    return scorecard, details


def grouped_metrics(groups):
    result = {}
    for name, values in groups.items():
        positives = values["tp"] + values["fn"]
        negatives = values["tn"] + values["fp"]
        result[name] = {
            "caseCount": sum(values.values()),
            "candidateRecall": ratio(values["tp"], positives),
            "falsePositiveRate": ratio(values["fp"], negatives),
        }
    return result


def loopback_endpoint(value):
    parsed = urllib.parse.urlparse(value)
    try:
        address = ipaddress.ip_address(parsed.hostname or "")
    except ValueError as error:
        raise CommitmentQualityError(
            "model endpoint must use an explicit loopback IP address"
        ) from error
    if parsed.scheme != "http" or not address.is_loopback:
        raise CommitmentQualityError("model endpoint must be an explicit loopback HTTP URL")
    if parsed.username or parsed.password or parsed.query or parsed.fragment:
        raise CommitmentQualityError("model endpoint must not contain credentials, query, or fragment")
    if not parsed.path.endswith("/chat/completions"):
        raise CommitmentQualityError("model endpoint must end in /chat/completions")
    return value


def model_prompt(cases):
    payload = [
        {
            "id": case["id"],
            "transcript": case["transcript"],
            "generatedActionItem": case["actionItem"],
        }
        for case in cases
    ]
    return (
        "Classify public synthetic meeting observations. A commitment requires an explicit "
        "future promise or assigned next step. Reject suggestions, hypotheticals, status "
        "reports, and questions even when generatedActionItem looks actionable. owner is "
        "only the exact speaker who explicitly promised; plural/group ownership is null. "
        "deadline is null, an ISO YYYY-MM-DD value, or one of friday, monday, tomorrow. "
        "evidenceIDs must contain only direct transcript ids that support both the action "
        "and its commitment status. Return JSON only as "
        '{"observations":[{"id":"case-001","candidate":true,"owner":"Mara",'
        '"deadline":"friday","evidenceIDs":["evidence-001-1"]}]}. '
        "For false candidates return null owner/deadline and an empty evidenceIDs array.\n\n"
        + json.dumps(payload, ensure_ascii=False, separators=(",", ":"))
    )


def parse_model_content(content):
    if not isinstance(content, str):
        raise CommitmentQualityError("model response content is not text")
    value = content.strip()
    if value.startswith("```"):
        value = re.sub(r"^```(?:json)?\s*", "", value)
        value = re.sub(r"\s*```$", "", value)
    try:
        return json.loads(value, object_pairs_hook=reject_duplicate_keys)
    except json.JSONDecodeError as error:
        raise CommitmentQualityError("model response is not one JSON object") from error


def call_local_model(endpoint, model, cases, timeout):
    body = json.dumps({
        "model": model,
        "temperature": 0,
        "seed": 0,
        "stream": False,
        "max_tokens": 4096,
        "response_format": {"type": "json_object"},
        "messages": [
            {"role": "system", "content": "You are a strict meeting commitment classifier."},
            {"role": "user", "content": model_prompt(cases)},
        ],
    }).encode("utf-8")
    request = urllib.request.Request(
        endpoint,
        data=body,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            raw = response.read(2 * 1024 * 1024 + 1)
    except (OSError, urllib.error.URLError) as error:
        raise CommitmentQualityError(f"local model request failed: {error}") from error
    if len(raw) > 2 * 1024 * 1024:
        raise CommitmentQualityError("local model response exceeds the size limit")
    try:
        document = json.loads(raw, object_pairs_hook=reject_duplicate_keys)
        content = document["choices"][0]["message"]["content"]
    except (UnicodeDecodeError, json.JSONDecodeError, KeyError, IndexError, TypeError) as error:
        raise CommitmentQualityError("local model response envelope is invalid") from error
    return parse_model_content(content)


def local_model_observations(fixture, endpoint, model, batch_size, timeout):
    observations = []
    cases = fixture["cases"]
    for start in range(0, len(cases), batch_size):
        batch = cases[start : start + batch_size]
        try:
            document = call_local_model(endpoint, model, batch, timeout)
        except CommitmentQualityError as error:
            raise CommitmentQualityError(
                f"model batch {batch[0]['id']}..{batch[-1]['id']} failed: {error}"
            ) from error
        partial_fixture = dict(fixture)
        partial_fixture["cases"] = batch
        observations.extend(validate_observations(document, partial_fixture))
    return validate_observations({"observations": observations}, fixture)


def write_private_json(path, document):
    path = Path(path).expanduser()
    if path.exists():
        raise CommitmentQualityError(f"output already exists: {path}")
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            json.dump(document, handle, ensure_ascii=False, indent=2, sort_keys=True)
            handle.write("\n")
    except Exception:
        try:
            path.unlink()
        except OSError:
            pass
        raise
    if stat.S_IMODE(path.stat().st_mode) != 0o600:
        raise CommitmentQualityError("private output is not owner-only")


def nonnegative_integer(value, path):
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        raise CommitmentQualityError(f"{path} must be a nonnegative integer")
    return value


def rate(value, path, optional=False):
    if value is None and optional:
        return value
    if (
        isinstance(value, bool)
        or not isinstance(value, (int, float))
        or not math.isfinite(value)
        or not 0 <= value <= 1
    ):
        raise CommitmentQualityError(f"{path} must be a finite rate from zero to one")
    return value


def validate_grouped_metrics(value, path, expected_names, case_count):
    if not isinstance(value, dict) or set(value) != expected_names:
        raise CommitmentQualityError(f"{path} groups are invalid")
    total = 0
    for name, metrics in value.items():
        exact_object(
            metrics,
            f"{path}.{name}",
            {"caseCount", "candidateRecall", "falsePositiveRate"},
        )
        total += nonnegative_integer(metrics["caseCount"], f"{path}.{name}.caseCount")
        rate(metrics["candidateRecall"], f"{path}.{name}.candidateRecall", optional=True)
        rate(metrics["falsePositiveRate"], f"{path}.{name}.falsePositiveRate", optional=True)
    if total != case_count:
        raise CommitmentQualityError(f"{path} case counts do not match the scorecard")


def numeric_metrics(scorecard):
    exact_object(
        scorecard,
        "scorecard",
        {
            "schemaVersion", "kind", "fixtureGeneration", "fixtureSHA256", "adapter",
            "model", "qualityDecision", "productDecision", "counts", "metrics",
            "byLanguage", "byLabel", "elapsedMilliseconds",
        },
    )
    if scorecard["schemaVersion"] != SCHEMA_VERSION or scorecard["kind"] != SCORECARD_KIND:
        raise CommitmentQualityError("scorecard schema is invalid")
    if scorecard["fixtureGeneration"] != PUBLIC_GENERATION:
        raise CommitmentQualityError("scorecard fixture generation is invalid")
    if not isinstance(scorecard["fixtureSHA256"], str) or re.fullmatch(
        r"[0-9a-f]{64}", scorecard["fixtureSHA256"]
    ) is None:
        raise CommitmentQualityError("scorecard fixtureSHA256 is invalid")
    safe_string(scorecard["adapter"], "scorecard.adapter")
    if scorecard["model"] is not None:
        safe_string(scorecard["model"], "scorecard.model", SAFE_MODEL)
    if scorecard["qualityDecision"] != "review-required" or scorecard["productDecision"] != "not-evaluated":
        raise CommitmentQualityError("scorecard must not declare an automatic winner")

    counts = exact_object(
        scorecard["counts"],
        "scorecard.counts",
        {
            "caseCount", "positiveCount", "negativeCount", "truePositive",
            "falsePositive", "falseNegative", "trueNegative", "unsupportedCandidate",
            "ownerFalsePositive", "deadlineFalsePositive",
        },
    )
    for key, value in counts.items():
        nonnegative_integer(value, f"scorecard.counts.{key}")
    if counts["caseCount"] != counts["positiveCount"] + counts["negativeCount"]:
        raise CommitmentQualityError("scorecard positive and negative counts are inconsistent")
    if counts["positiveCount"] != counts["truePositive"] + counts["falseNegative"]:
        raise CommitmentQualityError("scorecard positive classification counts are inconsistent")
    if counts["negativeCount"] != counts["trueNegative"] + counts["falsePositive"]:
        raise CommitmentQualityError("scorecard negative classification counts are inconsistent")
    for key in ("unsupportedCandidate", "ownerFalsePositive", "deadlineFalsePositive"):
        if counts[key] > counts["caseCount"]:
            raise CommitmentQualityError(f"scorecard {key} exceeds the case count")

    metrics = scorecard["metrics"]
    required = {
        "candidatePrecision", "candidateRecall", "candidateF1", "falsePositiveRate",
        "unsupportedCandidateRate", "ownerExactRate", "ownerFalsePositiveRate",
        "deadlineExactRate", "deadlineFalsePositiveRate", "evidenceExactRate",
    }
    if not isinstance(metrics, dict) or set(metrics) != required:
        raise CommitmentQualityError("scorecard metrics are invalid")
    for key, value in metrics.items():
        rate(value, f"scorecard.metrics.{key}", optional=True)
    validate_grouped_metrics(
        scorecard["byLanguage"], "scorecard.byLanguage", LANGUAGES, counts["caseCount"]
    )
    validate_grouped_metrics(
        scorecard["byLabel"], "scorecard.byLabel", LABELS, counts["caseCount"]
    )
    elapsed = scorecard["elapsedMilliseconds"]
    if elapsed is not None and (
        isinstance(elapsed, bool)
        or not isinstance(elapsed, (int, float))
        or not math.isfinite(elapsed)
        or elapsed < 0
    ):
        raise CommitmentQualityError("scorecard elapsedMilliseconds is invalid")
    return metrics


def compare(left, right):
    left_metrics = numeric_metrics(left)
    right_metrics = numeric_metrics(right)
    for key in ("fixtureGeneration", "fixtureSHA256"):
        if left[key] != right[key]:
            raise CommitmentQualityError("scorecards do not describe the same fixture")
    deltas = {}
    for key in sorted(left_metrics):
        left_value = left_metrics[key]
        right_value = right_metrics[key]
        deltas[key] = None if left_value is None or right_value is None else round(
            right_value - left_value, 6
        )
    return {
        "schemaVersion": SCHEMA_VERSION,
        "kind": COMPARISON_KIND,
        "fixtureGeneration": left["fixtureGeneration"],
        "fixtureSHA256": left["fixtureSHA256"],
        "leftAdapter": left["adapter"],
        "rightAdapter": right["adapter"],
        "metricDeltaRightMinusLeft": deltas,
        "winner": "not-evaluated",
        "productDecision": "not-evaluated",
    }


def parser():
    root = argparse.ArgumentParser(description=__doc__)
    commands = root.add_subparsers(dest="command", required=True)
    validate = commands.add_parser("validate", help="validate the canonical fixture")
    validate.add_argument("--fixture", required=True)

    run = commands.add_parser("run", help="score deterministic or local model observations")
    run.add_argument("--fixture", required=True)
    run.add_argument("--adapter", choices=("deterministic", "openai-compatible"), required=True)
    run.add_argument("--endpoint")
    run.add_argument("--model")
    run.add_argument("--batch-size", type=int, default=8)
    run.add_argument("--timeout", type=float, default=180)
    run.add_argument("--details-output")

    comparison = commands.add_parser("compare", help="compare two scorecards without a winner")
    comparison.add_argument("--left", required=True)
    comparison.add_argument("--right", required=True)
    return root


def main(argv=None):
    args = parser().parse_args(argv)
    if args.command == "validate":
        fixture = validate_fixture(load_json(args.fixture, "fixture"))
        print(json.dumps({
            "kind": FIXTURE_KIND,
            "generation": fixture["generation"],
            "caseCount": len(fixture["cases"]),
            "sha256": fixture_digest(fixture),
        }, sort_keys=True))
        return 0
    if args.command == "compare":
        document = compare(
            load_json(args.left, "left scorecard"),
            load_json(args.right, "right scorecard"),
        )
        print(json.dumps(document, sort_keys=True))
        return 0

    fixture = validate_fixture(load_json(args.fixture, "fixture"))
    started = time.monotonic()
    if args.adapter == "deterministic":
        if args.endpoint or args.model:
            raise CommitmentQualityError("deterministic adapter does not accept endpoint or model")
        adapter = "research-deterministic-v1"
        model = None
        observations = [deterministic_observation(case) for case in fixture["cases"]]
    else:
        if not args.endpoint or not args.model:
            raise CommitmentQualityError("local model adapter requires endpoint and model")
        endpoint = loopback_endpoint(args.endpoint)
        model = safe_string(args.model, "model", SAFE_MODEL)
        if not 1 <= args.batch_size <= 12 or not 1 <= args.timeout <= 900:
            raise CommitmentQualityError("batch-size or timeout is outside the safe range")
        adapter = "loopback-openai-compatible-v1"
        observations = local_model_observations(
            fixture, endpoint, model, args.batch_size, args.timeout
        )
    scorecard, details = score(
        fixture,
        observations,
        adapter,
        model=model,
        elapsed_ms=(time.monotonic() - started) * 1000,
    )
    if args.details_output:
        write_private_json(args.details_output, {
            "schemaVersion": SCHEMA_VERSION,
            "kind": "commitment-quality-details",
            "fixtureGeneration": fixture["generation"],
            "fixtureSHA256": fixture_digest(fixture),
            "adapter": adapter,
            "model": model,
            "cases": details,
        })
    print(json.dumps(scorecard, sort_keys=True))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except CommitmentQualityError as error:
        print(f"commitment quality error: {error}", file=sys.stderr)
        raise SystemExit(2)
