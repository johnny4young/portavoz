import copy
import contextlib
import importlib.util
import io
import json
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "commitment_quality.py"
SPEC = importlib.util.spec_from_file_location("commitment_quality", SCRIPT)
quality = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(quality)
FIXTURE = ROOT / "Fixtures" / "CommitmentQuality" / "public-synthetic-v1.json"


class CommitmentQualityTests(unittest.TestCase):
    def fixture(self):
        return quality.validate_fixture(quality.load_json(FIXTURE, "fixture"))

    def test_canonical_fixture_is_balanced_and_public(self):
        fixture = self.fixture()

        self.assertEqual(fixture["generation"], "public-synthetic-v1")
        self.assertEqual(fixture["contentSource"], "public-synthetic-only")
        self.assertEqual(len(fixture["cases"]), 48)
        self.assertEqual(
            {language: sum(case["language"] == language for case in fixture["cases"])
             for language in quality.LANGUAGES},
            {"en": 16, "es": 16, "mixed": 16},
        )

    def test_fixture_rejects_missing_direct_action_evidence(self):
        fixture = self.fixture()
        broken = copy.deepcopy(fixture)
        broken["cases"][0]["actionItem"]["evidenceIDs"] = []

        with self.assertRaisesRegex(
            quality.CommitmentQualityError,
            "actionItem evidence",
        ):
            quality.validate_fixture(broken)

    def test_fixture_rejects_negative_candidate_truth(self):
        fixture = self.fixture()
        broken = copy.deepcopy(fixture)
        suggestion = next(case for case in broken["cases"] if case["label"] == "suggestion")
        suggestion["expected"]["candidate"] = True
        suggestion["expected"]["evidenceIDs"] = suggestion["actionItem"]["evidenceIDs"]

        with self.assertRaisesRegex(quality.CommitmentQualityError, "label and candidate"):
            quality.validate_fixture(broken)

    def test_deterministic_control_is_perfect_on_the_declared_rule_fixture(self):
        fixture = self.fixture()
        observations = [
            quality.deterministic_observation(case) for case in fixture["cases"]
        ]

        scorecard, details = quality.score(
            fixture,
            observations,
            "research-deterministic-v1",
        )

        self.assertEqual(scorecard["counts"]["truePositive"], 12)
        self.assertEqual(scorecard["counts"]["trueNegative"], 36)
        self.assertEqual(scorecard["counts"]["falsePositive"], 0)
        self.assertEqual(scorecard["counts"]["falseNegative"], 0)
        self.assertEqual(scorecard["metrics"]["candidateF1"], 1.0)
        self.assertEqual(scorecard["metrics"]["ownerFalsePositiveRate"], 0.0)
        self.assertEqual(scorecard["metrics"]["deadlineFalsePositiveRate"], 0.0)
        self.assertEqual(scorecard["metrics"]["evidenceExactRate"], 1.0)
        self.assertTrue(all(item["evidenceValid"] for item in details if item["observed"]["candidate"]))
        self.assertEqual(scorecard["qualityDecision"], "review-required")
        self.assertEqual(scorecard["productDecision"], "not-evaluated")

    def test_unsupported_candidates_fail_closed_and_false_fields_are_measured(self):
        fixture = self.fixture()
        observations = [
            quality.deterministic_observation(case) for case in fixture["cases"]
        ]
        positive = next(case for case in fixture["cases"] if case["expected"]["candidate"])
        negative = next(case for case in fixture["cases"] if not case["expected"]["candidate"])
        by_id = {item["id"]: item for item in observations}
        by_id[positive["id"]] = quality.observation(
            positive["id"], True, positive["expected"]["owner"], None, []
        )
        by_id[negative["id"]] = quality.observation(
            negative["id"], True, "Invented owner", "friday",
            negative["actionItem"]["evidenceIDs"],
        )

        scorecard, _ = quality.score(
            fixture,
            list(by_id.values()),
            "test-adapter",
        )

        self.assertEqual(scorecard["counts"]["unsupportedCandidate"], 1)
        self.assertEqual(scorecard["counts"]["falseNegative"], 1)
        self.assertEqual(scorecard["counts"]["falsePositive"], 1)
        self.assertEqual(scorecard["counts"]["ownerFalsePositive"], 1)
        self.assertEqual(scorecard["counts"]["deadlineFalsePositive"], 1)

    def test_observation_contract_rejects_missing_and_duplicate_cases(self):
        fixture = self.fixture()
        observations = [
            quality.deterministic_observation(case) for case in fixture["cases"]
        ]
        with self.assertRaisesRegex(quality.CommitmentQualityError, "exactly one"):
            quality.validate_observations({"observations": observations[:-1]}, fixture)
        observations[-1]["id"] = observations[0]["id"]
        with self.assertRaisesRegex(quality.CommitmentQualityError, "duplicate"):
            quality.validate_observations({"observations": observations}, fixture)

    def test_model_endpoint_is_loopback_only(self):
        self.assertEqual(
            quality.loopback_endpoint("http://127.0.0.1:11434/v1/chat/completions"),
            "http://127.0.0.1:11434/v1/chat/completions",
        )
        self.assertEqual(
            quality.loopback_endpoint("http://[::1]:11434/v1/chat/completions"),
            "http://[::1]:11434/v1/chat/completions",
        )
        for endpoint in (
            "http://localhost:11434/v1/chat/completions",
            "https://api.example.com/v1/chat/completions",
            "http://192.168.1.10:11434/v1/chat/completions",
            "http://localhost:11434/api/generate",
        ):
            with self.assertRaises(quality.CommitmentQualityError):
                quality.loopback_endpoint(endpoint)

    def test_private_details_are_owner_only_and_non_overwriting(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "details.json"
            quality.write_private_json(path, {"safe": True})

            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
            with self.assertRaisesRegex(quality.CommitmentQualityError, "already exists"):
                quality.write_private_json(path, {"safe": True})

    def test_comparison_requires_same_fixture_and_never_selects_a_winner(self):
        fixture = self.fixture()
        observations = [
            quality.deterministic_observation(case) for case in fixture["cases"]
        ]
        left, _ = quality.score(fixture, observations, "left")
        right, _ = quality.score(fixture, observations, "right")

        comparison = quality.compare(left, right)

        self.assertEqual(comparison["winner"], "not-evaluated")
        self.assertEqual(comparison["productDecision"], "not-evaluated")
        self.assertTrue(all(value == 0 for value in comparison["metricDeltaRightMinusLeft"].values()))
        right["fixtureSHA256"] = "1" * 64
        with self.assertRaisesRegex(quality.CommitmentQualityError, "same fixture"):
            quality.compare(left, right)

    def test_comparison_rejects_inconsistent_scorecard_counts(self):
        fixture = self.fixture()
        observations = [
            quality.deterministic_observation(case) for case in fixture["cases"]
        ]
        left, _ = quality.score(fixture, observations, "left")
        right = copy.deepcopy(left)
        right["counts"]["truePositive"] -= 1

        with self.assertRaisesRegex(quality.CommitmentQualityError, "inconsistent"):
            quality.compare(left, right)

    def test_cli_validate_and_deterministic_run(self):
        with tempfile.TemporaryDirectory() as directory:
            details = Path(directory) / "details.json"
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(
                    quality.main(["validate", "--fixture", str(FIXTURE)]),
                    0,
                )
                self.assertEqual(
                    quality.main([
                        "run", "--fixture", str(FIXTURE),
                        "--adapter", "deterministic",
                        "--details-output", str(details),
                    ]),
                    0,
                )
            self.assertTrue(details.is_file())
            detail_document = json.loads(details.read_text())
            self.assertEqual(
                detail_document["fixtureSHA256"],
                quality.fixture_digest(self.fixture()),
            )

    def test_make_deterministic_target_emits_one_json_scorecard(self):
        result = subprocess.run(
            ["make", "--no-print-directory", "commitment-quality-deterministic"],
            cwd=ROOT,
            check=True,
            capture_output=True,
            text=True,
        )
        document = json.loads(result.stdout)

        self.assertEqual(document["kind"], quality.SCORECARD_KIND)
        self.assertEqual(document["adapter"], "research-deterministic-v1")


if __name__ == "__main__":
    unittest.main()
