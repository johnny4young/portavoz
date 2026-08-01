#!/usr/bin/env python3
"""Strict, payload-free scoring for Portavoz Ask quality evidence."""

import argparse
import hashlib
import json
import math
import os
import re
import sys
import tempfile
import unicodedata
from pathlib import Path


SCHEMA_VERSION = 1
OBSERVATION_SCHEMA_VERSIONS = {1, 2}
FIXTURE_KIND = "ask-quality-fixture"
OBSERVATION_KIND = "ask-quality-observations"
SCORECARD_KIND = "ask-quality-scorecard"
COMPARISON_KIND = "ask-quality-comparison"
PUBLIC_GENERATION_V1 = "public-synthetic-v1"
PUBLIC_GENERATION = "public-synthetic-v2"
PUBLIC_GENERATIONS = {PUBLIC_GENERATION_V1, PUBLIC_GENERATION}
PUBLIC_SOURCE = "public-synthetic-only"
SEGMENT_ADAPTER = "local-hybrid-preindexed-segment-no-expansion-evidence-v3"
SPEAKER_TURN_ADAPTER = (
    "local-hybrid-preindexed-speaker-turn-v1-no-expansion-evidence-v1"
)
RELATIONSHIP_COUNTS = {
    "spanishToSpanish": 60,
    "englishToEnglish": 60,
    "englishToSpanish": 40,
    "spanishToEnglish": 40,
    "codeSwitched": 20,
    "robustness": 20,
}
RETRIEVAL_FLOORS = {
    "hitAt1": 0.95,
    "recallAt10": 0.98,
    "meanReciprocalRank": 0.96,
    "ndcgAt10": 0.96,
}
ANSWER_FLOORS = {
    "factuality": 0.95,
    "citationCoverage": 0.98,
}
RELATIONSHIP_RETRIEVAL_FLOORS = {
    "hitAt1": 0.90,
    "recallAt10": 0.95,
}
RELATIONSHIP_ANSWER_FLOORS = {
    "factuality": 0.90,
    "citationCoverage": 0.95,
}
INTENTS = {
    "name",
    "date",
    "commitment",
    "decision",
    "risk",
    "technicalIdentifier",
    "paraphrase",
    "negation",
    "notFound",
}
EXACT_RANK_ONE_INTENTS = {
    "name",
    "date",
    "commitment",
    "decision",
    "risk",
    "technicalIdentifier",
}
LANGUAGES = {"en", "es", "mixed"}
ANSWER_POLICIES = {"answer", "abstain"}
ANSWER_OUTCOMES = {"answered", "abstained", "notEvaluated"}
SCORECARD_OUTCOMES = {"pass", "blocked"}
SCORECARD_GATES = {
    "completeDistribution",
    "exactFactsRankFirst",
    "retrievalQualityFloor",
    "answerQualityFloor",
    "relationshipQualityFloor",
    "citationsCanonical",
    "answerPolicyHonored",
    "hardNegativesExcluded",
    "noUnsupportedClaims",
}
RETRIEVAL_METRICS = (
    "hitAt1",
    "recallAt10",
    "meanReciprocalRank",
    "ndcgAt10",
    "exactRankOne",
)
SCORE_RATE_METRICS = RETRIEVAL_METRICS + (
    "factuality",
    "citationCoverage",
    "answerOutcomeAccuracy",
)
SCORE_COUNT_METRICS = (
    "queryCount",
    "answerableCount",
    "abstentionCount",
    "hardNegativeHits",
    "invalidCitationHits",
    "staleCitationHits",
    "unsupportedClaims",
)
SAFE_ID = re.compile(r"^[a-z0-9][a-z0-9._-]{0,79}$")
SAFE_GENERATION = re.compile(r"^[a-z0-9][a-z0-9-]{0,39}$")
SAFE_BUILD = re.compile(r"^[A-Za-z0-9._+-]{1,80}$")
COMMIT = re.compile(r"^[0-9a-f]{40}$")
SHA256 = re.compile(r"^[0-9a-f]{64}$")


class AskQualityError(ValueError):
    """Fail-closed fixture, observation, or publication error."""


