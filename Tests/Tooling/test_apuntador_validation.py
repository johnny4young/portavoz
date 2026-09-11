import copy
import importlib.util
import json
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "apuntador_validation", ROOT / "scripts" / "apuntador_validation.py"
)
validation = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(validation)
FIXTURE_PATH = ROOT / "Fixtures" / "ApuntadorValidation" / "public-bilingual-v1.json"
BUDGET_PATH = ROOT / "docs" / "evidence" / "apuntador-validation-budget.json"


def fixture_document():
    return json.loads(FIXTURE_PATH.read_text(encoding="utf-8"))


def budget_document():
    return json.loads(BUDGET_PATH.read_text(encoding="utf-8"))


def honest_observations(fixture, fixture_checksum):
    scenarios = []
    for scenario_id, scenario in fixture["scenarios"].items():
        publishes = scenario["expectedOutcome"] in {"answered", "recovered"}
        scenarios.append({
            "scenarioID": scenario_id,
            "outcome": scenario["expectedOutcome"],
            "claimIDs": sorted(scenario["expectedClaims"]),
            "citedEvidenceIDs": sorted(scenario["expectedEvidence"]),
            "firstEvidenceMilliseconds": 250.0 if publishes else None,
            "completionMilliseconds": 600.0,
            "latePublicationCount": 0,
        })
    return {
        "schemaVersion": 1,
        "kind": validation.OBSERVATION_KIND,
        "fixtureGeneration": validation.GENERATION,
        "fixtureChecksum": fixture_checksum,
        "adapter": {"id": "deterministic-fixture", "version": "1.0.0"},
        "run": {
            "commit": "a" * 40,
            "build": "debug-tests",
            "platform": "macos",
            "osVersion": "26.5.2",
            "architecture": "arm64",
        },
        "scenarios": scenarios,
    }


