import copy
import contextlib
import importlib.util
import io
import json
import stat
import subprocess
import tempfile
import unittest
from collections import Counter
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "commitment_link_quality.py"
SPEC = importlib.util.spec_from_file_location("commitment_link_quality", SCRIPT)
quality = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(quality)
FIXTURE = ROOT / "Fixtures" / "CommitmentLinkQuality" / "public-synthetic-v1.json"
CORPUS = ROOT / "Fixtures" / "CommitmentLinkQuality" / "public-corpus-v1.json"


class CommitmentLinkQualityTests(unittest.TestCase):
    def fixture(self):
        return quality.validate_fixture(quality.load_json(FIXTURE, "fixture"))

    def observations(self):
        return quality.control_observations(self.fixture())

    def similarity_observations(self):
        fixture = self.fixture()
        control = quality.control_observations(fixture)
        return {
            "schemaVersion": 1,
            "kind": quality.SIMILARITY_OBSERVATION_KIND,
            "fixtureGeneration": fixture["generation"],
            "fixtureSHA256": quality.fixture_digest(fixture),
            "adapter": "product-accelerate-exact-scored-v1",
            "embeddingProfileFingerprint": "a" * 64,
            "build": "0.9.0+1",
            "commit": "b" * 40,
            "evaluationStatus": "not-evaluated",
            "servingStatus": "not-approved",
            "observations": [
                {
                    "caseID": row["caseID"],
                    "semanticHits": [
                        {
                            "evidenceSegmentID": evidence_id,
                            "similarity": round(1 - rank * 0.01, 6),
                        }
                        for rank, evidence_id in enumerate(
                            row["semanticHitSegmentIDs"]
                        )
                    ],
                    "suggestions": row["suggestions"],
                }
                for row in control["observations"]
            ],
        }

    def test_public_corpus_is_bounded_and_rejects_incomplete_languages(self):
        corpus = quality.load_public_corpus(CORPUS)
        self.assertEqual(
            {language: len(rows) for language, rows in corpus["vocabularies"].items()},
            {"en": 12, "es": 12, "mixed": 12},
        )
        broken = copy.deepcopy(corpus)
        del broken["templates"]["distractorTitle"]["mixed"]
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "broken-corpus.json"
            path.write_text(json.dumps(broken, ensure_ascii=False), encoding="utf-8")
            with self.assertRaisesRegex(
                quality.CommitmentLinkQualityError,
                "languages are incomplete",
            ):
                quality.load_public_corpus(path)

    def test_public_fixture_is_reproducible_balanced_and_bounded(self):
        fixture = self.fixture()

        self.assertEqual(fixture, quality.public_fixture())
        self.assertEqual(len(fixture["cases"]), 36)
        self.assertEqual(
            Counter(case["language"] for case in fixture["cases"]),
            Counter({"en": 12, "es": 12, "mixed": 12}),
        )
        self.assertEqual(
            sum(bool(case["expected"]["linkableCommitmentIDs"])
                for case in fixture["cases"]),
            18,
        )
        self.assertTrue(all(len(case["targets"]) <= 2 for case in fixture["cases"]))
        self.assertTrue(any(
            len(target["evidence"]) == 2
            for case in fixture["cases"]
            for target in case["targets"]
        ))

    def test_fixture_rejects_link_truth_without_exact_owner(self):
        fixture = self.fixture()
        broken = copy.deepcopy(fixture)
        case = next(
            item for item in broken["cases"]
            if item["expected"]["linkableCommitmentIDs"]
            and item["candidate"]["assignee"]["kind"] == "person"
        )
        target_id = case["expected"]["linkableCommitmentIDs"][0]
        target = next(item for item in case["targets"] if item["id"] == target_id)
        target["assignee"] = quality.owner("person", "person-conflict")

        with self.assertRaisesRegex(
            quality.CommitmentLinkQualityError,
            "exact ownership",
        ):
            quality.validate_fixture(broken)

    def test_fixture_rejects_semantic_and_link_truth_drift(self):
        fixture = self.fixture()
        broken = copy.deepcopy(fixture)
        case = next(item for item in broken["cases"] if item["expected"]["mustAbstain"])
        case["expected"]["linkableCommitmentIDs"] = [case["targets"][0]["id"]]

        with self.assertRaisesRegex(
            quality.CommitmentLinkQualityError,
            "semantically relevant|abstention truth",
        ):
            quality.validate_fixture(broken)

    def test_perfect_control_is_explicitly_review_only(self):
        fixture = self.fixture()
        scorecard, details = quality.evaluate(
            fixture,
            quality.control_observations(fixture),
        )

        self.assertEqual(scorecard["counts"]["cases"], 36)
        self.assertEqual(scorecard["counts"]["linkableCases"], 18)
        self.assertEqual(scorecard["counts"]["abstentionCases"], 18)
        self.assertEqual(scorecard["counts"]["suggestions"], 21)
        self.assertEqual(scorecard["metrics"]["semanticTargetRecallAt20"], 1.0)
        self.assertEqual(scorecard["metrics"]["linkF1"], 1.0)
        self.assertEqual(scorecard["metrics"]["abstentionAccuracy"], 1.0)
        self.assertEqual(scorecard["metrics"]["supportedSuggestionRate"], 1.0)
        self.assertEqual(scorecard["qualityDecision"], "review-required")
        self.assertEqual(scorecard["productDecision"], "not-evaluated")
        self.assertEqual(len(details), 36)
        multi_evidence_case = next(
            case for case in fixture["cases"]
            if any(len(target["evidence"]) == 2 for target in case["targets"])
        )
        multi_observation = next(
            row for row in quality.control_observations(fixture)["observations"]
            if row["caseID"] == multi_evidence_case["id"]
        )
        self.assertEqual(
            len(multi_observation["suggestions"][0]["matchedEvidenceSegmentIDs"]),
            2,
        )

    def test_wrong_person_suggestion_is_false_and_unsupported(self):
        fixture = self.fixture()
        observations = quality.control_observations(fixture)
        case = next(item for item in fixture["cases"] if item["class"] == "wrong-person")
        observation = next(
            item for item in observations["observations"] if item["caseID"] == case["id"]
        )
        target = case["targets"][0]
        hit = observation["semanticHitSegmentIDs"][0]
        observation["suggestions"] = [{
            "commitmentID": target["id"],
            "assignee": target["assignee"],
            "matchedEvidenceSegmentIDs": [hit],
            "bestSemanticRank": 1,
        }]

        scorecard, _ = quality.evaluate(fixture, observations)

        self.assertEqual(scorecard["counts"]["falsePositiveSuggestions"], 1)
        self.assertEqual(scorecard["counts"]["unsupportedSuggestions"], 1)
        self.assertEqual(scorecard["metrics"]["falseSuggestionRate"], 0.055556)

    def test_semantically_wrong_but_policy_valid_suggestion_is_still_false(self):
        fixture = self.fixture()
        observations = quality.control_observations(fixture)
        case = next(item for item in fixture["cases"] if item["class"] == "no-overlap")
        observation = next(
            item for item in observations["observations"] if item["caseID"] == case["id"]
        )
        target = case["targets"][0]
        hit = target["evidence"][0]["id"]
        observation["semanticHitSegmentIDs"] = [hit]
        observation["suggestions"] = [{
            "commitmentID": target["id"],
            "assignee": target["assignee"],
            "matchedEvidenceSegmentIDs": [hit],
            "bestSemanticRank": 1,
        }]

        scorecard, _ = quality.evaluate(fixture, observations)

        self.assertEqual(scorecard["counts"]["falsePositiveSuggestions"], 1)
        self.assertEqual(scorecard["counts"]["supportedSuggestions"], 22)
        self.assertEqual(scorecard["counts"]["unsupportedSuggestions"], 0)
        self.assertLess(scorecard["metrics"]["linkPrecision"], 1.0)

    def test_observation_contract_rejects_missing_duplicate_and_unknown_evidence(self):
        fixture = self.fixture()
        observations = quality.control_observations(fixture)
        missing = copy.deepcopy(observations)
        missing["observations"].pop()
        with self.assertRaisesRegex(
            quality.CommitmentLinkQualityError,
            "exactly one",
        ):
            quality.validate_observations(missing, fixture)

        duplicate = copy.deepcopy(observations)
        duplicate["observations"][-1]["caseID"] = duplicate["observations"][0]["caseID"]
        with self.assertRaisesRegex(
            quality.CommitmentLinkQualityError,
            "duplicate observation",
        ):
            quality.validate_observations(duplicate, fixture)

        unknown = copy.deepcopy(observations)
        unknown["observations"][0]["semanticHitSegmentIDs"] = ["evidence-unknown"]
        with self.assertRaisesRegex(
            quality.CommitmentLinkQualityError,
            "unknown evidence",
        ):
            quality.validate_observations(unknown, fixture)

    def test_observation_contract_rejects_over_bounded_and_drifted_fixture(self):
        fixture = self.fixture()
        observations = quality.control_observations(fixture)
        over_bounded = copy.deepcopy(observations)
        over_bounded["observations"][0]["suggestions"] = (
            over_bounded["observations"][0]["suggestions"] * 4
        )
        with self.assertRaisesRegex(
            quality.CommitmentLinkQualityError,
            "bounded to three",
        ):
            quality.validate_observations(over_bounded, fixture)

        drifted = copy.deepcopy(observations)
        drifted["fixtureSHA256"] = "0" * 64
        with self.assertRaisesRegex(
            quality.CommitmentLinkQualityError,
            "digest does not match",
        ):
            quality.validate_observations(drifted, fixture)

    def test_similarity_contract_binds_profile_provenance_and_stays_non_serving(self):
        fixture = self.fixture()
        observations = self.similarity_observations()

        self.assertIs(
            quality.validate_similarity_observations(observations, fixture),
            observations,
        )
        self.assertEqual(observations["evaluationStatus"], "not-evaluated")
        self.assertEqual(observations["servingStatus"], "not-approved")
        self.assertEqual(len(observations["observations"]), 36)

        for key, value, message in (
            ("embeddingProfileFingerprint", "short", "fingerprint"),
            ("build", "invalid build", "build"),
            ("commit", "ABC", "commit"),
            ("evaluationStatus", "accepted", "not-evaluated"),
            ("servingStatus", "approved", "not-approved"),
        ):
            broken = copy.deepcopy(observations)
            broken[key] = value
            with self.assertRaisesRegex(
                quality.CommitmentLinkQualityError,
                message,
            ):
                quality.validate_similarity_observations(broken, fixture)

    def test_similarity_contract_rejects_unknown_duplicate_and_misordered_scores(self):
        fixture = self.fixture()
        observations = self.similarity_observations()
        row_index, row = next(
            (index, item)
            for index, item in enumerate(observations["observations"])
            if len(item["semanticHits"]) >= 2
        )

        for mutate, message in (
            (
                lambda value: value["observations"][0].update(
                    {"unexpected": True}
                ),
                "exactly",
            ),
            (
                lambda value: value["observations"][row_index]["semanticHits"][0].update(
                    {"evidenceSegmentID": "evidence-unknown"}
                ),
                "unknown",
            ),
            (
                lambda value: value["observations"][row_index]["semanticHits"].append(
                    copy.deepcopy(
                        value["observations"][row_index]["semanticHits"][0]
                    )
                ),
                "duplicates",
            ),
        ):
            broken = copy.deepcopy(observations)
            mutate(broken)
            with self.assertRaisesRegex(
                quality.CommitmentLinkQualityError,
                message,
            ):
                quality.validate_similarity_observations(broken, fixture)

        case_id = row["caseID"]
        for similarity, message in (
            (float("nan"), "finite cosine"),
            (1.1, "finite cosine"),
        ):
            broken = copy.deepcopy(observations)
            broken_row = next(
                item for item in broken["observations"]
                if item["caseID"] == case_id
            )
            broken_row["semanticHits"][0]["similarity"] = similarity
            with self.assertRaisesRegex(
                quality.CommitmentLinkQualityError,
                message,
            ):
                quality.validate_similarity_observations(broken, fixture)

        broken = copy.deepcopy(observations)
        broken_row = next(
            item for item in broken["observations"]
            if item["caseID"] == case_id
        )
        broken_row["semanticHits"][0]["similarity"] = 0.1
        broken_row["semanticHits"][1]["similarity"] = 0.9
        with self.assertRaisesRegex(
            quality.CommitmentLinkQualityError,
            "descending similarity",
        ):
            quality.validate_similarity_observations(broken, fixture)

    def test_details_output_is_owner_only_and_non_overwriting(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "details.json"
            quality.write_json(path, {"safe": True}, owner_only=True)

            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
            with self.assertRaisesRegex(
                quality.CommitmentLinkQualityError,
                "already exists",
            ):
                quality.write_json(path, {"safe": True}, owner_only=True)

    def test_cli_validate_control_and_evaluate(self):
        fixture = self.fixture()
        with tempfile.TemporaryDirectory() as directory:
            observations_path = Path(directory) / "observations.json"
            observations_path.write_text(
                json.dumps(quality.control_observations(fixture)),
                encoding="utf-8",
            )
            similarity_path = Path(directory) / "similarity.json"
            similarity_path.write_text(
                json.dumps(self.similarity_observations()),
                encoding="utf-8",
            )
            details_path = Path(directory) / "details.json"
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(
                    quality.main(["validate", "--fixture", str(FIXTURE)]),
                    0,
                )
                self.assertEqual(
                    quality.main(["control", "--fixture", str(FIXTURE)]),
                    0,
                )
                self.assertEqual(
                    quality.main([
                        "validate-similarity",
                        "--fixture", str(FIXTURE),
                        "--observations", str(similarity_path),
                    ]),
                    0,
                )
                self.assertEqual(
                    quality.main([
                        "evaluate",
                        "--fixture", str(FIXTURE),
                        "--observations", str(observations_path),
                        "--details-output", str(details_path),
                    ]),
                    0,
                )
            self.assertTrue(details_path.is_file())
            self.assertEqual(stat.S_IMODE(details_path.stat().st_mode), 0o600)

    def test_make_target_emits_one_review_only_scorecard(self):
        result = subprocess.run(
            ["make", "--no-print-directory", "commitment-link-quality-control"],
            cwd=ROOT,
            check=True,
            capture_output=True,
            text=True,
        )
        scorecard = json.loads(result.stdout)

        self.assertEqual(scorecard["kind"], quality.SCORECARD_KIND)
        self.assertEqual(scorecard["qualityDecision"], "review-required")
        self.assertEqual(scorecard["productDecision"], "not-evaluated")


if __name__ == "__main__":
    unittest.main()
