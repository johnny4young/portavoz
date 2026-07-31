import copy
import importlib.util
import json
import os
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "ask_quality", ROOT / "scripts" / "ask_quality.py"
)
quality = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(quality)


class AskQualityTests(unittest.TestCase):
    def test_public_fixture_is_deterministic_and_has_the_exact_distribution(self):
        first = quality.public_fixture()
        second = quality.public_fixture()

        self.assertEqual(first, second)
        validated = quality.validate_fixture(first)
        self.assertEqual(len(validated["queries"]), 240)
        self.assertEqual(
            validated["relationshipCounts"], quality.RELATIONSHIP_COUNTS
        )
        self.assertEqual(len(validated["checksum"]), 64)
        self.assertEqual(validated["contentSource"], "public-synthetic-only")

    def test_robustness_cases_isolate_spanish_spelling_and_identifier_noise(self):
        fixture = quality.public_fixture()
        segments = {segment["id"]: segment for segment in fixture["segments"]}
        queries = [
            query
            for query in fixture["queries"]
            if query["relationship"] == "robustness"
        ]

        self.assertEqual(len(queries), 20)
        for query in queries[:15]:
            segment_id = query["relevant"][0]["segmentID"]
            self.assertEqual(segments[segment_id]["language"], "es")
        for expected_typo, query in zip(
            ["progamó", "conprometió", "desición", "rieso", "esqumea"],
            queries[5:10],
        ):
            self.assertIn(expected_typo, query["text"])
        self.assertTrue(
            all("GraphQL-v3-atlas" in query["text"] for query in queries[10:15])
        )
        self.assertTrue(
            all(query["answerPolicy"] == "abstain" for query in queries[15:])
        )

    def test_public_fixture_verifier_rejects_drift(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = Path(directory) / "fixture.json"
            fixture.write_text(json.dumps(quality.public_fixture()))
            document = json.loads(fixture.read_text())
            document["queries"][0]["text"] = "drift"
            fixture.write_text(json.dumps(document))

            with self.assertRaisesRegex(
                quality.AskQualityError, "is not canonical"
            ):
                quality.main_from_args(
                    ["verify-public", "--fixture", str(fixture)]
                )

    def test_evaluator_rejects_a_modified_public_fixture(self):
        fixture = quality.public_fixture()
        fixture["queries"][0]["text"] = "synthetic but not canonical"

        with self.assertRaisesRegex(
            quality.AskQualityError, "public Ask quality fixture is not canonical"
        ):
            quality.validate_fixture(fixture)

    def test_fixture_rejects_incomplete_language_distribution(self):
        fixture = quality.public_fixture()
        fixture["queries"].pop()

        with self.assertRaisesRegex(
            quality.AskQualityError, "distribution must be exactly"
        ):
            quality.validate_fixture(fixture)

    def test_fixture_rejects_labels_that_do_not_match_canonical_evidence(self):
        fixture = quality.public_fixture()
        fixture["queries"][0]["relevant"][0][
            "expectedTimestampMilliseconds"
        ] += 1

        with self.assertRaisesRegex(
            quality.AskQualityError, "does not match canonical corpus evidence"
        ):
            quality.validate_fixture(fixture)

    def test_fixture_rejects_duplicate_json_keys(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "duplicate.json"
            path.write_text('{"schemaVersion": 1, "schemaVersion": 1}')

            with self.assertRaisesRegex(
                quality.AskQualityError, "duplicate key: schemaVersion"
            ):
                quality.load_json(path, "fixture")

    def test_perfect_observations_pass_without_copying_payloads_to_scorecard(self):
        fixture_document = quality.public_fixture()
        fixture = quality.validate_fixture(fixture_document)
        observations = quality.validate_observations(
            self.perfect_observations(fixture_document), fixture
        )

        scorecard = quality.evaluate(fixture, observations)
        encoded = json.dumps(scorecard, sort_keys=True)

        self.assertEqual(scorecard["outcome"], "pass")
        self.assertEqual(scorecard["overall"]["hitAt1"], 1)
        self.assertEqual(scorecard["overall"]["ndcgAt10"], 1)
        self.assertTrue(all(scorecard["gates"].values()))
        self.assertEqual(
            scorecard["subject"]["adapter"], "accelerate-exact-control"
        )
        self.assertNotIn('"text"', encoded)
        self.assertNotIn('"queryID"', encoded)
        self.assertNotIn("Mara", encoded)

    def test_exact_fact_missing_rank_one_blocks(self):
        fixture_document = quality.public_fixture()
        fixture = quality.validate_fixture(fixture_document)
        observations = self.perfect_observations(fixture_document)
        observations["queries"][0]["hits"] = []

        scorecard = quality.evaluate(
            fixture, quality.validate_observations(observations, fixture)
        )

        self.assertEqual(scorecard["outcome"], "blocked")
        self.assertFalse(scorecard["gates"]["exactFactsRankFirst"])

    def test_paraphrase_failures_block_the_retrieval_quality_floor(self):
        fixture_document = quality.public_fixture()
        fixture = quality.validate_fixture(fixture_document)
        observations = self.perfect_observations(fixture_document)
        query_by_id = {query["id"]: query for query in fixture_document["queries"]}
        for observation in observations["queries"]:
            if query_by_id[observation["queryID"]]["intent"] == "paraphrase":
                observation["hits"] = []

        scorecard = quality.evaluate(
            fixture, quality.validate_observations(observations, fixture)
        )

        self.assertEqual(scorecard["outcome"], "blocked")
        self.assertTrue(scorecard["gates"]["exactFactsRankFirst"])
        self.assertFalse(scorecard["gates"]["retrievalQualityFloor"])
        self.assertFalse(scorecard["gates"]["relationshipQualityFloor"])

    def test_low_factuality_blocks_the_answer_quality_floor(self):
        fixture_document = quality.public_fixture()
        fixture = quality.validate_fixture(fixture_document)
        observations = self.perfect_observations(fixture_document)
        for observation in observations["queries"]:
            if observation["answer"]["outcome"] == "answered":
                observation["answer"]["factuality"] = 0.5

        scorecard = quality.evaluate(
            fixture, quality.validate_observations(observations, fixture)
        )

        self.assertEqual(scorecard["outcome"], "blocked")
        self.assertFalse(scorecard["gates"]["answerQualityFloor"])
        self.assertFalse(scorecard["gates"]["relationshipQualityFloor"])

    def test_unknown_and_stale_citations_block_separately(self):
        fixture_document = quality.public_fixture()
        fixture = quality.validate_fixture(fixture_document)
        observations = self.perfect_observations(fixture_document)
        observations["queries"][0]["hits"][0]["segmentID"] = "unknown-segment"
        observations["queries"][1]["hits"][0]["transcriptRevision"] = 2

        scorecard = quality.evaluate(
            fixture, quality.validate_observations(observations, fixture)
        )

        self.assertEqual(scorecard["outcome"], "blocked")
        self.assertEqual(scorecard["overall"]["invalidCitationHits"], 1)
        self.assertEqual(scorecard["overall"]["staleCitationHits"], 1)
        self.assertFalse(scorecard["gates"]["citationsCanonical"])

    def test_hard_negative_in_top_ten_blocks(self):
        fixture_document = quality.public_fixture()
        fixture = quality.validate_fixture(fixture_document)
        observations = self.perfect_observations(fixture_document)
        hard_negative = fixture_document["queries"][0][
            "hardNegativeSegmentIDs"
        ][0]
        segment = next(
            item
            for item in fixture_document["segments"]
            if item["id"] == hard_negative
        )
        observations["queries"][0]["hits"].append(self.hit(segment))

        scorecard = quality.evaluate(
            fixture, quality.validate_observations(observations, fixture)
        )

        self.assertEqual(scorecard["outcome"], "blocked")
        self.assertEqual(scorecard["overall"]["hardNegativeHits"], 1)
        self.assertFalse(scorecard["gates"]["hardNegativesExcluded"])

    def test_wrong_abstention_and_unsupported_claims_block(self):
        fixture_document = quality.public_fixture()
        fixture = quality.validate_fixture(fixture_document)
        observations = self.perfect_observations(fixture_document)
        abstention = next(
            item
            for item in observations["queries"]
            if item["answer"]["outcome"] == "abstained"
        )
        abstention["answer"]["outcome"] = "answered"
        observations["queries"][0]["answer"]["unsupportedClaims"] = 1

        scorecard = quality.evaluate(
            fixture, quality.validate_observations(observations, fixture)
        )

        self.assertEqual(scorecard["outcome"], "blocked")
        self.assertFalse(scorecard["gates"]["answerPolicyHonored"])
        self.assertFalse(scorecard["gates"]["noUnsupportedClaims"])

    def test_observations_must_cover_every_query_exactly_once(self):
        fixture_document = quality.public_fixture()
        fixture = quality.validate_fixture(fixture_document)
        observations = self.perfect_observations(fixture_document)
        observations["queries"].pop()

        with self.assertRaisesRegex(
            quality.AskQualityError, "observations are incomplete"
        ):
            quality.validate_observations(observations, fixture)

    def test_observations_reject_duplicate_hits_and_payload_fields(self):
        fixture_document = quality.public_fixture()
        fixture = quality.validate_fixture(fixture_document)
        duplicate = self.perfect_observations(fixture_document)
        duplicate["queries"][0]["hits"].append(
            copy.deepcopy(duplicate["queries"][0]["hits"][0])
        )
        with self.assertRaisesRegex(
            quality.AskQualityError, "hits repeat segment"
        ):
            quality.validate_observations(duplicate, fixture)

        payload = self.perfect_observations(fixture_document)
        payload["queries"][0]["answer"]["generatedText"] = "private"
        with self.assertRaisesRegex(
            quality.AskQualityError, "forbidden keys: generatedText"
        ):
            quality.validate_observations(payload, fixture)

    def test_scorecard_is_owner_only_and_never_overwritten(self):
        fixture_document = quality.public_fixture()
        observation_document = self.perfect_observations(fixture_document)
        with tempfile.TemporaryDirectory() as directory:
            fixture_path = Path(directory) / "fixture.json"
            observations_path = Path(directory) / "observations.json"
            output = Path(directory) / "private" / "scorecard.json"
            fixture_path.write_text(json.dumps(fixture_document))
            observations_path.write_text(json.dumps(observation_document))

            result = quality.main_from_args(
                [
                    "evaluate",
                    "--fixture",
                    str(fixture_path),
                    "--observations",
                    str(observations_path),
                    "--output",
                    str(output),
                ]
            )

            self.assertEqual(result, 0)
            self.assertEqual(os.stat(output).st_mode & 0o777, 0o600)
            with self.assertRaisesRegex(
                quality.AskQualityError, "scorecard already exists"
            ):
                quality.main_from_args(
                    [
                        "evaluate",
                        "--fixture",
                        str(fixture_path),
                        "--observations",
                        str(observations_path),
                        "--output",
                        str(output),
                    ]
                )

    def test_blocked_scorecard_returns_a_failing_exit_status(self):
        fixture_document = quality.public_fixture()
        observation_document = self.perfect_observations(fixture_document)
        observation_document["queries"][0]["hits"] = []
        with tempfile.TemporaryDirectory() as directory:
            fixture_path = Path(directory) / "fixture.json"
            observations_path = Path(directory) / "observations.json"
            output = Path(directory) / "scorecard.json"
            fixture_path.write_text(json.dumps(fixture_document))
            observations_path.write_text(json.dumps(observation_document))

            result = quality.main_from_args(
                [
                    "evaluate",
                    "--fixture",
                    str(fixture_path),
                    "--observations",
                    str(observations_path),
                    "--output",
                    str(output),
                ]
            )

            self.assertEqual(result, 1)
            self.assertEqual(json.loads(output.read_text())["outcome"], "blocked")

    def test_scorecard_does_not_change_existing_parent_permissions(self):
        fixture_document = quality.public_fixture()
        fixture = quality.validate_fixture(fixture_document)
        observations = quality.validate_observations(
            self.perfect_observations(fixture_document), fixture
        )
        with tempfile.TemporaryDirectory() as directory:
            shared_directory = Path(directory) / "shared"
            shared_directory.mkdir(mode=0o755)
            os.chmod(shared_directory, 0o755)
            output = shared_directory / "scorecard.json"

            quality.write_owner_only(
                output, quality.evaluate(fixture, observations)
            )

            self.assertEqual(os.stat(shared_directory).st_mode & 0o777, 0o755)
            self.assertEqual(os.stat(output).st_mode & 0o777, 0o600)

    @staticmethod
    def hit(segment):
        return {
            "segmentID": segment["id"],
            "meetingID": segment["meetingID"],
            "timestampMilliseconds": segment["timestampMilliseconds"],
            "transcriptRevision": segment["transcriptRevision"],
        }

    @classmethod
    def perfect_observations(cls, fixture):
        segments = {segment["id"]: segment for segment in fixture["segments"]}
        observations = []
        for query in fixture["queries"]:
            hits = [
                cls.hit(segments[label["segmentID"]])
                for label in query["relevant"]
            ]
            answerable = query["answerPolicy"] == "answer"
            observations.append(
                {
                    "queryID": query["id"],
                    "hits": hits,
                    "answer": {
                        "outcome": "answered" if answerable else "abstained",
                        "factuality": 1,
                        "citationCoverage": 1,
                        "unsupportedClaims": 0,
                    },
                }
            )
        return {
            "schemaVersion": 1,
            "kind": "ask-quality-observations",
            "fixtureGeneration": fixture["generation"],
            "adapter": "accelerate-exact-control",
            "build": "test",
            "commit": "0" * 40,
            "queries": observations,
        }


if __name__ == "__main__":
    unittest.main()
