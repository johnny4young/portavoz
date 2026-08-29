import copy
import importlib.util
import json
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "live_assist_validation", ROOT / "scripts" / "live_assist_validation.py"
)
validation = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(validation)
FIXTURE_PATH = ROOT / "Fixtures" / "LiveAssistValidation" / "public-bilingual-v1.json"
BUDGET_PATH = ROOT / "docs" / "evidence" / "live-assist-validation-budget.json"


def raw_fixture():
    return json.loads(FIXTURE_PATH.read_text(encoding="utf-8"))


def raw_budget():
    return json.loads(BUDGET_PATH.read_text(encoding="utf-8"))


def perfect_observations(fixture, checksum):
    question = []
    for session in fixture["sessions"].values():
        for event_id, event in session["events"].items():
            decision = {
                "question": "prompt",
                "nonQuestion": "ignore",
                "abstain": "abstain",
            }[event["expectedDecision"]]
            question.append({"eventID": event_id, "decision": decision})
    return {
        "schemaVersion": 1,
        "kind": validation.OBSERVATION_KIND,
        "fixtureGeneration": validation.GENERATION,
        "fixtureChecksum": checksum,
        "adapter": {
            "id": "oracle-control",
            "version": "1.0.0",
            "class": "released-prefilter",
            "installedModel": False,
        },
        "run": {
            "commit": "a" * 40,
            "build": "debug-tests",
            "platform": "macos",
            "osVersion": "26.5.2",
            "architecture": "arm64",
            "sourceState": "clean",
        },
        "questionEvents": question,
        "interviewScenarios": [
            {
                "scenarioID": scenario_id,
                "questionID": expected["questionID"],
                "evidenceIDs": expected["evidenceIDs"],
            }
            for scenario_id, expected in fixture["interviews"].items()
        ],
        "rollingSummaryScenarios": [
            {
                "scenarioID": scenario_id,
                "selectedIDs": expected["selectedIDs"],
                "hasBacklog": expected["backlog"],
                "checkpointIDs": expected["selectedIDs"],
                "checkpointLanguage": expected["language"],
                "checkpointCharacterCount": 1,
            }
            for scenario_id, expected in fixture["summaries"].items()
        ],
        "translationScenarios": [
            {
                "scenarioID": scenario_id,
                "pair": expected["pair"],
                "pendingIDs": expected["pendingIDs"],
                "installedAssetAction": "translate",
                "downloadableAssetAction": "requestDownloadConsent",
                "retryDelaysMilliseconds": [1000, 2000, 4000, 8000, 8000],
                "invalidPublicationCount": 0,
            }
            for scenario_id, expected in fixture["translations"].items()
        ],
        "faultScenarios": [
            {
                "scenarioID": scenario_id,
                "outcome": expected["outcome"],
                "latePublicationCount": 0,
            }
            for scenario_id, expected in fixture["faults"].items()
        ],
        "timings": {
            domain: {
                "firstResultMilliseconds": 1.0,
                "steadyStateMilliseconds": [0.1] * 8,
            }
            for domain in validation.DOMAINS
        },
        "resources": {
            "iterations": 8,
            "wallDurationMilliseconds": 20.0,
            "cpuTimeMilliseconds": 10.0,
            "initialPhysicalFootprintBytes": 100_000_000,
            "finalPhysicalFootprintBytes": 100_100_000,
            "peakPhysicalFootprintBytes": 101_000_000,
            "energyNanojoules": 1_000_000,
            "maximumThermalState": "nominal",
            "powerSource": "ac",
            "lowPowerModeEnabled": False,
        },
    }


