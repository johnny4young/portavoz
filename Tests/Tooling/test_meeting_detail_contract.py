import copy
import importlib.util
import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


REPOSITORY = Path(__file__).resolve().parents[2]
SCRIPT = REPOSITORY / "scripts" / "meeting_detail_contract.py"
SPEC = importlib.util.spec_from_file_location("meeting_detail_contract", SCRIPT)
contract = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(contract)


class MeetingDetailContractTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        paths = [
            *contract.INTERACTION_SOURCE_PATHS,
            str(contract.UI_TEST_SOURCE.relative_to(REPOSITORY)),
            *contract.PERFORMANCE_EVIDENCE_PATHS,
        ]
        for relative_path in paths:
            source = REPOSITORY / relative_path
            destination = self.root / relative_path
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, destination)
        self.document = contract.read_json(contract.DEFAULT_CONTRACT)

    def tearDown(self):
        self.temporary.cleanup()

    def test_tracked_contract_is_current_and_complete(self):
        validated = contract.validate_contract(self.document, REPOSITORY)

        self.assertEqual(validated["requiredLocales"], ["en", "es"])
        self.assertEqual(
            validated["interactionSources"],
            list(contract.INTERACTION_SOURCE_PATHS),
        )
        self.assertEqual(len(validated["featureOwnership"]), 11)
        self.assertEqual(
            sum(len(owner["tests"]) for owner in validated["featureOwnership"]),
            24,
        )
        self.assertEqual(
            validated["performanceMeasurementLimitations"],
            list(contract.PERFORMANCE_MEASUREMENT_LIMITATIONS),
        )

    def test_source_interaction_change_requires_a_reviewed_snapshot(self):
        source = self.root / "Sources/portavoz-app/MeetingPlayerBar.swift"
        source.write_text(
            source.read_text(encoding="utf-8")
            + '\nprivate let unexpected = Button("Unreviewed") {}\n',
            encoding="utf-8",
        )

        with self.assertRaisesRegex(contract.ContractError, "interaction signals differ"):
            contract.validate_contract(self.document, self.root)

    def test_boundary_source_locale_and_measurement_limit_sets_are_closed(self):
        for field, value, message in (
            (
                "interactionSources",
                self.document["interactionSources"][:-1],
                "reviewed boundary",
            ),
            ("requiredLocales", ["en"], "cover en and es"),
            (
                "performanceMeasurementLimitations",
                self.document["performanceMeasurementLimitations"][:-1],
                "changed or hidden",
            ),
        ):
            changed = copy.deepcopy(self.document)
            changed[field] = value
            with self.subTest(field=field):
                with self.assertRaisesRegex(contract.ContractError, message):
                    contract.validate_contract(changed, self.root)

    def test_every_ui_journey_has_exactly_one_owner(self):
        tests_source = self.root / "Tests/PortavozUITests/MeetingDetailUITests.swift"
        tests_source.write_text(
            tests_source.read_text(encoding="utf-8")
            + "\nextension MeetingDetailUITests {\n"
            + "    func testNewJourney() {}\n"
            + "}\n",
            encoding="utf-8",
        )
        with self.assertRaisesRegex(contract.ContractError, "missing=.*testNewJourney"):
            contract.validate_contract(self.document, self.root)

        duplicated = copy.deepcopy(self.document)
        repeated = "testMostRecentRecipeRemainsVisibleAfterReload"
        duplicated["featureOwnership"][0]["tests"].append(repeated)
        duplicated["featureOwnership"][0]["tests"].sort()
        with self.assertRaisesRegex(contract.ContractError, "multiple owners"):
            contract.validate_contract(duplicated, REPOSITORY)

    def test_screenshot_ownership_is_derived_from_each_test_body(self):
        changed = copy.deepcopy(self.document)
        owner = next(
            item
            for item in changed["featureOwnership"]
            if item["feature"] == "detail-scale"
        )
        owner["screenshots"] = []

        with self.assertRaisesRegex(contract.ContractError, "screenshot ownership differs"):
            contract.validate_contract(changed, self.root)

    def test_feature_source_anchors_must_exist_inside_the_boundary(self):
        changed = copy.deepcopy(self.document)
        changed["featureOwnership"][0]["sourceAnchors"][0]["anchor"] = "missing-anchor"

        with self.assertRaisesRegex(contract.ContractError, "source anchor is missing"):
            contract.validate_contract(changed, self.root)

        changed = copy.deepcopy(self.document)
        changed["featureOwnership"][0]["sourceAnchors"][0]["path"] = "README.md"
        with self.assertRaisesRegex(contract.ContractError, "outside the reviewed boundary"):
            contract.validate_contract(changed, self.root)

    def test_performance_evidence_is_path_and_digest_bound(self):
        evidence = self.root / contract.PERFORMANCE_EVIDENCE_PATHS[0]
        evidence.write_text("{}\n", encoding="utf-8")

        with self.assertRaisesRegex(contract.ContractError, "evidence digest changed"):
            contract.validate_contract(self.document, self.root)

        changed = copy.deepcopy(self.document)
        changed["performanceEvidence"] = changed["performanceEvidence"][:-1]
        with self.assertRaisesRegex(contract.ContractError, "paths do not match"):
            contract.validate_contract(changed, REPOSITORY)

    def test_unknown_and_duplicate_json_keys_fail_closed(self):
        changed = copy.deepcopy(self.document)
        changed["unreviewed"] = True
        with self.assertRaisesRegex(contract.ContractError, "unknown=.*unreviewed"):
            contract.validate_contract(changed, REPOSITORY)

        duplicate = self.root / "duplicate.json"
        duplicate.write_text(
            '{"schemaVersion":1,"schemaVersion":1}\n',
            encoding="utf-8",
        )
        with self.assertRaisesRegex(contract.ContractError, "duplicate JSON key"):
            contract.read_json(duplicate)

    def test_snapshot_is_canonical_and_round_trips(self):
        output = self.root / "candidate.json"
        contract.write_snapshot(output, REPOSITORY)
        self.assertEqual(
            contract.validate_contract(contract.read_json(output), REPOSITORY),
            self.document,
        )
        self.assertTrue(output.read_text(encoding="utf-8").endswith("\n"))

    def test_verify_cli_reports_the_reviewed_counts(self):
        result = subprocess.run(
            [sys.executable, str(SCRIPT), "verify"],
            cwd=REPOSITORY,
            check=False,
            capture_output=True,
            text=True,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertRegex(
            result.stdout,
            r"\d+ signals, 11 owners, 24 UI tests",
        )


if __name__ == "__main__":
    unittest.main()
