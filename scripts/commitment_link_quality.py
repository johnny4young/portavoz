#!/usr/bin/env python3
"""Public, adapter-neutral quality authority for commitment-link suggestions."""

import argparse
import hashlib
import json
import math
import os
import re
import stat
import subprocess
import sys
from collections import Counter
from pathlib import Path


SCHEMA_VERSION = 1
FIXTURE_KIND = "commitment-link-quality-fixture"
PRIVATE_FIXTURE_KIND = "commitment-link-private-quality-fixture"
OBSERVATION_KIND = "commitment-link-quality-observations"
SIMILARITY_OBSERVATION_KIND = "commitment-link-similarity-observations"
POLICY_REPLAY_KIND = "commitment-link-similarity-policy-replay"
SCORECARD_KIND = "commitment-link-quality-scorecard"
POLICY_SWEEP_GENERATION = "observed-equivalence-classes-v1"
POLICY_RULE = "best-matched-evidence-similarity-at-least"
PUBLIC_GENERATION = "public-synthetic-v1"
PUBLIC_SOURCE = "public-synthetic-only"
PRIVATE_SOURCE = "private-anonymized-local"
PRIVATE_ANONYMIZATION_POLICY = "owner-reviewed-redaction-v1"
PRIVATE_REVIEW_STATUS = "owner-reviewed"
PUBLIC_CORPUS_KIND = "commitment-link-quality-corpus"
PUBLIC_CORPUS_PATH = (
    Path(__file__).resolve().parents[1]
    / "Fixtures"
    / "CommitmentLinkQuality"
    / "public-corpus-v1.json"
)
LANGUAGES = ("en", "es", "mixed")
CLASSES = (
    "continuation",
    "ambiguous",
    "self-continuation",
    "wrong-person",
    "no-overlap",
    "same-meeting",
    "inactive-target",
    "dismissed-target",
    "unknown-owner",
)
SAFE_ID = re.compile(r"^[a-z0-9][a-z0-9._-]{0,95}$")
SAFE_ADAPTER = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:/+-]{0,119}$")
SAFE_BUILD = re.compile(r"^[A-Za-z0-9][A-Za-z0-9.+_-]{0,79}$")
FULL_COMMIT = re.compile(r"^[0-9a-f]{40}$")
SHA256 = re.compile(r"^[0-9a-f]{64}$")
ASSIGNEE_KINDS = {"person", "me", "unassigned"}
TARGET_STATUSES = {"confirmed", "done", "dismissed"}
MAXIMUM_CASES = 100
MAXIMUM_TARGETS = 200
MAXIMUM_RELATED_ROWS = 20
MAXIMUM_SEMANTIC_HITS = 20
MAXIMUM_SUGGESTIONS = 3
REPOSITORY_ROOT = Path(__file__).resolve().parents[1]
PRIVATE_TEXT_PATTERNS = (
    ("email address", re.compile(r"\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b", re.I)),
    ("URL", re.compile(r"(?:https?://|\bwww\.)", re.I)),
    ("filesystem path", re.compile(r"(?:/Users/|/home/|[A-Z]:\\)", re.I)),
    ("UUID", re.compile(
        r"\b[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-"
        r"[89ab][0-9a-f]{3}-[0-9a-f]{12}\b",
        re.I,
    )),
    ("phone-like number", re.compile(r"(?<!\w)(?:\+?\d[\s().-]*){8,}(?!\w)")),
)


class CommitmentLinkQualityError(ValueError):
    """Fail-closed fixture, observation, or scorecard error."""


