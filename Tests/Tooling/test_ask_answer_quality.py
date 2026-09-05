import copy
import importlib.util
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
ANSWER_SPEC = importlib.util.spec_from_file_location(
    "ask_answer_quality", ROOT / "scripts" / "ask_answer_quality.py"
)
answer_quality = importlib.util.module_from_spec(ANSWER_SPEC)
ANSWER_SPEC.loader.exec_module(answer_quality)
retrieval = answer_quality.retrieval


def public_fixture():
    return retrieval.validate_fixture(retrieval.public_fixture())


def honest_observations(fixture):
    """One answer per query that follows the fixture's own labels exactly."""
    answers = []
    for query_id, query in fixture["queries"].items():
        if query["answerPolicy"] == "answer":
            answers.append(
                {
                    "queryID": query_id,
                    "outcome": "answered",
                    "citedSegmentIDs": sorted(query["relevant"]),
                    "answerCharacterCount": 120,
                }
            )
        else:
            answers.append(
                {
                    "queryID": query_id,
                    "outcome": "abstained",
                    "citedSegmentIDs": [],
                    "answerCharacterCount": 0,
                }
            )
    return {
        "schemaVersion": answer_quality.ANSWER_SCHEMA_VERSION,
        "kind": answer_quality.OBSERVATION_KIND,
        "fixtureGeneration": fixture["generation"],
        "fixtureChecksum": fixture["checksum"],
        "adapter": {
            "id": "test-adapter",
            "version": "1.0.0",
            "answering": "on-device",
        },
        "answers": answers,
    }


