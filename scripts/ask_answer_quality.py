#!/usr/bin/env python3
"""Separately versioned Ask ANSWER judge (Q6/SEARCH-0b, D315).

Retrieval already has a fail-closed evaluator (`ask_quality.py`, schema 1/2).
Answers were explicitly unevaluated. This module judges the answer ARTIFACT —
did the pipeline answer when it should, abstain when it should, and ground
every citation in labeled evidence — deterministically and fail closed.

Deliberate limits, stated instead of hidden:

- The observation is content-free: it carries outcomes, citation identities,
  and a character count — never answer text. The same contract therefore
  serves the public synthetic fixture and a future private anonymized pack.
- Prose quality is NOT evaluated. A deterministic judge can verify grounding
  and policy, not eloquence; every scorecard says `"proseQuality":
  "notEvaluated"` so nobody can mistake a grounding pass for a quality pass.
"""

import argparse
import importlib.util
import json
import re
import sys
from pathlib import Path

_RETRIEVAL_SPEC = importlib.util.spec_from_file_location(
    "ask_quality", Path(__file__).resolve().parent / "ask_quality.py"
)
retrieval = importlib.util.module_from_spec(_RETRIEVAL_SPEC)
_RETRIEVAL_SPEC.loader.exec_module(retrieval)

ANSWER_SCHEMA_VERSION = 1
SAFE_CHECKSUM = re.compile(r"^[0-9a-f]{64}$")
OBSERVATION_KIND = "portavoz-ask-answer-observations"
SCORECARD_KIND = "portavoz-ask-answer-scorecard"
OUTCOMES = {"answered", "abstained"}
ANSWERING_MODES = {"on-device", "unavailable"}
MAXIMUM_CITATIONS = 20

AskAnswerQualityError = retrieval.AskQualityError


def validate_answer_observations(document, fixture):
    """Validates one answer-observation document against a validated fixture.

    Fail closed: every fixture query must be judged exactly once, every
    citation must name a corpus segment at most once, an abstention must be
    evidence-free, and an answer must carry evidence — an answer without a
    single citation is inadmissible, not merely low-scoring.
    """
    root = retrieval.object_shape(
        document,
        "observations",
        (
            "schemaVersion",
            "kind",
            "fixtureGeneration",
            "fixtureChecksum",
            "adapter",
            "answers",
        ),
    )
    if retrieval.integer(
        root["schemaVersion"], "observations.schemaVersion"
    ) != ANSWER_SCHEMA_VERSION:
        raise AskAnswerQualityError(
            "observations.schemaVersion must be "
            f"{ANSWER_SCHEMA_VERSION}"
        )
    if root["kind"] != OBSERVATION_KIND:
        raise AskAnswerQualityError(
            f"observations.kind must be {OBSERVATION_KIND}"
        )
    generation = retrieval.safe_string(
        root["fixtureGeneration"],
        "observations.fixtureGeneration",
        retrieval.SAFE_GENERATION,
    )
    if generation != fixture["generation"]:
        raise AskAnswerQualityError(
            "observations.fixtureGeneration does not match the fixture"
        )
    checksum = retrieval.safe_string(
        root["fixtureChecksum"],
        "observations.fixtureChecksum",
        SAFE_CHECKSUM,
    )
    if checksum != fixture["checksum"]:
        raise AskAnswerQualityError(
            "observations.fixtureChecksum does not match the fixture"
        )
    adapter = retrieval.object_shape(
        root["adapter"],
        "observations.adapter",
        ("id", "version", "answering"),
    )
    subject = {
        "adapterID": retrieval.safe_string(
            adapter["id"], "observations.adapter.id"
        ),
        "adapterVersion": retrieval.safe_string(
            adapter["version"], "observations.adapter.version"
        ),
        "answering": retrieval.enum_value(
            adapter["answering"],
            "observations.adapter.answering",
            ANSWERING_MODES,
        ),
    }

    if not isinstance(root["answers"], list) or not root["answers"]:
        raise AskAnswerQualityError(
            "observations.answers must be a nonempty array"
        )
    answers = {}
    for index, raw_answer in enumerate(root["answers"]):
        path = f"observations.answers[{index}]"
        answer = retrieval.object_shape(
            raw_answer,
            path,
            ("queryID", "outcome", "citedSegmentIDs", "answerCharacterCount"),
        )
        query_id = retrieval.safe_string(answer["queryID"], f"{path}.queryID")
        if query_id not in fixture["queries"]:
            raise AskAnswerQualityError(
                f"{path}.queryID is absent from the fixture"
            )
        if query_id in answers:
            raise AskAnswerQualityError(
                f"observations judge query {query_id} more than once"
            )
        outcome = retrieval.enum_value(
            answer["outcome"], f"{path}.outcome", OUTCOMES
        )
        cited = retrieval.string_array(
            answer["citedSegmentIDs"],
            f"{path}.citedSegmentIDs",
            maximum_count=MAXIMUM_CITATIONS,
        )
        if len(set(cited)) != len(cited):
            raise AskAnswerQualityError(f"{path} repeats a citation")
        unknown = [
            segment_id
            for segment_id in cited
            if segment_id not in fixture["segments"]
        ]
        if unknown:
            raise AskAnswerQualityError(
                f"{path} cites a segment absent from the corpus: {unknown[0]}"
            )
        if outcome == "abstained" and cited:
            raise AskAnswerQualityError(
                f"{path} abstained but still carries citations"
            )
        if outcome == "answered" and not cited:
            raise AskAnswerQualityError(
                f"{path} answered without a single citation"
            )
        character_count = retrieval.integer(
            answer["answerCharacterCount"],
            f"{path}.answerCharacterCount",
            0,
            100_000,
        )
        if outcome == "answered" and character_count == 0:
            raise AskAnswerQualityError(
                f"{path} answered with an empty answer artifact"
            )
        answers[query_id] = {
            "outcome": outcome,
            "cited": cited,
            "answerCharacterCount": character_count,
        }

    missing = sorted(set(fixture["queries"]) - set(answers))
    if missing:
        raise AskAnswerQualityError(
            f"observations never judge query {missing[0]}"
        )
    return {"subject": subject, "answers": answers}


