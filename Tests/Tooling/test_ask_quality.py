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
        self.assertEqual(validated["generation"], "public-synthetic-v2")

    def test_public_fixture_v1_remains_reproducible(self):
        fixture = quality.public_fixture("public-synthetic-v1")
        validated = quality.validate_fixture(fixture)

        self.assertEqual(
            validated["checksum"],
            "a44be7a1a90af377d45ebc5cfa97e807f9c270c70778bfe5f75d36707ec26303",
        )

    def test_v2_topology_has_two_multilingual_turns_per_meeting(self):
        fixture = quality.public_fixture()
        segments = {segment["id"]: segment for segment in fixture["segments"]}
        meetings = {}
        for segment in fixture["segments"]:
            meetings.setdefault(segment["meetingID"], []).append(segment)

        self.assertEqual(len(meetings), 60)
        has_multilingual_turn = False
        for meeting_segments in meetings.values():
            meeting_segments.sort(key=lambda item: item["timestampMilliseconds"])
            self.assertEqual(len(meeting_segments), 4)
            self.assertEqual(
                meeting_segments[0]["owner"], meeting_segments[1]["owner"]
            )
            self.assertEqual(
                meeting_segments[2]["owner"], meeting_segments[3]["owner"]
            )
            self.assertNotEqual(
                meeting_segments[0]["owner"], meeting_segments[2]["owner"]
            )
            has_multilingual_turn = has_multilingual_turn or any(
                meeting_segments[index]["language"]
                != meeting_segments[index + 1]["language"]
                for index in (0, 2)
            )
        self.assertTrue(has_multilingual_turn)
        for query in fixture["queries"]:
            query_segment = segments[f"segment-{int(query['id'][-3:]):03d}"]
            hard_negative = segments[query["hardNegativeSegmentIDs"][0]]
            self.assertNotEqual(
                query_segment["meetingID"], hard_negative["meetingID"]
            )

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
        typo_by_intent = {
            "name": "resposable",
            "date": "progamó",
            "commitment": "conprometió",
            "decision": "desición",
            "risk": "rieso",
            "technicalIdentifier": "esqumea",
            "paraphrase": "resolbió",
        }
        for query in queries[5:10]:
            expected_typo = typo_by_intent.get(query["intent"])
            if expected_typo is not None:
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
        self.assertEqual(scorecard["subject"]["observationSchemaVersion"], 2)
        self.assertNotIn('"text"', encoded)
        self.assertNotIn('"queryID"', encoded)
        self.assertNotIn("Mara", encoded)

    def test_paired_receipt_accepts_exact_segment_parity_without_payloads(self):
        fixture_document = quality.public_fixture()
        fixture = quality.validate_fixture(fixture_document)
        control = quality.evaluate(
            fixture,
            quality.validate_observations(
                self.perfect_observations(fixture_document), fixture
            ),
        )
        candidate = copy.deepcopy(control)
        control["subject"]["adapter"] = quality.SEGMENT_ADAPTER
        candidate["subject"]["adapter"] = quality.SPEAKER_TURN_ADAPTER

        receipt = quality.compare_scorecards(
            fixture,
            quality.validate_scorecard(control, "controlScorecard"),
            quality.validate_scorecard(candidate, "candidateScorecard"),
        )
        encoded = json.dumps(receipt, sort_keys=True)

        self.assertEqual(receipt["outcome"], "candidate-parity")
        self.assertTrue(all(receipt["gates"].values()))
        self.assertTrue(
            all(value == 0 for value in receipt["aggregateDeltas"].values())
        )
        self.assertNotIn('"text"', encoded)
        self.assertNotIn('"queryID"', encoded)
        self.assertNotIn("Mara", encoded)

    def test_paired_receipt_blocks_run_identity_and_retrieval_regressions(self):
        fixture_document = quality.public_fixture()
        fixture = quality.validate_fixture(fixture_document)
        control = self.scorecard(fixture_document, fixture, quality.SEGMENT_ADAPTER)
        candidate_observations = self.perfect_observations(fixture_document)
        candidate_observations["queries"][0]["hits"] = []
        candidate = quality.evaluate(
            fixture,
            quality.validate_observations(candidate_observations, fixture),
        )
        candidate["subject"]["adapter"] = quality.SPEAKER_TURN_ADAPTER
        candidate["subject"]["commit"] = "1" * 40

        receipt = quality.compare_scorecards(
            fixture,
            quality.validate_scorecard(control, "controlScorecard"),
            quality.validate_scorecard(candidate, "candidateScorecard"),
        )

        self.assertEqual(receipt["outcome"], "blocked")
        self.assertFalse(receipt["gates"]["runIdentityMatches"])
        self.assertFalse(receipt["gates"]["aggregateRetrievalParity"])
        self.assertFalse(receipt["gates"]["relationshipRetrievalParity"])

    def test_compare_command_publishes_owner_only_receipt(self):
        fixture_document = quality.public_fixture()
        fixture = quality.validate_fixture(fixture_document)
        control = self.scorecard(fixture_document, fixture, quality.SEGMENT_ADAPTER)
        candidate = copy.deepcopy(control)
        candidate["subject"]["adapter"] = quality.SPEAKER_TURN_ADAPTER
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fixture_path = root / "fixture.json"
            control_path = root / "control.json"
            candidate_path = root / "candidate.json"
            output = root / "comparison.json"
            fixture_path.write_text(json.dumps(fixture_document))
            control_path.write_text(json.dumps(control))
            candidate_path.write_text(json.dumps(candidate))

            result = quality.main_from_args(
                [
                    "compare",
                    "--fixture",
                    str(fixture_path),
                    "--control",
                    str(control_path),
                    "--candidate",
                    str(candidate_path),
                    "--output",
                    str(output),
                ]
            )

            self.assertEqual(result, 0)
            self.assertEqual(
                json.loads(output.read_text())["outcome"], "candidate-parity"
            )
            self.assertEqual(os.stat(output).st_mode & 0o777, 0o600)

    def test_paired_receipt_blocks_hard_negative_chunk_regression(self):
        fixture_document = quality.public_fixture()
        fixture = quality.validate_fixture(fixture_document)
        control = self.scorecard(fixture_document, fixture, quality.SEGMENT_ADAPTER)
        candidate_observations = self.perfect_observations(fixture_document)
        hard_negative = fixture_document["queries"][0][
            "hardNegativeSegmentIDs"
        ][0]
        segment = next(
            item
            for item in fixture_document["segments"]
            if item["id"] == hard_negative
        )
        candidate_observations["queries"][0]["hits"].append(self.hit(segment))
        candidate = quality.evaluate(
            fixture,
            quality.validate_observations(candidate_observations, fixture),
        )
        candidate["subject"]["adapter"] = quality.SPEAKER_TURN_ADAPTER

        receipt = quality.compare_scorecards(
            fixture,
            quality.validate_scorecard(control, "controlScorecard"),
            quality.validate_scorecard(candidate, "candidateScorecard"),
        )

        self.assertEqual(receipt["outcome"], "blocked")
        self.assertFalse(receipt["gates"]["hardNegativesDoNotRegress"])

    def test_scorecard_validator_rejects_tampered_outcome(self):
        fixture_document = quality.public_fixture()
        fixture = quality.validate_fixture(fixture_document)
        scorecard = self.scorecard(
            fixture_document, fixture, quality.SEGMENT_ADAPTER
        )
        scorecard["outcome"] = "blocked"

        with self.assertRaisesRegex(
            quality.AskQualityError, "outcome does not match its gates"
        ):
            quality.validate_scorecard(scorecard)

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
        observations["queries"][0]["hits"][0]["sourceSegmentIDs"] = [
            "unknown-segment"
        ]
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

    def test_hard_negative_inside_relevant_chunk_blocks(self):
        fixture_document = quality.public_fixture()
        fixture = quality.validate_fixture(fixture_document)
        observations = self.perfect_observations(fixture_document)
        hard_negative = "segment-002"
        fixture["queries"]["query-001"]["hardNegatives"] = {hard_negative}
        observations["queries"][0]["hits"][0]["sourceSegmentIDs"].append(
            hard_negative
        )

        scorecard = quality.evaluate(
            fixture, quality.validate_observations(observations, fixture)
        )

        self.assertEqual(scorecard["overall"]["hardNegativeHits"], 1)
        self.assertFalse(scorecard["gates"]["hardNegativesExcluded"])

    def test_unordered_chunk_sources_are_stale_evidence(self):
        fixture_document = quality.public_fixture()
        fixture = quality.validate_fixture(fixture_document)
        observations = self.perfect_observations(fixture_document)
        first = fixture_document["segments"][0]
        second = fixture_document["segments"][1]
        hit = observations["queries"][0]["hits"][0]
        hit["sourceSegmentIDs"] = [second["id"], first["id"]]
        hit["timestampMilliseconds"] = second["timestampMilliseconds"]

        scorecard = quality.evaluate(
            fixture, quality.validate_observations(observations, fixture)
        )

        self.assertEqual(scorecard["overall"]["staleCitationHits"], 1)
        self.assertFalse(scorecard["gates"]["citationsCanonical"])

    def test_cross_meeting_chunk_sources_are_stale_evidence(self):
        fixture_document = quality.public_fixture()
        fixture = quality.validate_fixture(fixture_document)
        observations = self.perfect_observations(fixture_document)
        other_meeting_source = fixture_document["segments"][4]
        observations["queries"][0]["hits"][0]["sourceSegmentIDs"].append(
            other_meeting_source["id"]
        )

        scorecard = quality.evaluate(
            fixture, quality.validate_observations(observations, fixture)
        )

        self.assertEqual(scorecard["overall"]["staleCitationHits"], 1)
        self.assertFalse(scorecard["gates"]["citationsCanonical"])

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
        with self.assertRaisesRegex(quality.AskQualityError, "hits repeat unit"):
            quality.validate_observations(duplicate, fixture)

        repeated_source = self.perfect_observations(fixture_document)
        second_unit = copy.deepcopy(repeated_source["queries"][0]["hits"][0])
        second_unit["unitID"] = "different-unit"
        repeated_source["queries"][0]["hits"].append(second_unit)
        with self.assertRaisesRegex(
            quality.AskQualityError, "hits repeat source segment"
        ):
            quality.validate_observations(repeated_source, fixture)

        payload = self.perfect_observations(fixture_document)
        payload["queries"][0]["answer"]["generatedText"] = "private"
        with self.assertRaisesRegex(
            quality.AskQualityError, "forbidden keys: generatedText"
        ):
            quality.validate_observations(payload, fixture)

    def test_retrieval_only_observations_remain_explicitly_blocked(self):
        fixture_document = quality.public_fixture()
        fixture = quality.validate_fixture(fixture_document)
        observations = self.perfect_observations(fixture_document)
        for observation in observations["queries"]:
            observation["answer"] = {
                "outcome": "notEvaluated",
                "factuality": None,
                "citationCoverage": None,
                "unsupportedClaims": 0,
            }

        scorecard = quality.evaluate(
            fixture, quality.validate_observations(observations, fixture)
        )

        self.assertEqual(scorecard["outcome"], "blocked")
        self.assertTrue(scorecard["gates"]["retrievalQualityFloor"])
        self.assertFalse(scorecard["gates"]["answerQualityFloor"])
        self.assertFalse(scorecard["gates"]["answerPolicyHonored"])

    def test_legacy_segment_observations_normalize_to_one_source_units(self):
        fixture_document = quality.public_fixture()
        fixture = quality.validate_fixture(fixture_document)
        observations = self.perfect_observations(fixture_document)
        observations["schemaVersion"] = 1
        for observation in observations["queries"]:
            observation["hits"] = [
                {
                    "segmentID": hit["sourceSegmentIDs"][0],
                    "meetingID": hit["meetingID"],
                    "timestampMilliseconds": hit["timestampMilliseconds"],
                    "transcriptRevision": hit["transcriptRevision"],
                }
                for hit in observation["hits"]
            ]

        validated = quality.validate_observations(observations, fixture)
        scorecard = quality.evaluate(fixture, validated)

        self.assertEqual(validated["subject"]["observationSchemaVersion"], 1)
        self.assertEqual(scorecard["outcome"], "pass")

    def test_unevaluated_answers_reject_fabricated_scores(self):
        fixture_document = quality.public_fixture()
        fixture = quality.validate_fixture(fixture_document)
        observations = self.perfect_observations(fixture_document)
        observations["queries"][0]["answer"] = {
            "outcome": "notEvaluated",
            "factuality": 1,
            "citationCoverage": None,
            "unsupportedClaims": 0,
        }

        with self.assertRaisesRegex(
            quality.AskQualityError, "unevaluated scores must be null"
        ):
            quality.validate_observations(observations, fixture)

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
            "unitID": segment["id"],
            "sourceSegmentIDs": [segment["id"]],
            "meetingID": segment["meetingID"],
            "timestampMilliseconds": segment["timestampMilliseconds"],
            "transcriptRevision": segment["transcriptRevision"],
        }

    @classmethod
    def scorecard(cls, fixture_document, fixture, adapter):
        scorecard = quality.evaluate(
            fixture,
            quality.validate_observations(
                cls.perfect_observations(fixture_document), fixture
            ),
        )
        scorecard["subject"]["adapter"] = adapter
        return scorecard

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
            "schemaVersion": 2,
            "kind": "ask-quality-observations",
            "fixtureGeneration": fixture["generation"],
            "adapter": "accelerate-exact-control",
            "build": "test",
            "commit": "0" * 40,
            "queries": observations,
        }


if __name__ == "__main__":
    unittest.main()
