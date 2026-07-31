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
FIXTURE_KIND = "ask-quality-fixture"
OBSERVATION_KIND = "ask-quality-observations"
SCORECARD_KIND = "ask-quality-scorecard"
PUBLIC_GENERATION = "public-synthetic-v1"
PUBLIC_SOURCE = "public-synthetic-only"
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
SAFE_ID = re.compile(r"^[a-z0-9][a-z0-9._-]{0,79}$")
SAFE_GENERATION = re.compile(r"^[a-z0-9][a-z0-9-]{0,39}$")
SAFE_BUILD = re.compile(r"^[A-Za-z0-9._+-]{1,80}$")
COMMIT = re.compile(r"^[0-9a-f]{40}$")


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
    if fixture["contentSource"] == PUBLIC_SOURCE and fixture != public_fixture():
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
    if integer(root["schemaVersion"], "observations.schemaVersion") != SCHEMA_VERSION:
        raise AskQualityError("observations.schemaVersion must be 1")
    if root["kind"] != OBSERVATION_KIND:
        raise AskQualityError(f"observations.kind must be {OBSERVATION_KIND}")
    if root["fixtureGeneration"] != fixture["generation"]:
        raise AskQualityError("observations.fixtureGeneration does not match fixture")
    subject = {
        "adapter": safe_string(root["adapter"], "observations.adapter"),
        "build": safe_string(root["build"], "observations.build", SAFE_BUILD),
        "commit": safe_string(root["commit"], "observations.commit", COMMIT),
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
        seen_hits = set()
        for hit_index, raw_hit in enumerate(observation["hits"]):
            hit_path = f"{path}.hits[{hit_index}]"
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
            segment_id = safe_string(hit["segmentID"], f"{hit_path}.segmentID")
            if segment_id in seen_hits:
                raise AskQualityError(f"{path}.hits repeat segment: {segment_id}")
            seen_hits.add(segment_id)
            hits.append(
                {
                    "segmentID": segment_id,
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
    valid_hits = []
    invalid_hits = 0
    stale_hits = 0
    for hit in observation["hits"]:
        canonical = segments.get(hit["segmentID"])
        if canonical is None:
            invalid_hits += 1
            continue
        if (
            hit["meetingID"] != canonical["meetingID"]
            or hit["timestampMilliseconds"] != canonical["timestampMilliseconds"]
            or hit["transcriptRevision"] != canonical["transcriptRevision"]
        ):
            stale_hits += 1
            continue
        valid_hits.append(hit["segmentID"])
    grades = [query["relevant"].get(segment_id, 0) for segment_id in valid_hits]
    relevant_ranks = [index + 1 for index, grade in enumerate(grades) if grade > 0]
    answerable = query["answerPolicy"] == "answer"
    expected_outcome = "answered" if answerable else "abstained"
    answer = observation["answer"]
    return {
        "relationship": query["relationship"],
        "intent": query["intent"],
        "answerable": answerable,
        "hitAt1": bool(grades and grades[0] > 0) if answerable else None,
        "recallAt10": (
            len(set(valid_hits).intersection(query["relevant"]))
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
        "hardNegativeHits": len(set(valid_hits).intersection(query["hardNegatives"])),
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


def public_fixture():
    relationships = [
        relationship
        for relationship, count in RELATIONSHIP_COUNTS.items()
        for _ in range(count)
    ]
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
        owner = owners[index % len(owners)]
        intent = intents[index % len(intents)]
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
        hard_negative = f"segment-{((index + 1) % len(relationships)) + 1:03d}"
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
        "generation": PUBLIC_GENERATION,
        "contentSource": PUBLIC_SOURCE,
        "segments": segments,
        "queries": queries,
    }


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


def write_public_fixture(path):
    path = Path(path).expanduser()
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("x", encoding="utf-8") as handle:
            handle.write(
                json.dumps(
                    public_fixture(),
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
    verify = subparsers.add_parser("verify-public")
    verify.add_argument("--fixture", required=True)
    evaluate_parser = subparsers.add_parser("evaluate")
    evaluate_parser.add_argument("--fixture", required=True)
    evaluate_parser.add_argument("--observations", required=True)
    evaluate_parser.add_argument("--output", required=True)
    return parser


def main_from_args(arguments):
    args = build_parser().parse_args(arguments)
    if args.command == "generate-public":
        write_public_fixture(args.output)
        return 0
    if args.command == "verify-public":
        path = Path(args.fixture).expanduser()
        actual = load_json(path, "public Ask quality fixture")
        expected = public_fixture()
        if actual != expected:
            raise AskQualityError("public Ask quality fixture is not canonical")
        validate_fixture(actual)
        return 0
    fixture_document = load_json(args.fixture, "Ask quality fixture")
    fixture = validate_fixture(fixture_document)
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