def validate_floors(document):
    floors = retrieval.object_shape(
        document,
        "floors",
        (
            "answerOutcomeAccuracy",
            "citationPrecision",
            "evidenceRecall",
            "maximumHardNegativeCitations",
        ),
    )
    return {
        "answerOutcomeAccuracy": retrieval.number(
            floors["answerOutcomeAccuracy"],
            "floors.answerOutcomeAccuracy",
            0,
            1,
        ),
        "citationPrecision": retrieval.number(
            floors["citationPrecision"], "floors.citationPrecision", 0, 1
        ),
        "evidenceRecall": retrieval.number(
            floors["evidenceRecall"], "floors.evidenceRecall", 0, 1
        ),
        "maximumHardNegativeCitations": retrieval.integer(
            floors["maximumHardNegativeCitations"],
            "floors.maximumHardNegativeCitations",
            0,
        ),
    }


def judge(fixture, observation_document, floors=None):
    """One deterministic scorecard for one answer-observation document."""
    validated = validate_answer_observations(observation_document, fixture)
    answers = validated["answers"]

    outcome_matches = []
    precisions = []
    recalls = []
    false_answers = 0
    missed_answers = 0
    hard_negative_citations = 0
    answered_count = 0
    for query_id, query in fixture["queries"].items():
        answer = answers[query_id]
        should_answer = query["answerPolicy"] == "answer"
        answered = answer["outcome"] == "answered"
        outcome_matches.append(1.0 if answered == should_answer else 0.0)
        if answered:
            answered_count += 1
            cited = answer["cited"]
            grounded = [
                segment_id
                for segment_id in cited
                if segment_id in query["relevant"]
            ]
            precisions.append(len(grounded) / len(cited))
            hard_negative_citations += sum(
                1
                for segment_id in cited
                if segment_id in query["hardNegatives"]
            )
            if not should_answer:
                false_answers += 1
        elif should_answer:
            missed_answers += 1
        if should_answer:
            recalls.append(
                len(
                    [
                        segment_id
                        for segment_id in answer["cited"]
                        if segment_id in query["relevant"]
                    ]
                )
                / len(query["relevant"])
            )

    metrics = {
        "answerOutcomeAccuracy": retrieval.average(outcome_matches),
        "citationPrecision": retrieval.average(precisions),
        "evidenceRecall": retrieval.average(recalls),
        "falseAnswerCount": false_answers,
        "missedAnswerCount": missed_answers,
        "hardNegativeCitationCount": hard_negative_citations,
    }
    scorecard = {
        "schemaVersion": ANSWER_SCHEMA_VERSION,
        "kind": SCORECARD_KIND,
        "fixture": {
            "generation": fixture["generation"],
            "contentSource": fixture["contentSource"],
            "checksum": fixture["checksum"],
            "queryCount": len(fixture["queries"]),
        },
        "subject": validated["subject"],
        "counts": {
            "answered": answered_count,
            "abstained": len(answers) - answered_count,
        },
        "metrics": metrics,
        "proseQuality": "notEvaluated",
    }
    if floors is not None:
        scorecard["gates"] = {
            "floors": floors,
            "floorsMet": (
                metrics["answerOutcomeAccuracy"]
                >= floors["answerOutcomeAccuracy"]
                and metrics["citationPrecision"] >= floors["citationPrecision"]
                and metrics["evidenceRecall"] >= floors["evidenceRecall"]
                and metrics["hardNegativeCitationCount"]
                <= floors["maximumHardNegativeCitations"]
            ),
        }
    return scorecard


def load_fixture(path):
    return retrieval.validate_fixture(
        retrieval.load_json(path, "fixture"), exact_distribution=False
    )


def main_from_args(arguments):
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    validate = subparsers.add_parser("validate")
    validate.add_argument("--fixture", required=True)
    validate.add_argument("--observations", required=True)

    evaluate = subparsers.add_parser("evaluate")
    evaluate.add_argument("--fixture", required=True)
    evaluate.add_argument("--observations", required=True)
    evaluate.add_argument("--floors")
    evaluate.add_argument("--output")

    options = parser.parse_args(arguments)
    fixture = load_fixture(options.fixture)
    observations = retrieval.load_json(options.observations, "observations")
    if options.command == "validate":
        validate_answer_observations(observations, fixture)
        print("answer observations are valid")
        return 0
    floors = None
    if options.floors:
        floors = validate_floors(retrieval.load_json(options.floors, "floors"))
    scorecard = judge(fixture, observations, floors=floors)
    payload = json.dumps(scorecard, indent=2, sort_keys=True)
    if options.output:
        Path(options.output).write_text(payload + "\n", encoding="utf-8")
    else:
        print(payload)
    return 0


def main():
    try:
        return main_from_args(sys.argv[1:])
    except AskAnswerQualityError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
