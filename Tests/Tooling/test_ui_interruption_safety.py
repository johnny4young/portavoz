import importlib.util
from pathlib import Path
import sys
import unittest
from unittest import mock
import uuid


ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
spec = importlib.util.spec_from_file_location("ui_interruption_safety", ROOT / "scripts/check-ui-interruption-safety.py")
safety = importlib.util.module_from_spec(spec)
spec.loader.exec_module(safety)

from ui_test_scope import select_paths, render


class InterruptionSafetyTests(unittest.TestCase):
    def evidence(self):
        root = f"/private/tmp/portavoz-ui-tests/portavoz-ui-{uuid.uuid4()}"
        return {
            "name": "testAsynchronousInterruption", "code": 65,
            "log": f"FIXTURE_SCRATCH={root}/portavoz-ui-child\nFIXTURE_INTERRUPTION_READY\n"
                   "PORTAVOZ_UI_INTERRUPTION_BLOCKED cleanup=complete\n".encode(),
            "summary": {"totalTestCount": 1, "skippedTests": 0, "failedTests": 1, "passedTests": 0},
            "effects": set(),
        }

    def test_expected_failure_is_not_a_product_pass(self):
        safety.validate_case(**self.evidence())

    def test_rejects_false_negative_controls(self):
        for mutation in ("exit-zero", "missing-ready", "missing-guard", "fallback", "continued",
                         "cleanup-failed", "choice", "target", "empty-restart", "skipped", "extra-case"):
            with self.subTest(mutation=mutation):
                data = self.evidence()
                if mutation == "exit-zero":
                    data["code"] = 0
                elif mutation == "missing-ready":
                    data["log"] = data["log"].replace(b"FIXTURE_INTERRUPTION_READY", b"")
                elif mutation == "missing-guard":
                    data["log"] = data["log"].replace(b"PORTAVOZ_UI_INTERRUPTION_BLOCKED", b"")
                elif mutation in ("fallback", "continued"):
                    data["log"] += b"FIXTURE_FALLBACK_REACHED" if mutation == "fallback" else b"FIXTURE_TARGET_CONTINUED"
                elif mutation == "cleanup-failed":
                    data["log"] = data["log"].replace(b"cleanup=complete", b"cleanup=failed")
                elif mutation in ("choice", "target"):
                    data["effects"].add(mutation)
                elif mutation == "empty-restart":
                    data["summary"]["totalTestCount"] = 0
                elif mutation == "skipped":
                    data["summary"]["skippedTests"] = 1
                else:
                    data["summary"]["totalTestCount"] = 2
                with self.assertRaises(RuntimeError):
                    safety.validate_case(**data)

    def test_surviving_scratch_is_not_successful_cleanup(self):
        with mock.patch.object(Path, "exists", return_value=True), self.assertRaises(RuntimeError):
            safety.validate_case(**self.evidence())

    def test_positive_controls_calibrate_both_observable_effects(self):
        for name, effect in (("testSyntheticChoiceIsObservable", "choice"),
                             ("testUninterruptedActionAndTeardown", "target")):
            data = self.evidence()
            data.update(name=name, code=0, effects={effect})
            data["log"] = data["log"].split(b"FIXTURE_INTERRUPTION_READY")[0]
            data["summary"].update(failedTests=0, passedTests=1)
            safety.validate_case(**data)
            data["effects"].clear()
            with self.assertRaises(RuntimeError):
                safety.validate_case(**data)

    def test_shared_sources_and_fixture_changes_select_controls_and_full_bilingual(self):
        for path in (*safety.SOURCE_PATHS, "scripts/check-ui-interruption-safety.py",
                     "Tests/UIInterruptionFixtures/Tests/InterruptionSafetyTests.swift"):
            selection = select_paths([path])
            self.assertTrue(selection.interruption_controls_required, path)
            self.assertIn("interruption_controls=true", render(selection, "github"))
            self.assertIn("UI_TEST_INTERRUPTION_REQUIRED=true", render(selection, "shell"))
        self.assertFalse(select_paths([]).interruption_controls_required)
        self.assertFalse(select_paths(["Sources/portavoz-app/DictationPanel.swift"]).interruption_controls_required)

    def test_fixture_target_compiles_the_real_installation_and_cleanup(self):
        project = (ROOT / "Tests/UIInterruptionFixtures/project.yml").read_text()
        for path in safety.SOURCE_PATHS:
            self.assertIn("../" + path.removeprefix("Tests/"), project)
        fixture = (ROOT / "Tests/UIInterruptionFixtures/Tests/InterruptionSafetyTests.swift").read_text()
        self.assertIn("InterruptionSafetyTests: PortavozUITestCase", fixture)
        self.assertIn("try await super.setUp()", fixture)
        self.assertNotIn("stopForUnexpectedInterruption", fixture)


if __name__ == "__main__":
    unittest.main()