class ApuntadorValidationTests(unittest.TestCase):
    def setUp(self):
        self.fixture_document = fixture_document()
        self.fixture = validation.validate_fixture(self.fixture_document)
        self.fixture_checksum = validation.file_sha256(FIXTURE_PATH)
        self.budget = validation.validate_budget(
            budget_document(), self.fixture_checksum
        )

    def score(self, observations):
        validated = validation.validate_observations(
            observations,
            self.fixture,
            self.fixture_checksum,
        )
        return validation.evaluate(
            self.fixture,
            self.fixture_checksum,
            validated,
            self.budget,
        )

    def test_public_fixture_has_exact_bilingual_typed_distribution(self):
        sources = self.fixture_document["sources"]
        scenarios = self.fixture_document["scenarios"]

        self.assertEqual(len(sources), 6)
        self.assertEqual(len(scenarios), 24)
        self.assertEqual(
            {(source["kind"], source["language"]) for source in sources},
            {
                (kind, language)
                for kind in validation.SOURCE_KINDS
                for language in validation.LANGUAGES
            },
        )
        self.assertEqual(
            sum(item["fault"] == "none" for item in scenarios),
            12,
        )
        self.assertEqual(
            {item["fault"] for item in scenarios},
            validation.FAULTS,
        )
        for kind in validation.SOURCE_KINDS:
            for language in validation.LANGUAGES:
                outcomes = {
                    item["expectedOutcome"]
                    for item in scenarios
                    if item["fault"] == "none"
                    and item["sourceKinds"] == [kind]
                    and item["language"] == language
                }
                self.assertEqual(outcomes, {"answered", "abstained"})

    def test_note_and_spoken_provenance_cannot_be_conflated(self):
        invalid = copy.deepcopy(self.fixture_document)
        note = next(source for source in invalid["sources"] if source["kind"] == "note")
        note["participants"] = ["Invented participant"]

        with self.assertRaisesRegex(
            validation.ApuntadorValidationError,
            "note provenance must be author-only",
        ):
            validation.validate_fixture(invalid)

        invalid = copy.deepcopy(self.fixture_document)
        meeting = next(
            source for source in invalid["sources"] if source["kind"] == "meeting"
        )
        meeting["passages"][0]["timestampMilliseconds"] = None
        with self.assertRaisesRegex(
            validation.ApuntadorValidationError,
            "timestampMilliseconds must be an integer",
        ):
            validation.validate_fixture(invalid)

    def test_scenario_cannot_widen_language_or_source_scope(self):
        invalid = copy.deepcopy(self.fixture_document)
        scenario = next(
            item for item in invalid["scenarios"]
            if item["id"] == "scenario-meeting-en-answer"
        )
        scenario["expectedEvidenceIDs"] = ["evidence-note-es"]

        with self.assertRaisesRegex(
            validation.ApuntadorValidationError,
            "escapes its declared language/source scope",
        ):
            validation.validate_fixture(invalid)

        invalid = copy.deepcopy(self.fixture_document)
        scenario = next(
            item for item in invalid["scenarios"]
            if item["id"] == "scenario-meeting-en-answer"
        )
        scenario["forbiddenClaimIDs"] = ["forbidden-note-es"]
        with self.assertRaisesRegex(
            validation.ApuntadorValidationError,
            "forbidden claims escape their declared language/source scope",
        ):
            validation.validate_fixture(invalid)

    def test_perfect_content_free_observations_pass_every_gate(self):
        scorecard = self.score(
            honest_observations(self.fixture, self.fixture_checksum)
        )
        encoded = json.dumps(scorecard, sort_keys=True)

        self.assertEqual(scorecard["outcome"], "pass")
        self.assertTrue(all(scorecard["gates"].values()))
        self.assertEqual(scorecard["metrics"]["outcomeAccuracy"], 1.0)
        self.assertEqual(scorecard["metrics"]["citationPrecision"], 1.0)
        self.assertEqual(scorecard["metrics"]["evidenceRecall"], 1.0)
        self.assertEqual(scorecard["metrics"]["claimPrecision"], 1.0)
        self.assertEqual(scorecard["metrics"]["claimRecall"], 1.0)
        self.assertEqual(
            scorecard["fixture"]["scenarioSourceKindCounts"],
            {"interview": 8, "meeting": 8, "note": 8},
        )
        self.assertEqual(scorecard["proseQuality"], "notEvaluated")
        self.assertEqual(
            scorecard["memoryAndLeakEvidence"],
            "separateMeasuredLaneRequired",
        )
        for forbidden_payload in (
            "question",
            "Harbor",
            "Lucía",
            "transcript",
            "answerText",
            "scenarioID",
        ):
            self.assertNotIn(forbidden_payload, encoded)

    def test_hard_negative_forbidden_claim_and_wrong_outcome_block(self):
        observations = honest_observations(self.fixture, self.fixture_checksum)
        row = next(
            item for item in observations["scenarios"]
            if item["scenarioID"] == "scenario-meeting-en-abstain"
        )
        row.update({
            "outcome": "answered",
            "claimIDs": ["forbidden-meeting-en"],
            "citedEvidenceIDs": ["distractor-meeting-en"],
            "firstEvidenceMilliseconds": 100.0,
        })

        scorecard = self.score(observations)

        self.assertEqual(scorecard["outcome"], "blocked")
        self.assertFalse(scorecard["gates"]["outcomeAccuracy"])
        self.assertFalse(scorecard["gates"]["hardNegativesExcluded"])
        self.assertFalse(scorecard["gates"]["forbiddenClaimsExcluded"])

    def test_cancellation_and_unavailable_outcomes_reject_late_content(self):
        observations = honest_observations(self.fixture, self.fixture_checksum)
        row = next(
            item for item in observations["scenarios"]
            if item["scenarioID"] == "scenario-cancelbeforeevidence-en"
        )
        row["claimIDs"] = ["claim-meeting-en"]

        with self.assertRaisesRegex(
            validation.ApuntadorValidationError,
            "terminal non-answer must not publish content",
        ):
            validation.validate_observations(
                observations,
                self.fixture,
                self.fixture_checksum,
            )

    def test_late_publication_and_timing_regressions_block(self):
        observations = honest_observations(self.fixture, self.fixture_checksum)
        observations["scenarios"][0]["latePublicationCount"] = 1
        observations["scenarios"][0]["firstEvidenceMilliseconds"] = 2_001.0
        observations["scenarios"][0]["completionMilliseconds"] = 10_001.0

        scorecard = self.score(observations)

        self.assertEqual(scorecard["outcome"], "blocked")
        self.assertFalse(scorecard["gates"]["noLatePublication"])
        self.assertFalse(scorecard["gates"]["firstEvidenceBudget"])
        self.assertFalse(scorecard["gates"]["completionBudget"])

    def test_numeric_contract_rejects_bool_nan_and_negative_values(self):
        for value in (True, float("nan"), -1):
            with self.subTest(value=value):
                observations = honest_observations(
                    self.fixture, self.fixture_checksum
                )
                observations["scenarios"][0]["completionMilliseconds"] = value
                with self.assertRaises(validation.ApuntadorValidationError):
                    validation.validate_observations(
                        observations,
                        self.fixture,
                        self.fixture_checksum,
                    )

    def test_fixture_and_budget_checksums_are_bound_and_canonical(self):
        self.assertEqual(
            self.fixture_checksum,
            validation.CANONICAL_FIXTURE_SHA256,
        )
        self.assertEqual(
            validation.file_sha256(BUDGET_PATH),
            validation.CANONICAL_BUDGET_SHA256,
        )
        stale = budget_document()
        stale["fixtureChecksum"] = "0" * 64
        with self.assertRaisesRegex(
            validation.ApuntadorValidationError,
            "fixtureChecksum is stale",
        ):
            validation.validate_budget(stale, self.fixture_checksum)

        impossible_floor = budget_document()
        impossible_floor["quality"]["minimumOutcomeAccuracy"] = 1.01
        with self.assertRaisesRegex(
            validation.ApuntadorValidationError,
            "outside its finite range",
        ):
            validation.validate_budget(impossible_floor, self.fixture_checksum)

    def test_loader_rejects_duplicate_json_keys(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "duplicate.json"
            path.write_text('{"schemaVersion":1,"schemaVersion":1}')
            with self.assertRaisesRegex(
                validation.ApuntadorValidationError,
                "duplicate key: schemaVersion",
            ):
                validation.load_json(path, "fixture")

    def test_cli_scores_to_a_content_free_receipt_and_blocks_regression(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            observations = root / "observations.json"
            output = root / "scorecard.json"
            observations.write_text(json.dumps(
                honest_observations(self.fixture, self.fixture_checksum)
            ))

            passing = subprocess.run(
                [
                    str(ROOT / "scripts" / "apuntador_validation.py"),
                    "score",
                    "--fixture", str(FIXTURE_PATH),
                    "--budget", str(BUDGET_PATH),
                    "--observations", str(observations),
                    "--output", str(output),
                ],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(passing.returncode, 0, passing.stderr)
            self.assertEqual(json.loads(output.read_text())["outcome"], "pass")

            document = json.loads(observations.read_text())
            document["scenarios"][0]["latePublicationCount"] = 1
            observations.write_text(json.dumps(document))
            blocked = subprocess.run(
                [
                    str(ROOT / "scripts" / "apuntador_validation.py"),
                    "score",
                    "--fixture", str(FIXTURE_PATH),
                    "--budget", str(BUDGET_PATH),
                    "--observations", str(observations),
                    "--output", str(output),
                ],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(blocked.returncode, 1)
            self.assertEqual(json.loads(output.read_text())["outcome"], "blocked")

    def test_repository_wires_canonical_validation_without_product_composition(self):
        makefile = (ROOT / "Makefile").read_text(encoding="utf-8")
        hygiene = (ROOT / "scripts" / "check-repository-hygiene.sh").read_text(
            encoding="utf-8"
        )
        package = (ROOT / "Package.swift").read_text(encoding="utf-8")
        architecture = (ROOT / "docs" / "ARCHITECTURE.md").read_text(
            encoding="utf-8"
        )
        quality = (ROOT / "docs" / "specs" / "08-quality.md").read_text(
            encoding="utf-8"
        )

        self.assertIn("test-apuntador-validation:", makefile)
        self.assertIn(
            "python3 scripts/apuntador_validation.py verify-public",
            makefile,
        )
        self.assertIn(
            "python3 scripts/apuntador_web_fixture.py verify-public",
            makefile,
        )
        self.assertIn("Tests.Tooling.test_apuntador_validation", hygiene)
        self.assertIn("Tests.Tooling.test_apuntador_web_fixture", hygiene)
        self.assertIn("Autonomous assistant validation", architecture)
        self.assertIn("Autonomous Apuntador scenario authority", quality)
        self.assertNotIn("Fixtures/ApuntadorValidation", package)
        self.assertNotIn("Fixtures/ApuntadorWeb", package)


if __name__ == "__main__":
    unittest.main()