class AskAnswerQualityTests(unittest.TestCase):
    def test_honest_observations_score_perfectly_and_disclose_prose_limits(self):
        fixture = public_fixture()
        scorecard = answer_quality.judge(fixture, honest_observations(fixture))

        self.assertEqual(scorecard["metrics"]["answerOutcomeAccuracy"], 1.0)
        self.assertEqual(scorecard["metrics"]["citationPrecision"], 1.0)
        self.assertEqual(scorecard["metrics"]["evidenceRecall"], 1.0)
        self.assertEqual(scorecard["metrics"]["falseAnswerCount"], 0)
        self.assertEqual(scorecard["metrics"]["missedAnswerCount"], 0)
        self.assertEqual(scorecard["metrics"]["hardNegativeCitationCount"], 0)
        self.assertEqual(scorecard["proseQuality"], "notEvaluated")
        self.assertEqual(scorecard["kind"], answer_quality.SCORECARD_KIND)
        self.assertEqual(
            scorecard["fixture"]["checksum"], fixture["checksum"]
        )
        self.assertEqual(
            scorecard["counts"]["answered"] + scorecard["counts"]["abstained"],
            len(fixture["queries"]),
        )

    def test_hallucinated_answer_on_an_abstention_query_is_measured(self):
        fixture = public_fixture()
        observations = honest_observations(fixture)
        abstention_query = next(
            query_id
            for query_id, query in fixture["queries"].items()
            if query["answerPolicy"] == "abstain" and query["hardNegatives"]
        )
        hard_negative = sorted(
            fixture["queries"][abstention_query]["hardNegatives"]
        )[0]
        for answer in observations["answers"]:
            if answer["queryID"] == abstention_query:
                answer["outcome"] = "answered"
                answer["citedSegmentIDs"] = [hard_negative]
                answer["answerCharacterCount"] = 80

        scorecard = answer_quality.judge(fixture, observations)

        self.assertEqual(scorecard["metrics"]["falseAnswerCount"], 1)
        self.assertEqual(scorecard["metrics"]["hardNegativeCitationCount"], 1)
        self.assertLess(scorecard["metrics"]["answerOutcomeAccuracy"], 1.0)
        self.assertLess(scorecard["metrics"]["citationPrecision"], 1.0)

    def test_missed_answer_lowers_recall_without_breaking_validation(self):
        fixture = public_fixture()
        observations = honest_observations(fixture)
        answerable_query = next(
            query_id
            for query_id, query in fixture["queries"].items()
            if query["answerPolicy"] == "answer"
        )
        for answer in observations["answers"]:
            if answer["queryID"] == answerable_query:
                answer["outcome"] = "abstained"
                answer["citedSegmentIDs"] = []
                answer["answerCharacterCount"] = 0

        scorecard = answer_quality.judge(fixture, observations)

        self.assertEqual(scorecard["metrics"]["missedAnswerCount"], 1)
        self.assertLess(scorecard["metrics"]["evidenceRecall"], 1.0)

    def test_floors_gate_states_its_verdict(self):
        fixture = public_fixture()
        floors = {
            "answerOutcomeAccuracy": 1.0,
            "citationPrecision": 1.0,
            "evidenceRecall": 1.0,
            "maximumHardNegativeCitations": 0,
        }
        passing = answer_quality.judge(
            fixture,
            honest_observations(fixture),
            floors=answer_quality.validate_floors(floors),
        )
        self.assertTrue(passing["gates"]["floorsMet"])

        observations = honest_observations(fixture)
        answerable_query = next(
            query_id
            for query_id, query in fixture["queries"].items()
            if query["answerPolicy"] == "answer"
        )
        for answer in observations["answers"]:
            if answer["queryID"] == answerable_query:
                answer["outcome"] = "abstained"
                answer["citedSegmentIDs"] = []
                answer["answerCharacterCount"] = 0
        failing = answer_quality.judge(
            fixture,
            observations,
            floors=answer_quality.validate_floors(floors),
        )
        self.assertFalse(failing["gates"]["floorsMet"])

    def test_malformed_observations_fail_closed(self):
        fixture = public_fixture()
        base = honest_observations(fixture)

        missing = copy.deepcopy(base)
        missing["answers"].pop()
        with self.assertRaisesRegex(
            answer_quality.AskAnswerQualityError, "never judge"
        ):
            answer_quality.validate_answer_observations(missing, fixture)

        duplicated = copy.deepcopy(base)
        duplicated["answers"].append(copy.deepcopy(duplicated["answers"][0]))
        with self.assertRaisesRegex(
            answer_quality.AskAnswerQualityError, "more than once"
        ):
            answer_quality.validate_answer_observations(duplicated, fixture)

        unknown_citation = copy.deepcopy(base)
        answered = next(
            answer
            for answer in unknown_citation["answers"]
            if answer["outcome"] == "answered"
        )
        answered["citedSegmentIDs"] = ["ghost-segment"]
        with self.assertRaisesRegex(
            answer_quality.AskAnswerQualityError, "absent from the corpus"
        ):
            answer_quality.validate_answer_observations(
                unknown_citation, fixture
            )

        cited_abstention = copy.deepcopy(base)
        abstained = next(
            answer
            for answer in cited_abstention["answers"]
            if answer["outcome"] == "abstained"
        )
        abstained["citedSegmentIDs"] = [
            sorted(fixture["segments"])[0]
        ]
        with self.assertRaisesRegex(
            answer_quality.AskAnswerQualityError, "abstained but still"
        ):
            answer_quality.validate_answer_observations(
                cited_abstention, fixture
            )

        evidence_free = copy.deepcopy(base)
        answered = next(
            answer
            for answer in evidence_free["answers"]
            if answer["outcome"] == "answered"
        )
        answered["citedSegmentIDs"] = []
        with self.assertRaisesRegex(
            answer_quality.AskAnswerQualityError, "without a single citation"
        ):
            answer_quality.validate_answer_observations(evidence_free, fixture)

        stale = copy.deepcopy(base)
        stale["fixtureChecksum"] = "0" * 64
        with self.assertRaisesRegex(
            answer_quality.AskAnswerQualityError, "does not match the fixture"
        ):
            answer_quality.validate_answer_observations(stale, fixture)

    def test_answer_text_never_enters_the_observation_contract(self):
        fixture = public_fixture()
        smuggled = honest_observations(fixture)
        smuggled["answers"][0]["answerText"] = "leaked meeting content"
        with self.assertRaisesRegex(
            answer_quality.AskAnswerQualityError, "forbidden keys"
        ):
            answer_quality.validate_answer_observations(smuggled, fixture)


if __name__ == "__main__":
    unittest.main()
