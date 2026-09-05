#!/usr/bin/env python3
"""Validate non-serving retrieval-stage evidence; never approve a model or route."""

from __future__ import annotations

import argparse
import copy
import hashlib
import re
import sys
from pathlib import Path

import ask_quality as quality


PROFILE_KEYS = (
    "modelIdentifier", "modelRevision", "vectorDimension", "pipelineIdentifier",
    "pipelineRevision", "vectorSchemaVersion",
)
COUNT_KEYS = (
    "requestedTexts", "returnedVectors", "nonzeroFiniteVectors", "zeroVectors", "malformedVectors",
)
CORPUS_KEYS = (
    "profile", "profileFingerprint", "projectedUnitCount", "embeddedRows", "excludedRows",
    "skippedRows", "invalidatedRows", "pendingRowsRemain", "pausedByPolicy", "embeddingResults",
)


def require(condition, label):
    if not condition:
        raise quality.AskQualityError(label)


def profile_fingerprint(profile):
    parts = ["semantic-embedding-profile-v1"] + [str(profile[key]) for key in PROFILE_KEYS]
    value = "|".join(f"{len(part.encode('utf-8'))}:{part}" for part in parts)
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def validate_counts(value, maximum):
    quality.object_shape(value, "vector counts", COUNT_KEYS)
    for key in COUNT_KEYS:
        quality.integer(value[key], f"vector counts.{key}", 0, maximum)
    require(value["returnedVectors"] == sum(value[key] for key in COUNT_KEYS[2:]),
            "vector classes must partition returned vectors")
    return value


def validate_corpus(corpus, fixture):
    quality.object_shape(corpus, "corpus", CORPUS_KEYS)
    profile = quality.object_shape(corpus["profile"], "profile", PROFILE_KEYS)
    for key in ("modelIdentifier", "pipelineIdentifier"):
        quality.safe_string(profile[key], f"profile.{key}", re.compile(r"[A-Za-z0-9._-]{1,256}"))
    for key in PROFILE_KEYS:
        if key not in ("modelIdentifier", "pipelineIdentifier"):
            quality.integer(profile[key], f"profile.{key}", 0 if key == "modelRevision" else 1,
                            1_000_000)
    require(corpus["profileFingerprint"] == profile_fingerprint(profile), "profile fingerprint mismatch")
    for key in ("projectedUnitCount", "embeddedRows", "excludedRows", "skippedRows", "invalidatedRows"):
        quality.integer(corpus[key], f"corpus.{key}", 0, len(fixture["segments"]))
    require(corpus["projectedUnitCount"] > 0, "nonempty fixture must project at least one unit")
    for key in ("pendingRowsRemain", "pausedByPolicy"):
        require(corpus[key] is False, "corpus must be completely prepared")
    require(corpus["skippedRows"] == corpus["invalidatedRows"] == 0, "corpus cannot skip or invalidate rows")
    require(corpus["embeddedRows"] + corpus["excludedRows"] == corpus["projectedUnitCount"],
            "corpus rows do not conserve projected units")
    counts = validate_counts(corpus["embeddingResults"], len(fixture["segments"]))
    require(counts["requestedTexts"] == counts["returnedVectors"] == corpus["embeddedRows"],
            "embedding results do not cover published rows")
    # Published zero vectors are counted, never mislabeled as useful semantic coverage.
    require(counts["malformedVectors"] == 0, "malformed embedding results cannot qualify a diagnostic")


def checked_hits(hits, maximum, query_id, observation, fixture):
    require(isinstance(hits, list) and len(hits) <= maximum, "stage candidate count is invalid")
    units, sources = set(), set()
    for offset in range(0, max(1, len(hits)), 10):
        # Reuse the canonical exact-shape, duplicate and revision validators;
        # only split validation, never reorder or truncate the raw candidate list.
        sample = dict(observation, queries=[dict(
            queryID=query_id, hits=hits[offset:offset + 10],
            answer=dict(outcome="notEvaluated", factuality=None, citationCoverage=None, unsupportedClaims=0))])
        sample_fixture = dict(fixture, queries={query_id: fixture["queries"][query_id]})
        validated = quality.validate_observations(sample, sample_fixture)["queries"][query_id]
        score = quality.query_score(fixture["queries"][query_id], validated, fixture["segments"])
        require(score["invalidHits"] == score["staleHits"] == 0, "stage citation is not current canonical evidence")
        for hit in validated["hits"]:
            require(hit["unitID"] not in units, "stage repeats unit")
            require(not sources.intersection(hit["sourceSegmentIDs"]), "stage repeats source")
            units.add(hit["unitID"])
            sources.update(hit["sourceSegmentIDs"])
    return hits