def reject_duplicate_keys(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise AskQualityError(f"duplicate key: {key}")
        result[key] = value
    return result


def load_json(path, label, maximum_bytes=8 * 1024 * 1024):
    path = Path(path).expanduser()
    try:
        if not path.is_file():
            raise AskQualityError(f"{label} not found: {path}")
        if path.stat().st_size > maximum_bytes:
            raise AskQualityError(f"{label} exceeds the size limit")
        return json.loads(
            path.read_text(encoding="utf-8"),
            object_pairs_hook=reject_duplicate_keys,
        )
    except OSError as error:
        raise AskQualityError(f"{label} could not be read: {path}") from error
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise AskQualityError(f"{label} is not valid UTF-8 JSON") from error


def object_shape(value, path, required, optional=()):
    if not isinstance(value, dict):
        raise AskQualityError(f"{path} must be an object")
    required = set(required)
    allowed = required | set(optional)
    missing = required - value.keys()
    extra = value.keys() - allowed
    if missing:
        raise AskQualityError(
            f"{path} is missing keys: {', '.join(sorted(missing))}"
        )
    if extra:
        raise AskQualityError(
            f"{path} contains forbidden keys: {', '.join(sorted(extra))}"
        )
    return value


def safe_string(value, path, pattern=SAFE_ID):
    if not isinstance(value, str) or pattern.fullmatch(value) is None:
        raise AskQualityError(f"{path} has an unsafe value")
    return value


def bounded_text(value, path, maximum):
    if not isinstance(value, str):
        raise AskQualityError(f"{path} must be text")
    value = value.strip()
    if not value or len(value) > maximum or "\x00" in value:
        raise AskQualityError(
            f"{path} must contain 1 to {maximum} safe characters"
        )
    return value


def enum_value(value, path, allowed):
    if value not in allowed:
        raise AskQualityError(
            f"{path} must be one of: {', '.join(sorted(allowed))}"
        )
    return value


def integer(value, path, minimum=0, maximum=None):
    if isinstance(value, bool) or not isinstance(value, int):
        raise AskQualityError(f"{path} must be an integer")
    if value < minimum or (maximum is not None and value > maximum):
        suffix = f" and <= {maximum}" if maximum is not None else ""
        raise AskQualityError(f"{path} must be >= {minimum}{suffix}")
    return value


def number(value, path, minimum=0, maximum=None):
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise AskQualityError(f"{path} must be numeric")
    value = float(value)
    if not math.isfinite(value):
        raise AskQualityError(f"{path} must be finite")
    if value < minimum or (maximum is not None and value > maximum):
        suffix = f" and <= {maximum}" if maximum is not None else ""
        raise AskQualityError(f"{path} must be >= {minimum}{suffix}")
    return value


def optional_number(value, path, minimum=0, maximum=None):
    if value is None:
        return None
    return number(value, path, minimum, maximum)


def string_array(value, path, maximum_count=20):
    if not isinstance(value, list) or len(value) > maximum_count:
        raise AskQualityError(
            f"{path} must be an array with at most {maximum_count} items"
        )
    result = [safe_string(item, f"{path}[{index}]") for index, item in enumerate(value)]
    if len(set(result)) != len(result):
        raise AskQualityError(f"{path} must not contain duplicates")
    return result


def validate_fixture(document, exact_distribution=True):
    fixture = object_shape(
        document,
        "fixture",
        (
            "schemaVersion",
            "kind",
            "generation",
            "contentSource",
            "segments",
            "queries",
        ),
    )
    if integer(fixture["schemaVersion"], "fixture.schemaVersion") != SCHEMA_VERSION:
        raise AskQualityError("fixture.schemaVersion must be 1")
    if fixture["kind"] != FIXTURE_KIND:
        raise AskQualityError(f"fixture.kind must be {FIXTURE_KIND}")
    generation = safe_string(
        fixture["generation"], "fixture.generation", SAFE_GENERATION
    )
    if fixture["contentSource"] not in {PUBLIC_SOURCE, "private-anonymized"}:
        raise AskQualityError("fixture.contentSource is not admitted")
    if not isinstance(fixture["segments"], list) or not fixture["segments"]:
        raise AskQualityError("fixture.segments must be a nonempty array")
    segments = {}
    for index, raw_segment in enumerate(fixture["segments"]):
        path = f"fixture.segments[{index}]"
        segment = object_shape(
            raw_segment,
            path,
            (
                "id",
                "meetingID",
                "meetingTitle",
                "timestampMilliseconds",
                "transcriptRevision",
                "language",
                "owner",
                "text",
            ),
        )
        identifier = safe_string(segment["id"], f"{path}.id")
        if identifier in segments:
            raise AskQualityError(f"fixture repeats segment: {identifier}")
        segments[identifier] = {
            "meetingID": safe_string(segment["meetingID"], f"{path}.meetingID"),
            "meetingTitle": bounded_text(
                segment["meetingTitle"], f"{path}.meetingTitle", 200
            ),
            "timestampMilliseconds": integer(
                segment["timestampMilliseconds"],
                f"{path}.timestampMilliseconds",
            ),
            "transcriptRevision": integer(
                segment["transcriptRevision"], f"{path}.transcriptRevision", 1
            ),
            "language": enum_value(
                segment["language"], f"{path}.language", LANGUAGES
            ),
            "owner": bounded_text(segment["owner"], f"{path}.owner", 120),
            "text": bounded_text(segment["text"], f"{path}.text", 2_000),
        }

    if not isinstance(fixture["queries"], list) or not fixture["queries"]:
        raise AskQualityError("fixture.queries must be a nonempty array")
    queries = {}
    relationship_counts = {key: 0 for key in RELATIONSHIP_COUNTS}
    for index, raw_query in enumerate(fixture["queries"]):
        path = f"fixture.queries[{index}]"
        query = object_shape(
            raw_query,
            path,
            (
                "id",
                "text",
                "relationship",
                "intent",
                "relevant",
                "hardNegativeSegmentIDs",
                "answerPolicy",
            ),
        )
        identifier = safe_string(query["id"], f"{path}.id")
        if identifier in queries:
            raise AskQualityError(f"fixture repeats query: {identifier}")
        relationship = enum_value(
            query["relationship"],
            f"{path}.relationship",
            RELATIONSHIP_COUNTS,
        )
        relationship_counts[relationship] += 1
        intent = enum_value(query["intent"], f"{path}.intent", INTENTS)
        answer_policy = enum_value(
            query["answerPolicy"], f"{path}.answerPolicy", ANSWER_POLICIES
        )
        if not isinstance(query["relevant"], list):
            raise AskQualityError(f"{path}.relevant must be an array")
        relevant = {}
        for relevant_index, raw_relevant in enumerate(query["relevant"]):
            relevant_path = f"{path}.relevant[{relevant_index}]"
            label = object_shape(
                raw_relevant,
                relevant_path,
                ("segmentID", "grade", "expectedTimestampMilliseconds", "expectedOwner"),
            )
            segment_id = safe_string(
                label["segmentID"], f"{relevant_path}.segmentID"
            )
            if segment_id not in segments:
                raise AskQualityError(
                    f"{relevant_path}.segmentID is absent from the corpus"
                )
            if segment_id in relevant:
                raise AskQualityError(f"{path}.relevant repeats {segment_id}")
            expected_timestamp = integer(
                label["expectedTimestampMilliseconds"],
                f"{relevant_path}.expectedTimestampMilliseconds",
            )
            expected_owner = bounded_text(
                label["expectedOwner"], f"{relevant_path}.expectedOwner", 120
            )
            segment = segments[segment_id]
            if (
                expected_timestamp != segment["timestampMilliseconds"]
                or expected_owner != segment["owner"]
            ):
                raise AskQualityError(
                    f"{relevant_path} does not match canonical corpus evidence"
                )
            relevant[segment_id] = integer(
                label["grade"], f"{relevant_path}.grade", 1, 3
            )
        hard_negatives = string_array(
            query["hardNegativeSegmentIDs"],
            f"{path}.hardNegativeSegmentIDs",
        )
        if any(segment_id not in segments for segment_id in hard_negatives):
            raise AskQualityError(f"{path} references an unknown hard negative")
        if set(relevant).intersection(hard_negatives):
            raise AskQualityError(f"{path} overlaps relevant and hard-negative evidence")
        if answer_policy == "answer" and not relevant:
            raise AskQualityError(f"{path} must label answerable evidence")
        if answer_policy == "abstain" and relevant:
            raise AskQualityError(f"{path} abstention query must not label evidence")
        if intent == "notFound" and answer_policy != "abstain":
            raise AskQualityError(f"{path} notFound query must require abstention")
        queries[identifier] = {
            "text": bounded_text(query["text"], f"{path}.text", 500),
            "relationship": relationship,
            "intent": intent,
            "relevant": relevant,
            "hardNegatives": set(hard_negatives),
            "answerPolicy": answer_policy,
        }
    if exact_distribution and relationship_counts != RELATIONSHIP_COUNTS:
        raise AskQualityError(
            "fixture query distribution must be exactly "
            + json.dumps(RELATIONSHIP_COUNTS, sort_keys=True)
        )
    if fixture["contentSource"] == PUBLIC_SOURCE:
        if generation not in PUBLIC_GENERATIONS:
            raise AskQualityError("public Ask quality generation is not canonical")
        if fixture != public_fixture(generation):
            raise AskQualityError("public Ask quality fixture is not canonical")
    return {
        "generation": generation,
        "contentSource": fixture["contentSource"],
        "segments": segments,
        "queries": queries,
        "relationshipCounts": relationship_counts,
        "checksum": fixture_checksum(fixture),
    }


def validate_observations(document, fixture):
    root = object_shape(
        document,
        "observations",
        (
            "schemaVersion",
            "kind",
            "fixtureGeneration",
            "adapter",
            "build",
            "commit",
            "queries",
        ),
    )
    schema_version = integer(
        root["schemaVersion"], "observations.schemaVersion"
    )
    if schema_version not in OBSERVATION_SCHEMA_VERSIONS:
        raise AskQualityError("observations.schemaVersion must be 1 or 2")
    if root["kind"] != OBSERVATION_KIND:
        raise AskQualityError(f"observations.kind must be {OBSERVATION_KIND}")
    if root["fixtureGeneration"] != fixture["generation"]:
        raise AskQualityError("observations.fixtureGeneration does not match fixture")
    subject = {
        "adapter": safe_string(root["adapter"], "observations.adapter"),
        "build": safe_string(root["build"], "observations.build", SAFE_BUILD),
        "commit": safe_string(root["commit"], "observations.commit", COMMIT),
        "observationSchemaVersion": schema_version,
    }
    if not isinstance(root["queries"], list):
        raise AskQualityError("observations.queries must be an array")
    observations = {}
    for index, raw_observation in enumerate(root["queries"]):
        path = f"observations.queries[{index}]"
        observation = object_shape(
            raw_observation,
            path,
            ("queryID", "hits", "answer"),
        )
        query_id = safe_string(observation["queryID"], f"{path}.queryID")
        if query_id not in fixture["queries"]:
            raise AskQualityError(f"{path}.queryID is absent from the fixture")
        if query_id in observations:
            raise AskQualityError(f"observations repeat query: {query_id}")
        if not isinstance(observation["hits"], list) or len(observation["hits"]) > 10:
            raise AskQualityError(f"{path}.hits must contain at most ten results")
        hits = []
        seen_units = set()
        seen_sources = set()
        for hit_index, raw_hit in enumerate(observation["hits"]):
            hit_path = f"{path}.hits[{hit_index}]"
            if schema_version == 1:
                hit = object_shape(
                    raw_hit,
                    hit_path,
                    (
                        "segmentID",
                        "meetingID",
                        "timestampMilliseconds",
                        "transcriptRevision",
                    ),
                )
                segment_id = safe_string(
                    hit["segmentID"], f"{hit_path}.segmentID"
                )
                unit_id = segment_id
                source_segment_ids = [segment_id]
            else:
                hit = object_shape(
                    raw_hit,
                    hit_path,
                    (
                        "unitID",
                        "sourceSegmentIDs",
                        "meetingID",
                        "timestampMilliseconds",
                        "transcriptRevision",
                    ),
                )
                unit_id = safe_string(hit["unitID"], f"{hit_path}.unitID")
                source_segment_ids = string_array(
                    hit["sourceSegmentIDs"],
                    f"{hit_path}.sourceSegmentIDs",
                    maximum_count=512,
                )
                if not source_segment_ids:
                    raise AskQualityError(
                        f"{hit_path}.sourceSegmentIDs must not be empty"
                    )
            if unit_id in seen_units:
                raise AskQualityError(f"{path}.hits repeat unit: {unit_id}")
            repeated_sources = seen_sources.intersection(source_segment_ids)
            if repeated_sources:
                raise AskQualityError(
                    f"{path}.hits repeat source segment: "
                    + sorted(repeated_sources)[0]
                )
            seen_units.add(unit_id)
            seen_sources.update(source_segment_ids)
            hits.append(
                {
                    "unitID": unit_id,
                    "sourceSegmentIDs": source_segment_ids,
                    "meetingID": safe_string(
                        hit["meetingID"], f"{hit_path}.meetingID"
                    ),
                    "timestampMilliseconds": integer(
                        hit["timestampMilliseconds"],
                        f"{hit_path}.timestampMilliseconds",
                    ),
                    "transcriptRevision": integer(
                        hit["transcriptRevision"],
                        f"{hit_path}.transcriptRevision",
                        1,
                    ),
                }
            )
        answer = object_shape(
            observation["answer"],
            f"{path}.answer",
            ("outcome", "factuality", "citationCoverage", "unsupportedClaims"),
        )
        outcome = enum_value(
            answer["outcome"],
            f"{path}.answer.outcome",
            ANSWER_OUTCOMES,
        )
        factuality = optional_number(
            answer["factuality"], f"{path}.answer.factuality", 0, 1
        )
        citation_coverage = optional_number(
            answer["citationCoverage"],
            f"{path}.answer.citationCoverage",
            0,
            1,
        )
        unsupported_claims = integer(
            answer["unsupportedClaims"],
            f"{path}.answer.unsupportedClaims",
        )
        if outcome == "notEvaluated":
            if factuality is not None or citation_coverage is not None:
                raise AskQualityError(
                    f"{path}.answer unevaluated scores must be null"
                )
            if unsupported_claims != 0:
                raise AskQualityError(
                    f"{path}.answer unevaluated claims must be zero"
                )
        elif factuality is None or citation_coverage is None:
            raise AskQualityError(
                f"{path}.answer evaluated scores must be numeric"
            )
        observations[query_id] = {
            "hits": hits,
            "answer": {
                "outcome": outcome,
                "factuality": factuality,
                "citationCoverage": citation_coverage,
                "unsupportedClaims": unsupported_claims,
            },
        }
    missing = set(fixture["queries"]) - set(observations)
    if missing:
        raise AskQualityError(
            "observations are incomplete; missing query IDs: "
            + ", ".join(sorted(missing)[:5])
        )
    return {"subject": subject, "queries": observations}


def fixture_checksum(fixture):
    encoded = json.dumps(
        fixture,
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def ndcg(grades, ideal_grades):
    if not ideal_grades:
        return None
    dcg = sum(
        (2**grade - 1) / math.log2(index + 2)
        for index, grade in enumerate(grades[:10])
    )
    ideal = sorted(ideal_grades, reverse=True)
    idcg = sum(
        (2**grade - 1) / math.log2(index + 2)
        for index, grade in enumerate(ideal[:10])
    )
    return dcg / idcg if idcg else None


def query_score(query, observation, segments):
    valid_units = []
    invalid_hits = 0
    stale_hits = 0
    for hit in observation["hits"]:
        canonical_sources = [
            segments.get(segment_id)
            for segment_id in hit["sourceSegmentIDs"]
        ]
        if any(source is None for source in canonical_sources):
            invalid_hits += 1
            continue
        ordered_source_ids = sorted(
            hit["sourceSegmentIDs"],
            key=lambda segment_id: (
                segments[segment_id]["timestampMilliseconds"],
                segment_id,
            ),
        )
        first = canonical_sources[0]
        if (
            hit["sourceSegmentIDs"] != ordered_source_ids
            or any(
                source["meetingID"] != hit["meetingID"]
                or source["transcriptRevision"] != hit["transcriptRevision"]
                for source in canonical_sources
            )
            or hit["timestampMilliseconds"] != first["timestampMilliseconds"]
        ):
            stale_hits += 1
            continue
        valid_units.append(hit["sourceSegmentIDs"])
    grades = [
        max((query["relevant"].get(segment_id, 0) for segment_id in unit), default=0)
        for unit in valid_units
    ]
    relevant_ranks = [index + 1 for index, grade in enumerate(grades) if grade > 0]
    covered_sources = {
        segment_id for unit in valid_units for segment_id in unit
    }
    answerable = query["answerPolicy"] == "answer"
    expected_outcome = "answered" if answerable else "abstained"
    answer = observation["answer"]
    return {
        "relationship": query["relationship"],
        "intent": query["intent"],
        "answerable": answerable,
        "hitAt1": bool(grades and grades[0] > 0) if answerable else None,
        "recallAt10": (
            len(covered_sources.intersection(query["relevant"]))
            / len(query["relevant"])
            if answerable
            else None
        ),
        "reciprocalRank": 1 / relevant_ranks[0] if relevant_ranks else (0 if answerable else None),
        "ndcgAt10": (
            ndcg(grades, list(query["relevant"].values()))
            if answerable
            else None
        ),
        "hardNegativeHits": len(
            covered_sources.intersection(query["hardNegatives"])
        ),
        "invalidHits": invalid_hits,
        "staleHits": stale_hits,
        "answerOutcomeCorrect": answer["outcome"] == expected_outcome,
        "factuality": answer["factuality"] if answerable else None,
        "citationCoverage": answer["citationCoverage"] if answerable else None,
        "unsupportedClaims": answer["unsupportedClaims"],
        "exactRankOneRequired": answerable and query["intent"] in EXACT_RANK_ONE_INTENTS,
    }


def average(values):
    values = [value for value in values if value is not None]
    return sum(values) / len(values) if values else None


def aggregate(scores):
    answerable = [score for score in scores if score["answerable"]]
    exact = [score for score in scores if score["exactRankOneRequired"]]
    return {
        "queryCount": len(scores),
        "answerableCount": len(answerable),
        "abstentionCount": len(scores) - len(answerable),
        "hitAt1": average([score["hitAt1"] for score in answerable]),
        "recallAt10": average([score["recallAt10"] for score in answerable]),
        "meanReciprocalRank": average(
            [score["reciprocalRank"] for score in answerable]
        ),
        "ndcgAt10": average([score["ndcgAt10"] for score in answerable]),
        "exactRankOne": average([score["hitAt1"] for score in exact]),
        "factuality": average([score["factuality"] for score in answerable]),
        "citationCoverage": average(
            [score["citationCoverage"] for score in answerable]
        ),
        "answerOutcomeAccuracy": average(
            [score["answerOutcomeCorrect"] for score in scores]
        ),
        "hardNegativeHits": sum(score["hardNegativeHits"] for score in scores),
        "invalidCitationHits": sum(score["invalidHits"] for score in scores),
        "staleCitationHits": sum(score["staleHits"] for score in scores),
        "unsupportedClaims": sum(score["unsupportedClaims"] for score in scores),
    }


def meets_floors(metrics, floors):
    return all(
        metrics[name] is not None and metrics[name] >= minimum
        for name, minimum in floors.items()
    )


def evaluate(fixture, observation_document):
    observations = observation_document["queries"]
    scores = [
        query_score(query, observations[query_id], fixture["segments"])
        for query_id, query in sorted(fixture["queries"].items())
    ]
    overall = aggregate(scores)
    slices = {
        relationship: aggregate(
            [score for score in scores if score["relationship"] == relationship]
        )
        for relationship in RELATIONSHIP_COUNTS
    }
    gates = {
        "completeDistribution": fixture["relationshipCounts"] == RELATIONSHIP_COUNTS,
        "exactFactsRankFirst": overall["exactRankOne"] == 1,
        "retrievalQualityFloor": meets_floors(overall, RETRIEVAL_FLOORS),
        "answerQualityFloor": meets_floors(overall, ANSWER_FLOORS),
        "relationshipQualityFloor": all(
            meets_floors(metrics, RELATIONSHIP_RETRIEVAL_FLOORS)
            and meets_floors(metrics, RELATIONSHIP_ANSWER_FLOORS)
            for metrics in slices.values()
        ),
        "citationsCanonical": (
            overall["invalidCitationHits"] == 0
            and overall["staleCitationHits"] == 0
        ),
        "answerPolicyHonored": overall["answerOutcomeAccuracy"] == 1,
        "hardNegativesExcluded": overall["hardNegativeHits"] == 0,
        "noUnsupportedClaims": overall["unsupportedClaims"] == 0,
    }
    return {
        "schemaVersion": SCHEMA_VERSION,
        "kind": SCORECARD_KIND,
        "outcome": "pass" if all(gates.values()) else "blocked",
        "subject": observation_document["subject"],
        "fixture": {
            "generation": fixture["generation"],
            "contentSource": fixture["contentSource"],
            "checksum": fixture["checksum"],
            "queryCount": len(fixture["queries"]),
            "segmentCount": len(fixture["segments"]),
            "relationshipCounts": fixture["relationshipCounts"],
        },
        "qualityFloors": {
            "overallRetrieval": RETRIEVAL_FLOORS,
            "overallAnswer": ANSWER_FLOORS,
            "perRelationshipRetrieval": RELATIONSHIP_RETRIEVAL_FLOORS,
            "perRelationshipAnswer": RELATIONSHIP_ANSWER_FLOORS,
        },
        "gates": gates,
        "overall": overall,
        "slices": slices,
    }


def validate_scorecard(document, label="scorecard"):
    root = object_shape(
        document,
        label,
        (
            "schemaVersion",
            "kind",
            "outcome",
            "subject",
            "fixture",
            "qualityFloors",
            "gates",
            "overall",
            "slices",
        ),
    )
    if integer(root["schemaVersion"], f"{label}.schemaVersion") != SCHEMA_VERSION:
        raise AskQualityError(f"{label}.schemaVersion must be 1")
    if root["kind"] != SCORECARD_KIND:
        raise AskQualityError(f"{label}.kind must be {SCORECARD_KIND}")
    outcome = enum_value(root["outcome"], f"{label}.outcome", SCORECARD_OUTCOMES)
    subject = validate_scorecard_subject(root["subject"], f"{label}.subject")
    fixture = validate_scorecard_fixture(root["fixture"], f"{label}.fixture")
    expected_floors = {
        "overallRetrieval": RETRIEVAL_FLOORS,
        "overallAnswer": ANSWER_FLOORS,
        "perRelationshipRetrieval": RELATIONSHIP_RETRIEVAL_FLOORS,
        "perRelationshipAnswer": RELATIONSHIP_ANSWER_FLOORS,
    }
    if root["qualityFloors"] != expected_floors:
        raise AskQualityError(f"{label}.qualityFloors are not canonical")
    gates = validate_scorecard_gates(root["gates"], f"{label}.gates")
    if (outcome == "pass") != all(gates.values()):
        raise AskQualityError(f"{label}.outcome does not match its gates")
    overall = validate_score_metrics(root["overall"], f"{label}.overall")
    slices = object_shape(
        root["slices"],
        f"{label}.slices",
        tuple(RELATIONSHIP_COUNTS),
    )
    normalized_slices = {
        relationship: validate_score_metrics(
            slices[relationship], f"{label}.slices.{relationship}"
        )
        for relationship in RELATIONSHIP_COUNTS
    }
    if overall["queryCount"] != fixture["queryCount"]:
        raise AskQualityError(f"{label}.overall query count does not match fixture")
    if sum(item["queryCount"] for item in normalized_slices.values()) != overall[
        "queryCount"
    ]:
        raise AskQualityError(f"{label}.slice query counts do not match overall")
    return {
        "outcome": outcome,
        "subject": subject,
        "fixture": fixture,
        "gates": gates,
        "overall": overall,
        "slices": normalized_slices,
    }


def validate_scorecard_subject(subject, path):
    value = object_shape(
        subject,
        path,
        ("adapter", "build", "commit", "observationSchemaVersion"),
    )
    return {
        "adapter": safe_string(value["adapter"], f"{path}.adapter"),
        "build": safe_string(value["build"], f"{path}.build", SAFE_BUILD),
        "commit": safe_string(value["commit"], f"{path}.commit", COMMIT),
        "observationSchemaVersion": integer(
            value["observationSchemaVersion"],
            f"{path}.observationSchemaVersion",
            1,
        ),
    }


def validate_scorecard_fixture(fixture, path):
    value = object_shape(
        fixture,
        path,
        (
            "generation",
            "contentSource",
            "checksum",
            "queryCount",
            "segmentCount",
            "relationshipCounts",
        ),
    )
    relationship_counts = object_shape(
        value["relationshipCounts"],
        f"{path}.relationshipCounts",
        tuple(RELATIONSHIP_COUNTS),
    )
    return {
        "generation": safe_string(
            value["generation"], f"{path}.generation", SAFE_GENERATION
        ),
        "contentSource": enum_value(
            value["contentSource"],
            f"{path}.contentSource",
            {PUBLIC_SOURCE, "private-anonymized"},
        ),
        "checksum": safe_string(value["checksum"], f"{path}.checksum", SHA256),
        "queryCount": integer(value["queryCount"], f"{path}.queryCount", 1),
        "segmentCount": integer(value["segmentCount"], f"{path}.segmentCount", 1),
        "relationshipCounts": {
            relationship: integer(
                relationship_counts[relationship],
                f"{path}.relationshipCounts.{relationship}",
            )
            for relationship in RELATIONSHIP_COUNTS
        },
    }


def validate_scorecard_gates(gates, path):
    value = object_shape(gates, path, tuple(SCORECARD_GATES))
    if any(not isinstance(result, bool) for result in value.values()):
        raise AskQualityError(f"{path} values must be booleans")
    return {gate: value[gate] for gate in sorted(SCORECARD_GATES)}


def validate_score_metrics(metrics, path):
    value = object_shape(
        metrics,
        path,
        SCORE_RATE_METRICS + SCORE_COUNT_METRICS,
    )
    result = {
        metric: optional_number(value[metric], f"{path}.{metric}", 0, 1)
        for metric in SCORE_RATE_METRICS
    }
    result.update(
        {
            metric: integer(value[metric], f"{path}.{metric}")
            for metric in SCORE_COUNT_METRICS
        }
    )
    return result


def compare_scorecards(fixture, control, candidate):
    same_fixture = all(
        scorecard_fixture_matches(item["fixture"], fixture)
        for item in (control, candidate)
    )
    same_run = all(
        control["subject"][key] == candidate["subject"][key]
        for key in ("build", "commit")
    )
    schema_two = all(
        item["subject"]["observationSchemaVersion"] == 2
        for item in (control, candidate)
    )
    expected_adapters = (
        control["subject"]["adapter"] == SEGMENT_ADAPTER
        and candidate["subject"]["adapter"] == SPEAKER_TURN_ADAPTER
    )
    aggregate_parity = retrieval_parity(
        control["overall"], candidate["overall"]
    )
    slice_parity = all(
        retrieval_parity(
            control["slices"][relationship],
            candidate["slices"][relationship],
        )
        for relationship in RELATIONSHIP_COUNTS
    )
    canonical_sources = all(
        item["gates"]["citationsCanonical"]
        and item["overall"]["invalidCitationHits"] == 0
        and item["overall"]["staleCitationHits"] == 0
        for item in (control, candidate)
    )
    hard_negative_parity = (
        candidate["overall"]["hardNegativeHits"]
        <= control["overall"]["hardNegativeHits"]
    )
    gates = {
        "fixtureIdentityMatches": same_fixture,
        "runIdentityMatches": same_run,
        "observationSchemaIsTwo": schema_two,
        "adapterRolesMatch": expected_adapters,
        "aggregateRetrievalParity": aggregate_parity,
        "relationshipRetrievalParity": slice_parity,
        "citationsCanonical": canonical_sources,
        "hardNegativesDoNotRegress": hard_negative_parity,
    }
    return {
        "schemaVersion": SCHEMA_VERSION,
        "kind": COMPARISON_KIND,
        "outcome": "candidate-parity" if all(gates.values()) else "blocked",
        "subject": {
            "build": control["subject"]["build"],
            "commit": control["subject"]["commit"],
            "controlAdapter": control["subject"]["adapter"],
            "candidateAdapter": candidate["subject"]["adapter"],
            "observationSchemaVersion": control["subject"][
                "observationSchemaVersion"
            ],
        },
        "fixture": {
            "generation": fixture["generation"],
            "checksum": fixture["checksum"],
            "queryCount": len(fixture["queries"]),
            "segmentCount": len(fixture["segments"]),
            "relationshipCounts": fixture["relationshipCounts"],
        },
        "sourceOutcomes": {
            "control": control["outcome"],
            "candidate": candidate["outcome"],
        },
        "gates": gates,
        "aggregateDeltas": metric_deltas(
            control["overall"], candidate["overall"]
        ),
        "relationshipDeltas": {
            relationship: metric_deltas(
                control["slices"][relationship],
                candidate["slices"][relationship],
            )
            for relationship in RELATIONSHIP_COUNTS
        },
    }


def scorecard_fixture_matches(scorecard_fixture, fixture):
    return scorecard_fixture == {
        "generation": fixture["generation"],
        "contentSource": fixture["contentSource"],
        "checksum": fixture["checksum"],
        "queryCount": len(fixture["queries"]),
        "segmentCount": len(fixture["segments"]),
        "relationshipCounts": fixture["relationshipCounts"],
    }


def retrieval_parity(control, candidate):
    return all(
        control[metric] is not None
        and candidate[metric] is not None
        and candidate[metric] + 1e-12 >= control[metric]
        for metric in RETRIEVAL_METRICS
    )


def metric_deltas(control, candidate):
    metrics = RETRIEVAL_METRICS + (
        "hardNegativeHits",
        "invalidCitationHits",
        "staleCitationHits",
    )
    return {
        metric: (
            None
            if control[metric] is None or candidate[metric] is None
            else candidate[metric] - control[metric]
        )
        for metric in metrics
    }


def public_fixture(generation=PUBLIC_GENERATION):
    if generation not in PUBLIC_GENERATIONS:
        raise AskQualityError(f"unknown public fixture generation: {generation}")
    relationships = public_relationships(generation)
    owners = ["Mara", "Noah", "Sofía", "Eli", "Iris", "Leo"]
    intents = [
        "name",
        "date",
        "commitment",
        "decision",
        "risk",
        "technicalIdentifier",
        "paraphrase",
        "negation",
    ]
    segments = []
    queries = []
    relationship_ordinals = {key: 0 for key in RELATIONSHIP_COUNTS}
    for index, relationship in enumerate(relationships):
        relationship_ordinals[relationship] += 1
        relationship_ordinal = relationship_ordinals[relationship]
        ordinal = index + 1
        identifier = f"atlas-{ordinal:03d}"
        segment_id = f"segment-{ordinal:03d}"
        meeting_id = f"meeting-{(index // 4) + 1:03d}"
        owner = public_owner(generation, index, owners)
        intent = public_intent(
            generation,
            index,
            relationship_ordinal,
            intents,
        )
        answer_policy = "answer"
        if relationship == "robustness" and relationship_ordinal > 15:
            intent = "notFound"
            answer_policy = "abstain"
        evidence_language = (
            "es"
            if relationship
            in {"spanishToSpanish", "englishToSpanish", "robustness"}
            else "en"
        )
        if relationship == "codeSwitched":
            evidence_language = "mixed"
        segment_text = evidence_text(
            evidence_language, intent, owner, identifier
        )
        timestamp = ordinal * 1_000
        segments.append(
            {
                "id": segment_id,
                "meetingID": meeting_id,
                "meetingTitle": f"Public synthetic meeting {(index // 4) + 1:03d}",
                "timestampMilliseconds": timestamp,
                "transcriptRevision": 1,
                "language": evidence_language,
                "owner": owner,
                "text": segment_text,
            }
        )
        query_text = query_text_for(
            relationship,
            owner,
            identifier,
            intent,
            robustness_ordinal=(
                relationship_ordinal if relationship == "robustness" else None
            ),
            not_found=answer_policy == "abstain",
        )
        relevant = []
        if answer_policy == "answer":
            relevant = [
                {
                    "segmentID": segment_id,
                    "grade": 3,
                    "expectedTimestampMilliseconds": timestamp,
                    "expectedOwner": owner,
                }
            ]
        hard_negative = public_hard_negative(generation, index, len(relationships))
        queries.append(
            {
                "id": f"query-{ordinal:03d}",
                "text": query_text,
                "relationship": relationship,
                "intent": intent,
                "relevant": relevant,
                "hardNegativeSegmentIDs": [hard_negative],
                "answerPolicy": answer_policy,
            }
        )
    return {
        "schemaVersion": SCHEMA_VERSION,
        "kind": FIXTURE_KIND,
        "generation": generation,
        "contentSource": PUBLIC_SOURCE,
        "segments": segments,
        "queries": queries,
    }


def public_relationships(generation):
    if generation == PUBLIC_GENERATION_V1:
        return [
            relationship
            for relationship, count in RELATIONSHIP_COUNTS.items()
            for _ in range(count)
        ]
    remaining = dict(RELATIONSHIP_COUNTS)
    relationships = []
    while any(remaining.values()):
        for relationship in RELATIONSHIP_COUNTS:
            if remaining[relationship] > 0:
                relationships.append(relationship)
                remaining[relationship] -= 1
    return relationships


def public_owner(generation, index, owners):
    if generation == PUBLIC_GENERATION_V1:
        return owners[index % len(owners)]
    meeting_index = index // 4
    turn_index = (index % 4) // 2
    return owners[((meeting_index * 2) + turn_index) % len(owners)]


def public_intent(generation, index, relationship_ordinal, intents):
    if generation == PUBLIC_GENERATION_V1:
        return intents[index % len(intents)]
    return intents[(relationship_ordinal - 1) % len(intents)]


def public_hard_negative(generation, index, segment_count):
    offset = 1 if generation == PUBLIC_GENERATION_V1 else 48
    return f"segment-{((index + offset) % segment_count) + 1:03d}"


def evidence_text(language, intent, owner, identifier):
    spanish = {
        "name": f"{owner} nombró a {identifier} como responsable de la migración.",
        "date": f"{owner} fijó la entrega {identifier} para el viernes 12 de marzo.",
        "commitment": f"{owner} se comprometió a entregar {identifier} antes del viernes.",
        "decision": f"{owner} confirmó la decisión {identifier}: aprobar el presupuesto.",
        "risk": f"{owner} registró el riesgo {identifier}: la migración puede duplicar eventos.",
        "technicalIdentifier": f"{owner} indicó que {identifier} usa GraphQL schema v3.",
        "paraphrase": f"{owner} acordó {identifier}: posponer el lanzamiento hasta abril.",
        "negation": f"{owner} aclaró que {identifier} no debe eliminar registros históricos.",
        "notFound": f"{owner} documentó {identifier} como una revisión rutinaria del equipo.",
    }
    english = {
        "name": f"{owner} named {identifier} as the migration owner.",
        "date": f"{owner} scheduled delivery {identifier} for Friday, March 12.",
        "commitment": f"{owner} committed to deliver {identifier} before Friday.",
        "decision": f"{owner} confirmed decision {identifier}: approve the budget.",
        "risk": f"{owner} recorded risk {identifier}: the migration may duplicate events.",
        "technicalIdentifier": f"{owner} said {identifier} uses GraphQL schema v3.",
        "paraphrase": f"{owner} agreed on {identifier}: postpone the launch until April.",
        "negation": f"{owner} clarified that {identifier} must not delete historical records.",
        "notFound": f"{owner} documented {identifier} as a routine team review.",
    }
    if language == "es":
        return spanish[intent]
    if language == "en":
        return english[intent]
    return f"{spanish[intent]} Follow-up: {english[intent]}"


def query_text_for(
    relationship,
    owner,
    identifier,
    intent,
    robustness_ordinal=None,
    not_found=False,
):
    reference = (
        f"missing-{robustness_ordinal:03d}"
        if not_found and robustness_ordinal is not None
        else "missing-999"
        if not_found
        else identifier
    )
    spanish = {
        "name": f"¿Quién quedó responsable de {reference} según {owner}?",
        "date": f"¿Para qué fecha programó {owner} la entrega {reference}?",
        "commitment": f"¿Qué se comprometió a entregar {owner} para {reference}?",
        "decision": f"¿Qué decisión confirmó {owner} sobre {reference}?",
        "risk": f"¿Qué riesgo registró {owner} para {reference}?",
        "technicalIdentifier": f"¿Qué esquema técnico usa {reference} según {owner}?",
        "paraphrase": f"¿Qué se resolvió sobre el lanzamiento {reference}?",
        "negation": f"¿Qué no debe hacer {reference} según {owner}?",
        "notFound": f"¿Qué se acordó sobre {reference}?",
    }
    english = {
        "name": f"Who became responsible for {reference} according to {owner}?",
        "date": f"When did {owner} schedule delivery {reference}?",
        "commitment": f"What did {owner} commit to deliver for {reference}?",
        "decision": f"What decision did {owner} confirm for {reference}?",
        "risk": f"What risk did {owner} record for {reference}?",
        "technicalIdentifier": (
            f"Which technical schema does {reference} use according to {owner}?"
        ),
        "paraphrase": f"What was resolved about launch {reference}?",
        "negation": f"What must {reference} not do according to {owner}?",
        "notFound": f"What was agreed for {reference}?",
    }
    if relationship in {"spanishToSpanish", "spanishToEnglish"}:
        return spanish[intent]
    if relationship in {"englishToEnglish", "englishToSpanish"}:
        return english[intent]
    if relationship == "codeSwitched":
        return f"¿What acordó {owner} sobre {reference} before Friday?"
    query = spanish[intent]
    if robustness_ordinal is not None and robustness_ordinal <= 5:
        return "".join(
            character
            for character in unicodedata.normalize("NFD", query)
            if unicodedata.category(character) != "Mn"
        )
    if robustness_ordinal is not None and robustness_ordinal <= 10:
        return (
            query.replace("responsable", "resposable")
            .replace("programó", "progamó")
            .replace("comprometió", "conprometió")
            .replace("decisión", "desición")
            .replace("riesgo", "rieso")
            .replace("esquema", "esqumea")
            .replace("resolvió", "resolbió")
        )
    if robustness_ordinal is not None and robustness_ordinal <= 15:
        return query.replace(reference, f"GraphQL-v3-{reference}")
    return query


def write_public_fixture(path, generation=PUBLIC_GENERATION):
    path = Path(path).expanduser()
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("x", encoding="utf-8") as handle:
            handle.write(
                json.dumps(
                    public_fixture(generation),
                    ensure_ascii=False,
                    indent=2,
                    sort_keys=True,
                )
                + "\n"
            )
    except FileExistsError as error:
        raise AskQualityError(f"public fixture already exists: {path}") from error
    except OSError as error:
        raise AskQualityError(f"public fixture could not be written: {path}") from error


def write_owner_only(path, document):
    path = Path(path).expanduser()
    parent_existed = path.parent.exists()
    try:
        path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        if not parent_existed:
            os.chmod(path.parent, 0o700)
    except OSError as error:
        raise AskQualityError(
            f"scorecard directory could not be prepared: {path.parent}"
        ) from error
    data = (
        json.dumps(document, ensure_ascii=False, indent=2, sort_keys=True) + "\n"
    ).encode("utf-8")
    descriptor = None
    temporary = None
    try:
        descriptor, temporary_name = tempfile.mkstemp(
            prefix=f".{path.name}.", suffix=".tmp", dir=path.parent
        )
        temporary = Path(temporary_name)
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, "wb") as handle:
            descriptor = None
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.link(temporary, path)
        directory_descriptor = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(directory_descriptor)
        finally:
            os.close(directory_descriptor)
    except FileExistsError as error:
        raise AskQualityError(f"scorecard already exists: {path}") from error
    except OSError as error:
        raise AskQualityError(f"scorecard could not be published: {path}") from error
    finally:
        if descriptor is not None:
            os.close(descriptor)
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def build_parser():
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    generate = subparsers.add_parser("generate-public")
    generate.add_argument("--output", required=True)
    generate.add_argument(
        "--generation", choices=sorted(PUBLIC_GENERATIONS), default=PUBLIC_GENERATION
    )
    verify = subparsers.add_parser("verify-public")
    verify.add_argument("--fixture", required=True)
    evaluate_parser = subparsers.add_parser("evaluate")
    evaluate_parser.add_argument("--fixture", required=True)
    evaluate_parser.add_argument("--observations", required=True)
    evaluate_parser.add_argument("--output", required=True)
    compare_parser = subparsers.add_parser("compare")
    compare_parser.add_argument("--fixture", required=True)
    compare_parser.add_argument("--control", required=True)
    compare_parser.add_argument("--candidate", required=True)
    compare_parser.add_argument("--output", required=True)
    return parser


def main_from_args(arguments):
    args = build_parser().parse_args(arguments)
    if args.command == "generate-public":
        write_public_fixture(args.output, args.generation)
        return 0
    if args.command == "verify-public":
        path = Path(args.fixture).expanduser()
        actual = load_json(path, "public Ask quality fixture")
        generation = actual.get("generation") if isinstance(actual, dict) else None
        expected = public_fixture(generation)
        if actual != expected:
            raise AskQualityError("public Ask quality fixture is not canonical")
        validate_fixture(actual)
        return 0
    fixture_document = load_json(args.fixture, "Ask quality fixture")
    fixture = validate_fixture(fixture_document)
    if args.command == "compare":
        control = validate_scorecard(
            load_json(args.control, "control Ask quality scorecard"),
            "controlScorecard",
        )
        candidate = validate_scorecard(
            load_json(args.candidate, "candidate Ask quality scorecard"),
            "candidateScorecard",
        )
        receipt = compare_scorecards(fixture, control, candidate)
        write_owner_only(args.output, receipt)
        return 0 if receipt["outcome"] == "candidate-parity" else 1
    observations = validate_observations(
        load_json(args.observations, "Ask quality observations"),
        fixture,
    )
    scorecard = evaluate(fixture, observations)
    write_owner_only(args.output, scorecard)
    return 0 if scorecard["outcome"] == "pass" else 1


def main():
    try:
        return main_from_args(sys.argv[1:])
    except AskQualityError as error:
        print(f"ask-quality error: {error}", file=sys.stderr)
        return 64


if __name__ == "__main__":
    raise SystemExit(main())