class LiveAssistValidationTests(unittest.TestCase):
    def test_bundled_model_identity_is_accepted_but_cannot_claim_model_free(self):
        observations = perfect_observations(self.fixture, self.checksum)
        observations["adapter"] = {
            "id": "portavoz-live-question-maxent-en-es-v1",
            "version": "1.0.0",
            "class": "bundled-model",
            "installedModel": True,
        }
        validated = validation.validate_observations(
            observations, self.fixture, self.checksum)
        self.assertEqual(validated["adapter"]["class"], "bundled-model")

        observations["adapter"]["installedModel"] = False
        with self.assertRaisesRegex(
            validation.LiveAssistValidationError,
            "adapter model identity differs",
        ):
            validation.validate_observations(
                observations, self.fixture, self.checksum)

    def setUp(self):
        self.fixture_document = raw_fixture()
        self.fixture = validation.validate_fixture(self.fixture_document)
        self.checksum = validation.file_sha256(FIXTURE_PATH)
        self.budget = validation.validate_budget(raw_budget(), self.checksum)

    def score(self, document):
        observations = validation.validate_observations(
            document, self.fixture, self.checksum
        )
        return validation.evaluate(
            self.fixture, self.checksum, observations, self.budget
        )

    def test_fixture_freezes_every_live_assistance_surface(self):
        self.assertEqual(len(self.fixture["sessions"]), 4)
        self.assertEqual(
            sum(len(item["events"]) for item in self.fixture["sessions"].values()),
            32,
        )
        self.assertEqual(self.fixture["exposureSeconds"], 7_200)
        self.assertEqual(len(self.fixture["interviews"]), 7)
        self.assertEqual(len(self.fixture["summaries"]), 5)
        self.assertEqual(len(self.fixture["translations"]), 6)
        self.assertEqual(len(self.fixture["faults"]), 8)
        profiles = {item["profile"] for item in self.fixture["sessions"].values()}
        self.assertEqual(profiles, validation.PROFILES)

    def test_question_ground_truth_is_balanced_per_profile(self):
        for session in self.fixture["sessions"].values():
            self.assertEqual(
                sorted(event["expectedDecision"] for event in session["events"].values()),
                ["abstain", "abstain", "nonQuestion", "nonQuestion", "nonQuestion", "question", "question", "question"],
            )

    def test_fixture_rejects_duplicate_identity_and_scope_drift(self):
        invalid = copy.deepcopy(self.fixture_document)
        invalid["questionSessions"][0]["events"][1]["id"] = invalid["questionSessions"][0]["events"][0]["id"]
        with self.assertRaisesRegex(validation.LiveAssistValidationError, "duplicate fixture identity"):
            validation.validate_fixture(invalid)

        invalid = copy.deepcopy(self.fixture_document)
        invalid["translationScenarios"][0]["expectedPendingIDs"] = [
            invalid["interviewScenarios"][0]["segments"][0]["id"]
        ]
        with self.assertRaisesRegex(validation.LiveAssistValidationError, "unknown identity"):
            validation.validate_fixture(invalid)

    def test_perfect_content_free_measurement_passes_targets(self):
        scorecard = self.score(perfect_observations(self.fixture, self.checksum))
        encoded = json.dumps(scorecard, sort_keys=True)
        self.assertEqual(scorecard["measurementStatus"], "complete")
        self.assertEqual(scorecard["servingCandidateStatus"], "pass")
        self.assertTrue(all(scorecard["gates"].values()))
        self.assertEqual(scorecard["metrics"]["falsePromptsPerHour"], 0)
        self.assertEqual(scorecard["authority"], "controlled-local")
        for forbidden in (
            "questionSessions",
            "Could you explain",
            "El presupuesto",
            "referenceSummary",
            "answerText",
        ):
            self.assertNotIn(forbidden, encoded)

    def test_false_prompts_missed_questions_and_no_abstention_are_below_target(self):
        observations = perfect_observations(self.fixture, self.checksum)
        question_ids = [
            row["eventID"] for row in observations["questionEvents"]
            if self._expected(question_id=row["eventID"]) == "question"
        ][:2]
        non_question_ids = [
            row["eventID"] for row in observations["questionEvents"]
            if self._expected(question_id=row["eventID"]) == "nonQuestion"
        ][:2]
        abstain_ids = [
            row["eventID"] for row in observations["questionEvents"]
            if self._expected(question_id=row["eventID"]) == "abstain"
        ][:2]
        by_id = {row["eventID"]: row for row in observations["questionEvents"]}
        for event_id in question_ids:
            by_id[event_id]["decision"] = "ignore"
        for event_id in non_question_ids:
            by_id[event_id]["decision"] = "prompt"
        for event_id in abstain_ids:
            by_id[event_id]["decision"] = "ignore"

        scorecard = self.score(observations)

        self.assertEqual(scorecard["measurementStatus"], "complete")
        self.assertEqual(scorecard["servingCandidateStatus"], "belowTarget")
        self.assertFalse(scorecard["gates"]["falsePromptsPerHour"])
        self.assertFalse(scorecard["gates"]["abstentionAccuracy"])

    def test_scenario_inventory_must_be_exact_and_unique(self):
        observations = perfect_observations(self.fixture, self.checksum)
        observations["interviewScenarios"].pop()
        with self.assertRaisesRegex(validation.LiveAssistValidationError, "must contain"):
            validation.validate_observations(observations, self.fixture, self.checksum)

        observations = perfect_observations(self.fixture, self.checksum)
        observations["questionEvents"][1]["eventID"] = observations["questionEvents"][0]["eventID"]
        with self.assertRaisesRegex(validation.LiveAssistValidationError, "duplicate or unknown"):
            validation.validate_observations(observations, self.fixture, self.checksum)

    def test_late_publication_and_fault_outcome_remain_blocking_targets(self):
        observations = perfect_observations(self.fixture, self.checksum)
        observations["faultScenarios"][0]["latePublicationCount"] = 1
        observations["faultScenarios"][1]["outcome"] = "cancelled"
        scorecard = self.score(observations)
        self.assertEqual(scorecard["servingCandidateStatus"], "belowTarget")
        self.assertFalse(scorecard["gates"]["noLatePublication"])
        self.assertFalse(scorecard["gates"]["faultOutcomeAccuracy"])

    def test_checkpoint_and_translation_reliability_are_blocking_targets(self):
        observations = perfect_observations(self.fixture, self.checksum)
        observations["rollingSummaryScenarios"][0]["checkpointIDs"] = []
        observations["translationScenarios"][0]["invalidPublicationCount"] = 1
        observations["translationScenarios"][1]["retryDelaysMilliseconds"] = [
            1, 1, 1, 1, 1,
        ]

        scorecard = self.score(observations)

        self.assertEqual(scorecard["servingCandidateStatus"], "belowTarget")
        self.assertFalse(scorecard["gates"]["summaryPolicyExactAccuracy"])
        self.assertFalse(scorecard["gates"]["translationPolicyExactAccuracy"])

    def test_runtime_evidence_rejects_nan_bool_and_impossible_peak(self):
        for value in (True, float("nan"), -1):
            with self.subTest(value=value):
                observations = perfect_observations(self.fixture, self.checksum)
                observations["timings"]["interview"]["firstResultMilliseconds"] = value
                with self.assertRaises(validation.LiveAssistValidationError):
                    validation.validate_observations(observations, self.fixture, self.checksum)
        observations = perfect_observations(self.fixture, self.checksum)
        observations["resources"]["peakPhysicalFootprintBytes"] = 1
        with self.assertRaisesRegex(validation.LiveAssistValidationError, "peak is inconsistent"):
            validation.validate_observations(observations, self.fixture, self.checksum)

        observations = perfect_observations(self.fixture, self.checksum)
        observations["timings"]["questionDetection"]["steadyStateMilliseconds"].pop()
        with self.assertRaisesRegex(validation.LiveAssistValidationError, "sample count differs"):
            validation.validate_observations(observations, self.fixture, self.checksum)

    def test_dirty_or_thermally_loaded_run_is_informational(self):
        observations = perfect_observations(self.fixture, self.checksum)
        observations["run"]["sourceState"] = "dirty"
        observations["resources"]["maximumThermalState"] = "fair"
        scorecard = self.score(observations)
        self.assertEqual(scorecard["authority"], "informational")

        observations = perfect_observations(self.fixture, self.checksum)
        observations["resources"]["powerSource"] = "battery"
        scorecard = self.score(observations)
        self.assertEqual(scorecard["authority"], "informational")

    def test_canonical_checksums_and_duplicate_key_loader_are_fail_closed(self):
        self.assertEqual(self.checksum, validation.CANONICAL_FIXTURE_SHA256)
        self.assertEqual(
            validation.file_sha256(BUDGET_PATH),
            validation.CANONICAL_BUDGET_SHA256,
        )
        stale = raw_budget()
        stale["fixtureChecksum"] = "0" * 64
        with self.assertRaisesRegex(validation.LiveAssistValidationError, "stale"):
            validation.validate_budget(stale, self.checksum)
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "duplicate.json"
            path.write_text('{"schemaVersion":1,"schemaVersion":1}')
            with self.assertRaisesRegex(validation.LiveAssistValidationError, "duplicate key"):
                validation.load_json(path, "fixture")

    def test_cli_scores_complete_baseline_but_can_require_targets(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            observations_path = root / "observations.json"
            scorecard_path = root / "scorecard.json"
            observations = perfect_observations(self.fixture, self.checksum)
            false_prompts = [
                row for row in observations["questionEvents"]
                if self._expected(question_id=row["eventID"]) == "nonQuestion"
            ][:2]
            for row in false_prompts:
                row["decision"] = "prompt"
            observations_path.write_text(json.dumps(observations))
            command = [
                str(ROOT / "scripts" / "live_assist_validation.py"),
                "score",
                "--fixture", str(FIXTURE_PATH),
                "--budget", str(BUDGET_PATH),
                "--observations", str(observations_path),
                "--output", str(scorecard_path),
            ]
            baseline = subprocess.run(command, check=False, capture_output=True, text=True)
            self.assertEqual(baseline.returncode, 0, baseline.stderr)
            self.assertEqual(json.loads(scorecard_path.read_text())["servingCandidateStatus"], "belowTarget")
            required_output = root / "required-scorecard.json"
            required_command = command.copy()
            required_command[-1] = str(required_output)
            required = subprocess.run(required_command + ["--require-targets"], check=False, capture_output=True, text=True)
            self.assertEqual(required.returncode, 1)

    def test_scorecard_writer_never_replaces_existing_evidence(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "scorecard.json"
            validation.write_json(output, {"state": "first"})
            first = output.read_bytes()
            with self.assertRaisesRegex(
                validation.LiveAssistValidationError,
                "already exists",
            ):
                validation.write_json(output, {"state": "second"})
            self.assertEqual(output.read_bytes(), first)
            self.assertEqual(output.stat().st_mode & 0o777, 0o600)

    def _expected(self, question_id):
        return next(
            event["expectedDecision"]
            for session in self.fixture["sessions"].values()
            for event_id, event in session["events"].items()
            if event_id == question_id
        )


if __name__ == "__main__":
    unittest.main()