def validate(document, fixture):
    quality.object_shape(document, "attribution", (
        "schemaVersion", "kind", "outcome", "observation", "corpus", "stages"))
    require(type(document["schemaVersion"]) is int and document["schemaVersion"] == 1,
            "attribution schema must be 1")
    require(document["kind"] == "ask-quality-attribution" and document["outcome"] == "diagnostic-only",
            "attribution is diagnostic only")
    observation = document["observation"]
    require(isinstance(observation, dict) and observation.get("schemaVersion") == 2,
            "attribution requires canonical schema 2")
    validated = quality.validate_observations(observation, fixture)
    validate_corpus(document["corpus"], fixture)
    require(isinstance(document["stages"], list), "stages must be an array")
    require(len(document["stages"]) == len(observation["queries"]), "incomplete stages")
    for stage, query in zip(document["stages"], observation["queries"]):
        quality.object_shape(stage, "stage", ("queryID", "lexical", "semanticRequests"))
        require(stage["queryID"] == query["queryID"], "stage order does not match canonical queries")
        require(query["answer"]["outcome"] == "notEvaluated", "attribution never evaluates generated answers")
        checked_hits(query["hits"], 10, query["queryID"], observation, fixture)
        checked_hits(stage["lexical"], 10, query["queryID"], observation, fixture)
        requests = stage["semanticRequests"]
        # No generative expansion: one original deterministic batch at most.
        require(isinstance(requests, list) and len(requests) <= 1, "unexpected semantic batch count")
        for request in requests:
            validate_request(request, query["queryID"], document, fixture)
    return validated


def validate_request(request, query_id, document, fixture):
    quality.object_shape(request, "semantic request", (
        "outcome", "profileFingerprint", "candidateLimit", "queryVectors", "variants"))
    require(request["outcome"] in ("succeeded", "failed"), "invalid semantic outcome")
    require(request["profileFingerprint"] == document["corpus"]["profileFingerprint"], "semantic profile drift")
    require(type(request["candidateLimit"]) is int and request["candidateLimit"] == 12,
            "expected production Library candidate limit")
    counts = validate_counts(request["queryVectors"], 12)
    require(0 < counts["returnedVectors"] == counts["requestedTexts"], "incomplete semantic query vectors")
    variants = request["variants"]
    require(isinstance(variants, list), "variants must be an array")
    require(len(variants) == (counts["returnedVectors"] if request["outcome"] == "succeeded" else 0),
            "variant count does not match semantic outcome")
    for hits in variants:
        checked_hits(hits, request["candidateLimit"], query_id, document["observation"], fixture)


def summarize(fixture, document):
    canonical = validate(document, fixture)
    lexical = copy.deepcopy(canonical)
    semantic_scores = []
    outcomes = dict(notInvoked=0, failed=0, succeeded=0)
    for stage in document["stages"]:
        query_id = stage["queryID"]
        lexical["queries"][query_id]["hits"] = stage["lexical"]
        requests = stage["semanticRequests"]
        if not requests:
            outcomes["notInvoked"] += 1
            continue
        request = requests[0]
        outcomes[request["outcome"]] += 1
        if request["outcome"] == "succeeded":
            # Variant 0 is the original question. Do not invent a merged ranking.
            original = dict(canonical["queries"][query_id], hits=request["variants"][0][:10])
            semantic_scores.append(quality.query_score(fixture["queries"][query_id], original, fixture["segments"]))
    stages = {}
    for name, observations in (("lexical", lexical), ("fused", canonical)):
        scorecard = quality.evaluate(fixture, observations)
        stages[name] = {key: scorecard[key] for key in ("overall", "slices")}
    stages["successfulOriginalSemanticTop10"] = {
        "overall": quality.aggregate(semantic_scores),
        "slices": {relationship: quality.aggregate([
            score for score in semantic_scores if score["relationship"] == relationship
        ]) for relationship in quality.RELATIONSHIP_COUNTS},
    }
    return dict(schemaVersion=1, kind="ask-quality-attribution-summary", outcome="diagnostic-only",
                subject=canonical["subject"], fixtureChecksum=fixture["checksum"],
                corpus=document["corpus"], semanticOutcomes=outcomes, stages=stages)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fixture", required=True, type=Path)
    parser.add_argument("--observations", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    arguments = parser.parse_args()
    try:
        require(arguments.output.resolve() not in (
            arguments.fixture.resolve(), arguments.observations.resolve()), "output would overwrite input")
        fixture = quality.validate_fixture(quality.load_json(arguments.fixture, "fixture"))
        document = quality.load_json(arguments.observations, "attribution", maximum_bytes=64 * 1024 * 1024)
        quality.write_owner_only(arguments.output, summarize(fixture, document))
    except (quality.AskQualityError, OSError, TypeError, KeyError, AttributeError):
        # No untrusted JSON keys, paths or provider payloads on stderr.
        print("Ask attribution validation failed; no qualification granted.", file=sys.stderr)
        return 2
    print("Ask attribution summarized; diagnostic only, no serving approval.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