def reject_duplicate_keys(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise CommitmentLinkQualityError(f"duplicate key: {key}")
        result[key] = value
    return result


def load_json(path, label, maximum_bytes=4 * 1024 * 1024):
    path = Path(path).expanduser()
    try:
        if not path.is_file():
            raise CommitmentLinkQualityError(f"{label} not found: {path}")
        if path.stat().st_size > maximum_bytes:
            raise CommitmentLinkQualityError(f"{label} exceeds the size limit")
        return json.loads(
            path.read_text(encoding="utf-8"),
            object_pairs_hook=reject_duplicate_keys,
        )
    except OSError as error:
        raise CommitmentLinkQualityError(f"{label} could not be read: {path}") from error
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise CommitmentLinkQualityError(f"{label} is not valid UTF-8 JSON") from error


def exact_object(value, path, keys):
    if not isinstance(value, dict):
        raise CommitmentLinkQualityError(f"{path} must be an object")
    expected = set(keys)
    if set(value) != expected:
        raise CommitmentLinkQualityError(
            f"{path} must contain exactly: {', '.join(sorted(expected))}"
        )
    return value


def safe_id(value, path):
    if not isinstance(value, str) or SAFE_ID.fullmatch(value) is None:
        raise CommitmentLinkQualityError(f"{path} has an unsafe value")
    return value


def bounded_text(value, path, maximum=500):
    if not isinstance(value, str):
        raise CommitmentLinkQualityError(f"{path} must be text")
    if value != value.strip() or not value or len(value) > maximum or "\x00" in value:
        raise CommitmentLinkQualityError(
            f"{path} must contain 1 to {maximum} trimmed safe characters"
        )
    return value


def load_public_corpus(path=PUBLIC_CORPUS_PATH):
    corpus = load_json(path, "public corpus", maximum_bytes=128 * 1024)
    exact_object(
        corpus,
        "public corpus",
        {"schemaVersion", "kind", "vocabularies", "templates"},
    )
    if corpus["schemaVersion"] != SCHEMA_VERSION:
        raise CommitmentLinkQualityError("public corpus schemaVersion is unsupported")
    if corpus["kind"] != PUBLIC_CORPUS_KIND:
        raise CommitmentLinkQualityError("public corpus kind is invalid")
    if set(corpus["vocabularies"]) != set(LANGUAGES):
        raise CommitmentLinkQualityError("public corpus languages are incomplete")
    for language in LANGUAGES:
        vocabulary = corpus["vocabularies"][language]
        if not isinstance(vocabulary, list) or len(vocabulary) != 12:
            raise CommitmentLinkQualityError(
                f"public corpus vocabulary {language} must contain exactly 12 rows"
            )
        for index, row in enumerate(vocabulary):
            exact_object(
                row,
                f"public corpus vocabularies.{language}[{index}]",
                {"topic", "actionText", "historyText"},
            )
            for key, value in row.items():
                bounded_text(
                    value,
                    f"public corpus vocabularies.{language}[{index}].{key}",
                )
    expected_templates = {
        "noOverlapEvidence",
        "repeatedCommitmentEvidence",
        "ambiguousTitle",
        "ambiguousHistoryReplacement",
        "distractorTitle",
        "distractorEvidence",
    }
    if set(corpus["templates"]) != expected_templates:
        raise CommitmentLinkQualityError("public corpus templates are incomplete")
    for template_name, translations in corpus["templates"].items():
        if not isinstance(translations, dict) or set(translations) != set(LANGUAGES):
            raise CommitmentLinkQualityError(
                f"public corpus template {template_name} languages are incomplete"
            )
        for language, value in translations.items():
            bounded_text(value, f"public corpus templates.{template_name}.{language}")
    return corpus


def bounded_ids(value, path, maximum, allow_empty=True):
    if not isinstance(value, list) or len(value) > maximum:
        raise CommitmentLinkQualityError(f"{path} must be a bounded array")
    result = [safe_id(item, f"{path}[{index}]") for index, item in enumerate(value)]
    if not allow_empty and not result:
        raise CommitmentLinkQualityError(f"{path} must not be empty")
    if len(set(result)) != len(result):
        raise CommitmentLinkQualityError(f"{path} contains duplicates")
    return result


def positive_integer(value, path, maximum=None):
    if isinstance(value, bool) or not isinstance(value, int) or value < 1:
        raise CommitmentLinkQualityError(f"{path} must be a positive integer")
    if maximum is not None and value > maximum:
        raise CommitmentLinkQualityError(f"{path} exceeds its limit")
    return value


def validate_assignee(value, path):
    exact_object(value, path, {"kind", "id"})
    if value["kind"] not in ASSIGNEE_KINDS:
        raise CommitmentLinkQualityError(f"{path}.kind is invalid")
    if value["kind"] == "person":
        safe_id(value["id"], f"{path}.id")
    elif value["id"] is not None:
        raise CommitmentLinkQualityError(f"{path}.id must be null for {value['kind']}")
    return value


def assignee_key(value):
    return (value["kind"], value["id"])


def validate_fixture(document):
    exact_object(
        document,
        "fixture",
        {"schemaVersion", "kind", "generation", "contentSource", "cases"},
    )
    if document["schemaVersion"] != SCHEMA_VERSION:
        raise CommitmentLinkQualityError("fixture schemaVersion is unsupported")
    if document["kind"] != FIXTURE_KIND:
        raise CommitmentLinkQualityError("fixture kind is invalid")
    if document["generation"] != PUBLIC_GENERATION:
        raise CommitmentLinkQualityError("fixture generation is not canonical")
    if document["contentSource"] != PUBLIC_SOURCE:
        raise CommitmentLinkQualityError("fixture must contain only public synthetic material")
    cases = document["cases"]
    if not isinstance(cases, list) or len(cases) != 36 or len(cases) > MAXIMUM_CASES:
        raise CommitmentLinkQualityError("canonical fixture must contain exactly 36 cases")

    case_ids = set()
    language_counts = Counter()
    class_counts = Counter()
    linkable_count = 0
    abstention_count = 0
    for case_index, case in enumerate(cases):
        path = f"cases[{case_index}]"
        exact_object(
            case,
            path,
            {"id", "language", "class", "candidate", "targets", "expected"},
        )
        case_id = safe_id(case["id"], f"{path}.id")
        if case_id in case_ids:
            raise CommitmentLinkQualityError(f"duplicate case id: {case_id}")
        case_ids.add(case_id)
        if case["language"] not in LANGUAGES:
            raise CommitmentLinkQualityError(f"{path}.language is invalid")
        if case["class"] not in CLASSES:
            raise CommitmentLinkQualityError(f"{path}.class is invalid")
        language_counts[case["language"]] += 1
        class_counts[case["class"]] += 1

        candidate = exact_object(
            case["candidate"],
            f"{path}.candidate",
            {"sourceMeetingID", "actionItemID", "language", "text", "assignee"},
        )
        safe_id(candidate["sourceMeetingID"], f"{path}.candidate.sourceMeetingID")
        safe_id(candidate["actionItemID"], f"{path}.candidate.actionItemID")
        if candidate["language"] not in LANGUAGES:
            raise CommitmentLinkQualityError(f"{path}.candidate.language is invalid")
        bounded_text(candidate["text"], f"{path}.candidate.text")
        validate_assignee(candidate["assignee"], f"{path}.candidate.assignee")

        targets = case["targets"]
        if not isinstance(targets, list) or not 1 <= len(targets) <= MAXIMUM_TARGETS:
            raise CommitmentLinkQualityError(f"{path}.targets must contain 1 to 200 targets")
        target_ids = set()
        evidence_ids = set()
        target_by_id = {}
        for target_index, target in enumerate(targets):
            target_path = f"{path}.targets[{target_index}]"
            exact_object(
                target,
                target_path,
                {"id", "title", "status", "assignee", "sourceMeetingIDs", "evidence"},
            )
            target_id = safe_id(target["id"], f"{target_path}.id")
            if target_id in target_ids:
                raise CommitmentLinkQualityError(f"{path}.targets contains duplicate ids")
            target_ids.add(target_id)
            target_by_id[target_id] = target
            bounded_text(target["title"], f"{target_path}.title")
            if target["status"] not in TARGET_STATUSES:
                raise CommitmentLinkQualityError(f"{target_path}.status is invalid")
            validate_assignee(target["assignee"], f"{target_path}.assignee")
            meetings = bounded_ids(
                target["sourceMeetingIDs"],
                f"{target_path}.sourceMeetingIDs",
                MAXIMUM_RELATED_ROWS,
                allow_empty=False,
            )
            evidence = target["evidence"]
            if not isinstance(evidence, list) or not 1 <= len(evidence) <= MAXIMUM_RELATED_ROWS:
                raise CommitmentLinkQualityError(
                    f"{target_path}.evidence must contain 1 to 20 rows"
                )
            for evidence_index, row in enumerate(evidence):
                row_path = f"{target_path}.evidence[{evidence_index}]"
                exact_object(row, row_path, {"id", "meetingID", "language", "text"})
                row_id = safe_id(row["id"], f"{row_path}.id")
                if row_id in evidence_ids:
                    raise CommitmentLinkQualityError(
                        f"{path}.targets contains duplicate evidence ids"
                    )
                evidence_ids.add(row_id)
                if safe_id(row["meetingID"], f"{row_path}.meetingID") not in meetings:
                    raise CommitmentLinkQualityError(
                        f"{row_path}.meetingID must belong to the target source meetings"
                    )
                if row["language"] not in LANGUAGES:
                    raise CommitmentLinkQualityError(f"{row_path}.language is invalid")
                bounded_text(row["text"], f"{row_path}.text")

        expected = exact_object(
            case["expected"],
            f"{path}.expected",
            {"semanticRelevantCommitmentIDs", "linkableCommitmentIDs", "mustAbstain"},
        )
        semantic_ids = bounded_ids(
            expected["semanticRelevantCommitmentIDs"],
            f"{path}.expected.semanticRelevantCommitmentIDs",
            MAXIMUM_SUGGESTIONS,
        )
        linkable_ids = bounded_ids(
            expected["linkableCommitmentIDs"],
            f"{path}.expected.linkableCommitmentIDs",
            MAXIMUM_SUGGESTIONS,
        )
        if not set(semantic_ids).issubset(target_ids):
            raise CommitmentLinkQualityError(f"{path} semantic truth references unknown targets")
        if not set(linkable_ids).issubset(semantic_ids):
            raise CommitmentLinkQualityError(f"{path} link truth must be semantically relevant")
        if not isinstance(expected["mustAbstain"], bool):
            raise CommitmentLinkQualityError(f"{path}.expected.mustAbstain must be boolean")
        if expected["mustAbstain"] != (not linkable_ids):
            raise CommitmentLinkQualityError(f"{path} abstention truth disagrees with links")

        for target_id in linkable_ids:
            target = target_by_id[target_id]
            if target["status"] != "confirmed":
                raise CommitmentLinkQualityError(f"{path} linkable target must be confirmed")
            if assignee_key(candidate["assignee"]) != assignee_key(target["assignee"]):
                raise CommitmentLinkQualityError(f"{path} linkable target must have exact ownership")
            if candidate["assignee"]["kind"] == "unassigned":
                raise CommitmentLinkQualityError(f"{path} unassigned candidate cannot be linkable")
            if candidate["sourceMeetingID"] in target["sourceMeetingIDs"]:
                raise CommitmentLinkQualityError(f"{path} linkable target cannot be same-meeting")

        if linkable_ids:
            linkable_count += 1
        else:
            abstention_count += 1

    if language_counts != Counter({"en": 12, "es": 12, "mixed": 12}):
        raise CommitmentLinkQualityError("fixture language distribution is invalid")
    if class_counts != Counter({
        "continuation": 12,
        "ambiguous": 3,
        "self-continuation": 3,
        "wrong-person": 3,
        "no-overlap": 3,
        "same-meeting": 3,
        "inactive-target": 3,
        "dismissed-target": 3,
        "unknown-owner": 3,
    }):
        raise CommitmentLinkQualityError("fixture class distribution is invalid")
    if linkable_count != 18 or abstention_count != 18:
        raise CommitmentLinkQualityError("fixture link/abstention distribution is invalid")
    return document


def private_text_rows(document):
    for case_index, case in enumerate(document["cases"]):
        yield (
            f"cases[{case_index}].candidate.text",
            case["candidate"]["text"],
        )
        for target_index, target_value in enumerate(case["targets"]):
            yield (
                f"cases[{case_index}].targets[{target_index}].title",
                target_value["title"],
            )
            for evidence_index, evidence in enumerate(target_value["evidence"]):
                yield (
                    f"cases[{case_index}].targets[{target_index}]"
                    f".evidence[{evidence_index}].text",
                    evidence["text"],
                )


def validate_private_fixture(document):
    exact_object(
        document,
        "private fixture",
        {
            "schemaVersion",
            "kind",
            "generation",
            "contentSource",
            "anonymization",
            "cases",
        },
    )
    if document["schemaVersion"] != SCHEMA_VERSION:
        raise CommitmentLinkQualityError(
            "private fixture schemaVersion is unsupported"
        )
    if document["kind"] != PRIVATE_FIXTURE_KIND:
        raise CommitmentLinkQualityError("private fixture kind is invalid")
    generation = safe_id(document["generation"], "private fixture.generation")
    if not generation.startswith("private-anonymized-"):
        raise CommitmentLinkQualityError(
            "private fixture generation must start with private-anonymized-"
        )
    if document["contentSource"] != PRIVATE_SOURCE:
        raise CommitmentLinkQualityError(
            "private fixture contentSource is invalid"
        )
    anonymization = exact_object(
        document["anonymization"],
        "private fixture.anonymization",
        {
            "policy",
            "reviewStatus",
            "containsAudio",
            "containsFilePaths",
            "containsAccountIdentifiers",
            "containsDirectIdentifiers",
        },
    )
    if anonymization["policy"] != PRIVATE_ANONYMIZATION_POLICY:
        raise CommitmentLinkQualityError(
            "private fixture anonymization policy is invalid"
        )
    if anonymization["reviewStatus"] != PRIVATE_REVIEW_STATUS:
        raise CommitmentLinkQualityError(
            "private fixture must be explicitly owner-reviewed"
        )
    for field in (
        "containsAudio",
        "containsFilePaths",
        "containsAccountIdentifiers",
        "containsDirectIdentifiers",
    ):
        if anonymization[field] is not False:
            raise CommitmentLinkQualityError(
                f"private fixture anonymization.{field} must be false"
            )

    validate_fixture({
        "schemaVersion": SCHEMA_VERSION,
        "kind": FIXTURE_KIND,
        "generation": PUBLIC_GENERATION,
        "contentSource": PUBLIC_SOURCE,
        "cases": document["cases"],
    })
    for path, value in private_text_rows(document):
        for label, pattern in PRIVATE_TEXT_PATTERNS:
            if pattern.search(value):
                raise CommitmentLinkQualityError(
                    f"{path} contains an obvious {label}"
                )
    return document


def validate_private_fixture_path(path):
    path = Path(path).expanduser()
    if path.is_symlink():
        raise CommitmentLinkQualityError(
            "private fixture must not be a symbolic link"
        )
    try:
        if not path.is_file() or stat.S_IMODE(path.stat().st_mode) != 0o600:
            raise CommitmentLinkQualityError(
                "private fixture must be a regular owner-only mode-0600 file"
            )
        resolved = path.resolve()
    except OSError as error:
        raise CommitmentLinkQualityError(
            "private fixture metadata could not be inspected"
        ) from error
    try:
        resolved.relative_to(REPOSITORY_ROOT)
    except ValueError:
        return resolved
    try:
        ignored = subprocess.run(
            ["git", "check-ignore", "--quiet", str(resolved)],
            cwd=REPOSITORY_ROOT,
            check=False,
            capture_output=True,
        )
    except OSError as error:
        raise CommitmentLinkQualityError(
            "private fixture ignore status could not be inspected"
        ) from error
    if ignored.returncode != 0:
        raise CommitmentLinkQualityError(
            "repository-local private fixture must be covered by .gitignore"
        )
    return resolved


def fixture_digest(document):
    return document_digest(document)


def document_digest(document):
    encoded = json.dumps(
        document,
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def evidence_by_id(case):
    return {
        row["id"]: (target, row)
        for target in case["targets"]
        for row in target["evidence"]
    }


def target_by_id(case):
    return {target["id"]: target for target in case["targets"]}


def validate_observations(document, fixture):
    exact_object(
        document,
        "observations",
        {"schemaVersion", "kind", "fixtureGeneration", "fixtureSHA256", "adapter", "observations"},
    )
    if document["schemaVersion"] != SCHEMA_VERSION:
        raise CommitmentLinkQualityError("observation schemaVersion is unsupported")
    if document["kind"] != OBSERVATION_KIND:
        raise CommitmentLinkQualityError("observation kind is invalid")
    if document["fixtureGeneration"] != fixture["generation"]:
        raise CommitmentLinkQualityError("observation fixture generation does not match")
    if document["fixtureSHA256"] != fixture_digest(fixture):
        raise CommitmentLinkQualityError("observation fixture digest does not match")
    if not isinstance(document["adapter"], str) or SAFE_ADAPTER.fullmatch(document["adapter"]) is None:
        raise CommitmentLinkQualityError("observation adapter is invalid")
    observations = document["observations"]
    if not isinstance(observations, list) or len(observations) != len(fixture["cases"]):
        raise CommitmentLinkQualityError("observations must contain exactly one row per case")

    cases = {case["id"]: case for case in fixture["cases"]}
    seen = set()
    for index, observation in enumerate(observations):
        path = f"observations[{index}]"
        exact_object(
            observation,
            path,
            {"caseID", "semanticHitSegmentIDs", "suggestions"},
        )
        case_id = safe_id(observation["caseID"], f"{path}.caseID")
        if case_id not in cases:
            raise CommitmentLinkQualityError(f"{path}.caseID is unknown")
        if case_id in seen:
            raise CommitmentLinkQualityError(f"duplicate observation case: {case_id}")
        seen.add(case_id)
        case = cases[case_id]
        known_evidence = evidence_by_id(case)
        hits = bounded_ids(
            observation["semanticHitSegmentIDs"],
            f"{path}.semanticHitSegmentIDs",
            MAXIMUM_SEMANTIC_HITS,
        )
        if not set(hits).issubset(known_evidence):
            raise CommitmentLinkQualityError(f"{path} semantic hits reference unknown evidence")
        suggestions = observation["suggestions"]
        if not isinstance(suggestions, list) or len(suggestions) > MAXIMUM_SUGGESTIONS:
            raise CommitmentLinkQualityError(f"{path}.suggestions must be bounded to three")
        known_targets = target_by_id(case)
        suggestion_ids = set()
        for suggestion_index, suggestion in enumerate(suggestions):
            suggestion_path = f"{path}.suggestions[{suggestion_index}]"
            exact_object(
                suggestion,
                suggestion_path,
                {"commitmentID", "assignee", "matchedEvidenceSegmentIDs", "bestSemanticRank"},
            )
            commitment_id = safe_id(suggestion["commitmentID"], f"{suggestion_path}.commitmentID")
            if commitment_id not in known_targets:
                raise CommitmentLinkQualityError(f"{suggestion_path}.commitmentID is unknown")
            if commitment_id in suggestion_ids:
                raise CommitmentLinkQualityError(f"{path}.suggestions contains duplicates")
            suggestion_ids.add(commitment_id)
            validate_assignee(suggestion["assignee"], f"{suggestion_path}.assignee")
            matched = bounded_ids(
                suggestion["matchedEvidenceSegmentIDs"],
                f"{suggestion_path}.matchedEvidenceSegmentIDs",
                MAXIMUM_RELATED_ROWS,
                allow_empty=False,
            )
            if not set(matched).issubset(known_evidence):
                raise CommitmentLinkQualityError(
                    f"{suggestion_path} matched evidence references unknown rows"
                )
            positive_integer(
                suggestion["bestSemanticRank"],
                f"{suggestion_path}.bestSemanticRank",
                MAXIMUM_SEMANTIC_HITS,
            )
    if seen != set(cases):
        raise CommitmentLinkQualityError("observations do not cover the canonical cases")
    return document


def validate_similarity_observations(document, fixture):
    exact_object(
        document,
        "similarity observations",
        {
            "schemaVersion",
            "kind",
            "fixtureGeneration",
            "fixtureSHA256",
            "adapter",
            "embeddingProfileFingerprint",
            "build",
            "commit",
            "evaluationStatus",
            "servingStatus",
            "observations",
        },
    )
    if document["schemaVersion"] != SCHEMA_VERSION:
        raise CommitmentLinkQualityError(
            "similarity observation schemaVersion is unsupported"
        )
    if document["kind"] != SIMILARITY_OBSERVATION_KIND:
        raise CommitmentLinkQualityError("similarity observation kind is invalid")
    if document["fixtureGeneration"] != fixture["generation"]:
        raise CommitmentLinkQualityError(
            "similarity observation fixture generation does not match"
        )
    if document["fixtureSHA256"] != fixture_digest(fixture):
        raise CommitmentLinkQualityError(
            "similarity observation fixture digest does not match"
        )
    if (
        not isinstance(document["adapter"], str)
        or SAFE_ADAPTER.fullmatch(document["adapter"]) is None
    ):
        raise CommitmentLinkQualityError("similarity observation adapter is invalid")
    if (
        not isinstance(document["embeddingProfileFingerprint"], str)
        or SHA256.fullmatch(document["embeddingProfileFingerprint"]) is None
    ):
        raise CommitmentLinkQualityError(
            "similarity observation embedding profile fingerprint is invalid"
        )
    if (
        not isinstance(document["build"], str)
        or SAFE_BUILD.fullmatch(document["build"]) is None
    ):
        raise CommitmentLinkQualityError("similarity observation build is invalid")
    if (
        not isinstance(document["commit"], str)
        or FULL_COMMIT.fullmatch(document["commit"]) is None
    ):
        raise CommitmentLinkQualityError("similarity observation commit is invalid")
    if document["evaluationStatus"] != "not-evaluated":
        raise CommitmentLinkQualityError(
            "similarity observations must remain not-evaluated"
        )
    if document["servingStatus"] != "not-approved":
        raise CommitmentLinkQualityError(
            "similarity observations must remain not-approved"
        )

    raw_observations = document["observations"]
    if not isinstance(raw_observations, list):
        raise CommitmentLinkQualityError(
            "similarity observations must contain an array"
        )
    projected_rows = []
    fixture_cases = {case["id"]: case for case in fixture["cases"]}
    for index, observation in enumerate(raw_observations):
        path = f"similarity observations[{index}]"
        exact_object(observation, path, {"caseID", "semanticHits", "suggestions"})
        case_id = safe_id(observation["caseID"], f"{path}.caseID")
        if case_id not in fixture_cases:
            raise CommitmentLinkQualityError(f"{path}.caseID is unknown")
        hits = observation["semanticHits"]
        if not isinstance(hits, list) or len(hits) > MAXIMUM_SEMANTIC_HITS:
            raise CommitmentLinkQualityError(
                f"{path}.semanticHits must be bounded to {MAXIMUM_SEMANTIC_HITS}"
            )
        known_evidence = evidence_by_id(fixture_cases[case_id])
        seen_evidence = set()
        previous_similarity = math.inf
        projected_ids = []
        for hit_index, hit in enumerate(hits):
            hit_path = f"{path}.semanticHits[{hit_index}]"
            exact_object(hit, hit_path, {"evidenceSegmentID", "similarity"})
            evidence_id = safe_id(
                hit["evidenceSegmentID"], f"{hit_path}.evidenceSegmentID"
            )
            if evidence_id not in known_evidence:
                raise CommitmentLinkQualityError(
                    f"{hit_path}.evidenceSegmentID is unknown"
                )
            if evidence_id in seen_evidence:
                raise CommitmentLinkQualityError(f"{path}.semanticHits contains duplicates")
            seen_evidence.add(evidence_id)
            similarity = hit["similarity"]
            if (
                isinstance(similarity, bool)
                or not isinstance(similarity, (int, float))
                or not math.isfinite(similarity)
                or not -1 <= similarity <= 1
            ):
                raise CommitmentLinkQualityError(
                    f"{hit_path}.similarity must be a finite cosine value"
                )
            if similarity > previous_similarity:
                raise CommitmentLinkQualityError(
                    f"{path}.semanticHits must be ordered by descending similarity"
                )
            previous_similarity = similarity
            projected_ids.append(evidence_id)
        projected_rows.append({
            "caseID": case_id,
            "semanticHitSegmentIDs": projected_ids,
            "suggestions": observation["suggestions"],
        })

    validate_observations({
        "schemaVersion": SCHEMA_VERSION,
        "kind": OBSERVATION_KIND,
        "fixtureGeneration": document["fixtureGeneration"],
        "fixtureSHA256": document["fixtureSHA256"],
        "adapter": document["adapter"],
        "observations": projected_rows,
    }, fixture)
    return document


def ratio(numerator, denominator):
    return round(numerator / denominator, 6) if denominator else None


def mean(values):
    return round(sum(values) / len(values), 6) if values else None


def suggestion_is_supported(case, observation, suggestion):
    target = target_by_id(case)[suggestion["commitmentID"]]
    candidate = case["candidate"]
    hits = observation["semanticHitSegmentIDs"]
    target_evidence = {row["id"] for row in target["evidence"]}
    expected_matches = [hit for hit in hits if hit in target_evidence]
    return (
        target["status"] == "confirmed"
        and candidate["assignee"]["kind"] != "unassigned"
        and assignee_key(candidate["assignee"]) == assignee_key(target["assignee"])
        and assignee_key(suggestion["assignee"]) == assignee_key(target["assignee"])
        and candidate["sourceMeetingID"] not in target["sourceMeetingIDs"]
        and suggestion["matchedEvidenceSegmentIDs"] == expected_matches
        and bool(expected_matches)
        and suggestion["bestSemanticRank"] == hits.index(expected_matches[0]) + 1
    )


def case_score(case, observation):
    expected = case["expected"]
    semantic_targets = set(expected["semanticRelevantCommitmentIDs"])
    linkable_targets = set(expected["linkableCommitmentIDs"])
    evidence_targets = {
        row["id"]: target["id"]
        for target in case["targets"]
        for row in target["evidence"]
    }
    retrieved_targets = []
    for evidence_id in observation["semanticHitSegmentIDs"]:
        target_id = evidence_targets[evidence_id]
        if target_id not in retrieved_targets:
            retrieved_targets.append(target_id)
    suggested_ids = [item["commitmentID"] for item in observation["suggestions"]]
    true_positive = len(linkable_targets.intersection(suggested_ids))
    false_positive = len(set(suggested_ids) - linkable_targets)
    false_negative = len(linkable_targets - set(suggested_ids))
    supported = sum(
        suggestion_is_supported(case, observation, item)
        for item in observation["suggestions"]
    )
    semantic_recall = ratio(
        len(semantic_targets.intersection(retrieved_targets)),
        len(semantic_targets),
    )
    link_recall = ratio(true_positive, len(linkable_targets))
    return {
        "caseID": case["id"],
        "language": case["language"],
        "class": case["class"],
        "semanticRelevantCount": len(semantic_targets),
        "semanticHitAt1": bool(retrieved_targets and retrieved_targets[0] in semantic_targets)
        if semantic_targets else None,
        "semanticTargetRecallAt20": semantic_recall,
        "expectedLinkCount": len(linkable_targets),
        "suggestionCount": len(suggested_ids),
        "truePositive": true_positive,
        "falsePositive": false_positive,
        "falseNegative": false_negative,
        "linkHitAt1": bool(suggested_ids and suggested_ids[0] in linkable_targets)
        if linkable_targets else None,
        "linkRecallAt3": link_recall,
        "abstained": not suggested_ids,
        "mustAbstain": expected["mustAbstain"],
        "supportedSuggestionCount": supported,
        "unsupportedSuggestionCount": len(suggested_ids) - supported,
    }


def grouped_metrics(details, field, names):
    groups = {}
    for name in names:
        rows = [row for row in details if row[field] == name]
        semantic_rows = [row for row in rows if row["semanticRelevantCount"]]
        link_rows = [row for row in rows if row["expectedLinkCount"]]
        abstention_rows = [row for row in rows if row["mustAbstain"]]
        groups[name] = {
            "cases": len(rows),
            "semanticTargetHitAt1": mean(
                [int(row["semanticHitAt1"]) for row in semantic_rows]
            ),
            "semanticTargetRecallAt20": mean(
                [row["semanticTargetRecallAt20"] for row in semantic_rows]
            ),
            "linkHitAt1": mean([int(row["linkHitAt1"]) for row in link_rows]),
            "linkRecallAt3": mean([row["linkRecallAt3"] for row in link_rows]),
            "abstentionAccuracy": mean(
                [int(row["abstained"]) for row in abstention_rows]
            ),
        }
    return groups


def evaluate(fixture, observation_document):
    fixture = validate_fixture(fixture)
    observation_document = validate_observations(observation_document, fixture)
    observations = {
        row["caseID"]: row for row in observation_document["observations"]
    }
    details = [case_score(case, observations[case["id"]]) for case in fixture["cases"]]
    true_positive = sum(row["truePositive"] for row in details)
    false_positive = sum(row["falsePositive"] for row in details)
    false_negative = sum(row["falseNegative"] for row in details)
    suggestion_count = sum(row["suggestionCount"] for row in details)
    supported = sum(row["supportedSuggestionCount"] for row in details)
    precision = ratio(true_positive, true_positive + false_positive)
    recall = ratio(true_positive, true_positive + false_negative)
    f1 = (
        round(2 * precision * recall / (precision + recall), 6)
        if precision is not None and recall is not None and precision + recall
        else None
    )
    semantic_rows = [row for row in details if row["semanticRelevantCount"]]
    link_rows = [row for row in details if row["expectedLinkCount"]]
    abstention_rows = [row for row in details if row["mustAbstain"]]
    scorecard = {
        "schemaVersion": SCHEMA_VERSION,
        "kind": SCORECARD_KIND,
        "fixtureGeneration": fixture["generation"],
        "fixtureSHA256": fixture_digest(fixture),
        "adapter": observation_document["adapter"],
        "contentSource": PUBLIC_SOURCE,
        "counts": {
            "cases": len(details),
            "semanticRelevantCases": len(semantic_rows),
            "linkableCases": len(link_rows),
            "abstentionCases": len(abstention_rows),
            "suggestions": suggestion_count,
            "truePositiveSuggestions": true_positive,
            "falsePositiveSuggestions": false_positive,
            "falseNegativeLinks": false_negative,
            "supportedSuggestions": supported,
            "unsupportedSuggestions": suggestion_count - supported,
        },
        "metrics": {
            "semanticTargetHitAt1": mean(
                [int(row["semanticHitAt1"]) for row in semantic_rows]
            ),
            "semanticTargetRecallAt20": mean(
                [row["semanticTargetRecallAt20"] for row in semantic_rows]
            ),
            "linkPrecision": precision,
            "linkRecall": recall,
            "linkF1": f1,
            "linkHitAt1": mean([int(row["linkHitAt1"]) for row in link_rows]),
            "linkRecallAt3": mean([row["linkRecallAt3"] for row in link_rows]),
            "abstentionAccuracy": mean(
                [int(row["abstained"]) for row in abstention_rows]
            ),
            "falseSuggestionRate": mean(
                [int(not row["abstained"]) for row in abstention_rows]
            ),
            "supportedSuggestionRate": ratio(supported, suggestion_count),
        },
        "byLanguage": grouped_metrics(details, "language", LANGUAGES),
        "byClass": grouped_metrics(details, "class", CLASSES),
        "qualityDecision": "review-required",
        "productDecision": "not-evaluated",
    }
    return scorecard, details


def unscored_similarity_projection(document):
    return {
        "schemaVersion": SCHEMA_VERSION,
        "kind": OBSERVATION_KIND,
        "fixtureGeneration": document["fixtureGeneration"],
        "fixtureSHA256": document["fixtureSHA256"],
        "adapter": document["adapter"],
        "observations": [
            {
                "caseID": row["caseID"],
                "semanticHitSegmentIDs": [
                    hit["evidenceSegmentID"] for hit in row["semanticHits"]
                ],
                "suggestions": row["suggestions"],
            }
            for row in document["observations"]
        ],
    }


def representative_similarity_thresholds(similarities):
    """Return one deterministic threshold for every distinct admission outcome."""
    unique = sorted(set(similarities))
    if not unique:
        return [-1.0]
    thresholds = [-1.0]
    for lower, upper in zip(unique, unique[1:]):
        midpoint = round((lower + upper) / 2, 12)
        thresholds.append(
            upper if midpoint <= lower or midpoint > upper else midpoint
        )
    maximum = unique[-1]
    if maximum < 1:
        midpoint = round((maximum + 1) / 2, 12)
        thresholds.append(
            1.0 if midpoint <= maximum or midpoint > 1 else midpoint
        )
    return thresholds


def replay_similarity_policies(fixture, similarity_document):
    fixture = validate_fixture(fixture)
    similarity_document = validate_similarity_observations(
        similarity_document,
        fixture,
    )
    unscored = unscored_similarity_projection(similarity_document)
    validate_observations(unscored, fixture)
    cases = {case["id"]: case for case in fixture["cases"]}
    scored_rows = {
        row["caseID"]: row for row in similarity_document["observations"]
    }
    unscored_rows = {
        row["caseID"]: row for row in unscored["observations"]
    }
    suggestion_scores = {}
    similarities = []
    baseline_suggestions = 0
    for case_id, observation in unscored_rows.items():
        case = cases[case_id]
        scores = {
            hit["evidenceSegmentID"]: hit["similarity"]
            for hit in scored_rows[case_id]["semanticHits"]
        }
        for suggestion in observation["suggestions"]:
            if not suggestion_is_supported(case, observation, suggestion):
                raise CommitmentLinkQualityError(
                    f"case {case_id} contains an unsupported legal suggestion"
                )
            best_similarity = max(
                scores[evidence_id]
                for evidence_id in suggestion["matchedEvidenceSegmentIDs"]
            )
            key = (case_id, suggestion["commitmentID"])
            suggestion_scores[key] = best_similarity
            similarities.append(best_similarity)
            baseline_suggestions += 1

    candidates = []
    for ordinal, threshold in enumerate(
        representative_similarity_thresholds(similarities),
        start=1,
    ):
        candidate_rows = []
        changed_cases = 0
        for row in unscored["observations"]:
            filtered = [
                suggestion
                for suggestion in row["suggestions"]
                if suggestion_scores[(row["caseID"], suggestion["commitmentID"])]
                >= threshold
            ]
            if len(filtered) != len(row["suggestions"]):
                changed_cases += 1
            candidate_rows.append({
                "caseID": row["caseID"],
                "semanticHitSegmentIDs": row["semanticHitSegmentIDs"],
                "suggestions": filtered,
            })
        candidate_document = {
            **{key: value for key, value in unscored.items() if key != "observations"},
            "observations": candidate_rows,
        }
        scorecard, _ = evaluate(fixture, candidate_document)
        admitted = scorecard["counts"]["suggestions"]
        candidates.append({
            "candidateID": f"candidate-{ordinal:03d}",
            "minimumSimilarity": threshold,
            "changedCases": changed_cases,
            "admittedSuggestions": admitted,
            "rejectedSuggestions": baseline_suggestions - admitted,
            "counts": scorecard["counts"],
            "metrics": scorecard["metrics"],
            "byLanguage": scorecard["byLanguage"],
            "byClass": scorecard["byClass"],
        })

    return {
        "schemaVersion": SCHEMA_VERSION,
        "kind": POLICY_REPLAY_KIND,
        "fixtureGeneration": fixture["generation"],
        "fixtureSHA256": fixture_digest(fixture),
        "sourceObservationSHA256": document_digest(similarity_document),
        "adapter": similarity_document["adapter"],
        "embeddingProfileFingerprint": similarity_document[
            "embeddingProfileFingerprint"
        ],
        "build": similarity_document["build"],
        "commit": similarity_document["commit"],
        "contentSource": fixture["contentSource"],
        "sweepGeneration": POLICY_SWEEP_GENERATION,
        "policyRule": POLICY_RULE,
        "candidateCount": len(candidates),
        "candidates": candidates,
        "evaluationStatus": "review-required",
        "selectionStatus": "not-selected",
        "productDecision": "not-evaluated",
        "servingStatus": "not-approved",
    }


def validate_policy_replay(document, fixture, similarity_document):
    expected = replay_similarity_policies(fixture, similarity_document)
    if document != expected:
        raise CommitmentLinkQualityError(
            "policy replay does not match deterministic recomputation"
        )
    return document


def owner(kind, identifier=None):
    return {"kind": kind, "id": identifier}


def target(identifier, title, assignee, language, text, *, status="confirmed", meetings=None):
    meeting_ids = meetings or [f"meeting-{identifier}"]
    return {
        "id": identifier,
        "title": title,
        "status": status,
        "assignee": assignee,
        "sourceMeetingIDs": meeting_ids,
        "evidence": [{
            "id": f"evidence-{identifier}",
            "meetingID": meeting_ids[0],
            "language": language,
            "text": text,
        }],
    }


def public_fixture():
    corpus = load_public_corpus()
    vocabularies = corpus["vocabularies"]
    templates = corpus["templates"]
    cases = []
    people = ("person-mara", "person-noah", "person-priya")
    class_sequence = (
        "continuation", "continuation", "continuation", "continuation",
        "ambiguous", "self-continuation", "wrong-person", "no-overlap",
        "same-meeting", "inactive-target", "unknown-owner", "dismissed-target",
    )
    serial = 0
    for language in LANGUAGES:
        for ordinal, vocabulary in enumerate(vocabularies[language]):
            serial += 1
            topic = vocabulary["topic"]
            action_text = vocabulary["actionText"]
            history_text = vocabulary["historyText"]
            case_class = class_sequence[ordinal]
            case_id = f"case-{serial:03d}"
            source_meeting = f"source-{case_id}"
            candidate_owner = owner("person", people[ordinal % len(people)])
            if case_class == "self-continuation":
                candidate_owner = owner("me")
            elif case_class == "unknown-owner":
                candidate_owner = owner("unassigned")
            primary_owner = candidate_owner
            if case_class == "wrong-person":
                primary_owner = owner("person", people[(ordinal + 1) % len(people)])
            elif case_class == "unknown-owner":
                primary_owner = owner("person", people[ordinal % len(people)])
            primary_id = f"target-{case_id}-a"
            primary_status = (
                "done" if case_class == "inactive-target"
                else "dismissed" if case_class == "dismissed-target"
                else "confirmed"
            )
            primary_meetings = [source_meeting] if case_class == "same-meeting" else None
            primary_text = history_text
            semantic_ids = [primary_id]
            linkable_ids = [primary_id]
            if case_class == "no-overlap":
                primary_text = templates["noOverlapEvidence"][language]
                semantic_ids = []
                linkable_ids = []
            elif case_class in {
                "wrong-person", "same-meeting", "inactive-target",
                "dismissed-target", "unknown-owner"
            }:
                linkable_ids = []
            primary = target(
                primary_id,
                action_text,
                primary_owner,
                language,
                primary_text,
                status=primary_status,
                meetings=primary_meetings,
            )
            if case_class == "continuation" and ordinal % 4 == 1:
                primary["evidence"].append({
                    "id": f"evidence-{primary_id}-follow-up",
                    "meetingID": primary["sourceMeetingIDs"][0],
                    "language": language,
                    "text": templates["repeatedCommitmentEvidence"][language].format(
                        topic=topic
                    ),
                })
            targets = [primary]
            if case_class == "ambiguous":
                secondary_id = f"target-{case_id}-b"
                targets.append(target(
                    secondary_id,
                    templates["ambiguousTitle"][language].format(
                        actionText=action_text
                    ),
                    candidate_owner,
                    language,
                    history_text.replace(
                        ".",
                        f" {templates['ambiguousHistoryReplacement'][language]}",
                    ),
                ))
                semantic_ids.append(secondary_id)
                linkable_ids.append(secondary_id)
            elif case_class in {"continuation", "wrong-person"}:
                distractor_id = f"target-{case_id}-b"
                distractor_owner = (
                    candidate_owner
                    if case_class == "wrong-person"
                    else owner("person", people[(ordinal + 1) % len(people)])
                )
                targets.append(target(
                    distractor_id,
                    templates["distractorTitle"][language],
                    distractor_owner,
                    language,
                    templates["distractorEvidence"][language],
                ))
            cases.append({
                "id": case_id,
                "language": language,
                "class": case_class,
                "candidate": {
                    "sourceMeetingID": source_meeting,
                    "actionItemID": f"action-{case_id}",
                    "language": language,
                    "text": action_text,
                    "assignee": candidate_owner,
                },
                "targets": targets,
                "expected": {
                    "semanticRelevantCommitmentIDs": semantic_ids,
                    "linkableCommitmentIDs": linkable_ids,
                    "mustAbstain": not linkable_ids,
                },
            })
    return {
        "schemaVersion": SCHEMA_VERSION,
        "kind": FIXTURE_KIND,
        "generation": PUBLIC_GENERATION,
        "contentSource": PUBLIC_SOURCE,
        "cases": cases,
    }


def control_observations(fixture):
    rows = []
    for case in fixture["cases"]:
        targets = target_by_id(case)
        semantic_ids = case["expected"]["semanticRelevantCommitmentIDs"]
        hits = [
            row["id"]
            for target_id in semantic_ids
            for row in targets[target_id]["evidence"]
        ][:MAXIMUM_SEMANTIC_HITS]
        suggestions = []
        for target_id in case["expected"]["linkableCommitmentIDs"]:
            target_value = targets[target_id]
            matched = [
                hit for hit in hits
                if hit in {row["id"] for row in target_value["evidence"]}
            ]
            suggestions.append({
                "commitmentID": target_id,
                "assignee": target_value["assignee"],
                "matchedEvidenceSegmentIDs": matched,
                "bestSemanticRank": hits.index(matched[0]) + 1,
            })
        suggestions.sort(key=lambda item: (
            item["bestSemanticRank"],
            -len(item["matchedEvidenceSegmentIDs"]),
            item["commitmentID"],
        ))
        rows.append({
            "caseID": case["id"],
            "semanticHitSegmentIDs": hits,
            "suggestions": suggestions[:MAXIMUM_SUGGESTIONS],
        })
    return {
        "schemaVersion": SCHEMA_VERSION,
        "kind": OBSERVATION_KIND,
        "fixtureGeneration": fixture["generation"],
        "fixtureSHA256": fixture_digest(fixture),
        "adapter": "research-perfect-control-v1",
        "observations": rows,
    }


def write_json(path, document, owner_only=False):
    path = Path(path).expanduser()
    if path.exists():
        raise CommitmentLinkQualityError(f"output already exists: {path}")
    path.parent.mkdir(parents=True, exist_ok=True)
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    mode = 0o600 if owner_only else 0o644
    descriptor = os.open(path, flags, mode)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
            json.dump(document, stream, ensure_ascii=False, indent=2)
            stream.write("\n")
    except Exception:
        path.unlink(missing_ok=True)
        raise
    if owner_only and stat.S_IMODE(path.stat().st_mode) != 0o600:
        path.unlink(missing_ok=True)
        raise CommitmentLinkQualityError("owner-only output permissions are invalid")


def parser():
    result = argparse.ArgumentParser(description=__doc__)
    subparsers = result.add_subparsers(dest="command", required=True)
    generate = subparsers.add_parser("generate-public")
    generate.add_argument("--output", required=True)
    validate = subparsers.add_parser("validate")
    validate.add_argument("--fixture", required=True)
    validate_private = subparsers.add_parser("validate-private")
    validate_private.add_argument("--fixture", required=True)
    validate_similarity = subparsers.add_parser("validate-similarity")
    validate_similarity.add_argument("--fixture", required=True)
    validate_similarity.add_argument("--observations", required=True)
    replay_similarity = subparsers.add_parser("replay-similarity")
    replay_similarity.add_argument("--fixture", required=True)
    replay_similarity.add_argument("--observations", required=True)
    replay_similarity.add_argument("--output", required=True)
    validate_replay = subparsers.add_parser("validate-policy-replay")
    validate_replay.add_argument("--fixture", required=True)
    validate_replay.add_argument("--observations", required=True)
    validate_replay.add_argument("--replay", required=True)
    control = subparsers.add_parser("control")
    control.add_argument("--fixture", required=True)
    control.add_argument("--details-output")
    evaluate_parser = subparsers.add_parser("evaluate")
    evaluate_parser.add_argument("--fixture", required=True)
    evaluate_parser.add_argument("--observations", required=True)
    evaluate_parser.add_argument("--details-output")
    return result


def main(argv=None):
    arguments = parser().parse_args(argv)
    try:
        if arguments.command == "generate-public":
            fixture = validate_fixture(public_fixture())
            write_json(arguments.output, fixture)
            return 0
        if arguments.command == "validate-private":
            fixture_path = validate_private_fixture_path(arguments.fixture)
            fixture = validate_private_fixture(
                load_json(fixture_path, "private fixture")
            )
            print(json.dumps({
                "kind": fixture["kind"],
                "generation": fixture["generation"],
                "contentSource": fixture["contentSource"],
                "cases": len(fixture["cases"]),
                "sha256": document_digest(fixture),
                "reviewStatus": fixture["anonymization"]["reviewStatus"],
            }, sort_keys=True))
            return 0
        fixture = validate_fixture(load_json(arguments.fixture, "fixture"))
        if fixture != public_fixture():
            raise CommitmentLinkQualityError(
                "fixture does not match the reproducible canonical generation"
            )
        if arguments.command == "validate":
            print(json.dumps({
                "kind": FIXTURE_KIND,
                "generation": fixture["generation"],
                "cases": len(fixture["cases"]),
                "sha256": fixture_digest(fixture),
            }, sort_keys=True))
            return 0
        if arguments.command == "validate-similarity":
            observations = validate_similarity_observations(
                load_json(arguments.observations, "similarity observations"),
                fixture,
            )
            print(json.dumps({
                "kind": observations["kind"],
                "fixtureSHA256": observations["fixtureSHA256"],
                "embeddingProfileFingerprint": observations[
                    "embeddingProfileFingerprint"
                ],
                "build": observations["build"],
                "commit": observations["commit"],
                "cases": len(observations["observations"]),
                "evaluationStatus": observations["evaluationStatus"],
                "servingStatus": observations["servingStatus"],
            }, sort_keys=True))
            return 0
        if arguments.command in {"replay-similarity", "validate-policy-replay"}:
            observations = validate_similarity_observations(
                load_json(arguments.observations, "similarity observations"),
                fixture,
            )
            if arguments.command == "replay-similarity":
                replay = replay_similarity_policies(fixture, observations)
                write_json(arguments.output, replay, owner_only=True)
            else:
                replay = validate_policy_replay(
                    load_json(arguments.replay, "policy replay"),
                    fixture,
                    observations,
                )
            print(json.dumps({
                "kind": replay["kind"],
                "sourceObservationSHA256": replay["sourceObservationSHA256"],
                "candidateCount": replay["candidateCount"],
                "evaluationStatus": replay["evaluationStatus"],
                "selectionStatus": replay["selectionStatus"],
                "productDecision": replay["productDecision"],
                "servingStatus": replay["servingStatus"],
            }, sort_keys=True))
            return 0
        observations = (
            control_observations(fixture)
            if arguments.command == "control"
            else load_json(arguments.observations, "observations")
        )
        scorecard, details = evaluate(fixture, observations)
        if arguments.details_output:
            write_json(arguments.details_output, {
                "schemaVersion": SCHEMA_VERSION,
                "kind": "commitment-link-quality-details",
                "fixtureSHA256": fixture_digest(fixture),
                "adapter": observations["adapter"],
                "cases": details,
            }, owner_only=True)
        print(json.dumps(scorecard, ensure_ascii=False, sort_keys=True))
        return 0
    except CommitmentLinkQualityError as error:
        print(f"commitment-link-quality: {error}", file=sys.stderr)
        return 64


if __name__ == "__main__":
    sys.exit(main())
