import importlib.util
from pathlib import Path
import subprocess
import sys
import re
import tempfile
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
                   "PORTAVOZ_UI_INTERRUPTION_BLOCKED cleanup=complete reason=interruption\n".encode(),
            "summary": {"totalTestCount": 1, "skippedTests": 0, "failedTests": 1, "passedTests": 0},
            "effects": {"overlay-ready", "overlay-owner-exit"},
        }

    def test_expected_failure_is_not_a_product_pass(self):
        safety.validate_case(**self.evidence())

    def test_rejects_false_negative_controls(self):
        for mutation in ("exit-zero", "missing-ready", "missing-guard", "fallback", "continued",
                         "cleanup-failed", "cleanup-absent", "wrong-reason", "missing-reason", "choice",
                         "target", "typed", "empty-restart", "skipped", "extra-case", "helper-crashed",
                         "overlay-never-ready"):
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
                elif mutation == "cleanup-absent":
                    data["log"] = data["log"].replace(b"cleanup=complete", b"cleanup=absent")
                elif mutation == "wrong-reason":
                    data["log"] = data["log"].replace(b"reason=interruption", b"reason=keyboard-owner")
                elif mutation == "missing-reason":
                    data["log"] = data["log"].replace(b" reason=interruption", b"")
                elif mutation in ("choice", "target", "typed"):
                    data["effects"].add(mutation)
                elif mutation == "helper-crashed":
                    data["effects"].remove("overlay-owner-exit")
                elif mutation == "overlay-never-ready":
                    data["effects"].remove("overlay-ready")
                elif mutation == "empty-restart":
                    data["summary"]["totalTestCount"] = 0
                elif mutation == "skipped":
                    data["summary"]["skippedTests"] = 1
                else:
                    data["summary"]["totalTestCount"] = 2
                with self.assertRaises(RuntimeError):
                    safety.validate_case(**data)

    def test_keyboard_negative_controls_require_the_same_guard_and_no_effect(self):
        for name in ("testSynchronousTextInterruption", "testAsynchronousTextInterruption",
                     "testSynchronousTraversalInterruption", "testAsynchronousTraversalInterruption"):
            data = self.evidence()
            data["name"] = name
            with self.assertRaisesRegex(RuntimeError, "expected path"):
                safety.validate_case(**data)  # A monitor stop is not a keyboard-owner refusal.
            data["log"] = data["log"].replace(b"reason=interruption", b"reason=keyboard-owner")
            safety.validate_case(**data)
            data["effects"].add("typed")
            with self.assertRaises(RuntimeError):
                safety.validate_case(**data)
            data["effects"].remove("typed")
            data["log"] = data["log"].replace(b"PORTAVOZ_UI_INTERRUPTION_BLOCKED", b"")
            with self.assertRaises(RuntimeError):
                safety.validate_case(**data)

    def test_same_application_modal_does_not_expect_a_foreign_owner_receipt(self):
        for name in ("testSynchronousSameApplicationModalInterruption",
                     "testAsynchronousSameApplicationModalInterruption", "testSameApplicationModalRejectsBackgroundAnchor",
                     "testSynchronousAppModalDialogInterruption", "testAsynchronousAppModalDialogInterruption",
                     "testUnexpectedNativePickerRejectsTraversal", "testNativePickerRejectsBackgroundAnchor",
                     "testNativePickerRejectsAncestorAnchor"):
            with self.subTest(name=name):
                data = self.evidence()
                data.update(name=name, effects=set())
                data["log"] = data["log"].replace(b"reason=interruption", b"reason=modal-context")
                safety.validate_case(**data)
                for effect in ("modal-choice", "typed", "file-choice", "unexpected-file-choice"):
                    with self.assertRaises(RuntimeError):
                        safety.validate_case(**dict(data, effects={effect}))
                wrong_path = data["log"].replace(b"reason=modal-context", b"reason=keyboard-owner")
                with self.assertRaises(RuntimeError):
                    safety.validate_case(**dict(data, log=wrong_path))

    def test_every_negative_control_declares_one_stop_path(self):
        negative = {name for name, effects in safety.CASES.items() if not effects}
        self.assertEqual(set(safety.STOP_REASONS), negative)
        self.assertLessEqual(set(safety.STOP_REASONS.values()), {"interruption", "keyboard-owner", "modal-context"})
        swift = (ROOT / "Tests/PortavozUITests/UITestKeyboardSupport.swift").read_text()
        for reason in ("keyboard-owner", "modal-context"):
            self.assertIn(f'"{reason}"', swift)
        base = (ROOT / "Tests/PortavozUITests/PortavozUITestCase.swift").read_text()
        self.assertIn('stopForUnexpectedInterruption(reason: "interruption")', base)
        fixture = (ROOT / "Tests/UIInterruptionFixtures/Tests/InterruptionSafetyTests.swift").read_text()
        for name in safety.CASES:
            self.assertIn(f"func {name}()", fixture)

    def test_surviving_scratch_is_not_successful_cleanup(self):
        with mock.patch.object(Path, "exists", return_value=True), self.assertRaises(RuntimeError):
            safety.validate_case(**self.evidence())

    def test_positive_controls_calibrate_both_observable_effects(self):
        for name, effect in (("testSyntheticChoiceIsObservable", "choice"),
                             ("testUninterruptedActionAndTeardown", "target"),
                             ("testUninterruptedKeyboardInputAndTeardown", "typed"),
                             ("testSameApplicationModalChoiceIsObservable", "modal-choice"),
                             ("testAppModalDialogChoiceIsObservable", "modal-choice"),
                             ("testExpectedNativePickerChoiceIsObservable", "file-choice")):
            data = self.evidence()
            data.update(name=name, code=0, effects={effect})
            if name in ("testSameApplicationModalChoiceIsObservable", "testAppModalDialogChoiceIsObservable"):
                data["effects"].add("typed")
            if name == "testSyntheticChoiceIsObservable":
                data["effects"].update(["overlay-ready", "overlay-owner-exit"])
            data["log"] = data["log"].split(b"FIXTURE_INTERRUPTION_READY")[0]
            data["summary"].update(failedTests=0, passedTests=1)
            safety.validate_case(**data)
            data["effects"].clear()
            with self.assertRaises(RuntimeError):
                safety.validate_case(**data)

    def test_choice_does_not_prove_the_helper_completed_its_owner_exit_callback(self):
        data = self.evidence()
        data.update(name="testSyntheticChoiceIsObservable", code=0, effects={"choice", "overlay-ready"})
        data["summary"].update(failedTests=0, passedTests=1)
        data["log"] = data["log"].split(b"FIXTURE_INTERRUPTION_READY")[0]
        with self.assertRaisesRegex(RuntimeError, "missing synthetic action/lifecycle effect"):
            safety.validate_case(**data)

    def test_shared_sources_and_fixture_changes_select_controls_and_full_bilingual(self):
        for path in (*safety.SOURCE_PATHS, "scripts/check-ui-interruption-safety.py",
                     "Tests/UIInterruptionFixtures/Tests/InterruptionSafetyTests.swift"):
            selection = select_paths([path])
            self.assertTrue(selection.interruption_controls_required, path)
            self.assertTrue(selection.required, path)
            self.assertEqual(selection.locales, ("en", "es"), path)
            self.assertIn("interruption_controls=true", render(selection, "github"))
            self.assertIn("UI_TEST_INTERRUPTION_REQUIRED=true", render(selection, "shell"))
        self.assertFalse(select_paths([]).interruption_controls_required)
        self.assertFalse(select_paths(["Sources/portavoz-app/DictationPanel.swift"]).interruption_controls_required)

    def test_every_hashed_control_source_selects_the_controls(self):
        for relative in safety.source_hashes():
            with self.subTest(path=relative):
                self.assertTrue(select_paths([relative]).interruption_controls_required, relative)

    def test_unrelated_full_bilingual_fallbacks_do_not_run_the_controls(self):
        for path in ("Resources/Localization/Portavoz/Localizable.xcstrings", "scripts/ui_test_runtime.py",
                     "Tests/PortavozUITests/UITestSupport.swift"):
            with self.subTest(path=path):
                selection = select_paths([path])
                self.assertTrue(selection.required)
                self.assertEqual(selection.locales, ("en", "es"))
                self.assertFalse(selection.interruption_controls_required)
                self.assertIn("interruption_controls=false", render(selection, "github"))
        combined = select_paths(["Resources/Localization/Portavoz/Localizable.xcstrings",
                                 "Tests/PortavozUITests/UITestKeyboardSupport.swift"])
        self.assertTrue(combined.interruption_controls_required)

    def test_owned_process_listing_is_limited_to_this_invocation_products(self):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory).resolve()
            products = base / "build/Build/Products/Debug"
            ours = products / "InterruptionOverlay.app/Contents/MacOS/InterruptionOverlay"
            runner = products / "InterruptionProofTests-Runner.app/Contents/MacOS/InterruptionProofTests-Runner"
            elsewhere = base / "other/InterruptionOverlay.app/Contents/MacOS/InterruptionOverlay"
            ps_output = "\n".join((
                f"  101 {ours}", f"  102 {runner}", f"  103 {elsewhere}",
                "  104 /Applications/Portavoz.app/Contents/MacOS/portavoz-app", "garbage", "",
                f"  105 {products}/Unrelated.app/Contents/MacOS/Unrelated",
            ))
            self.assertEqual(safety.owned_fixture_processes(products, ps_output), [101, 102])

    def test_timed_out_control_fails_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            owned = output / "owned"
            owned.mkdir()
            calls = []

            def fake_command(args, log, *, environment, timeout):
                calls.append(args[0])
                if args[0] == "xcodebuild":
                    raise subprocess.TimeoutExpired(args, timeout)
                return 0

            with mock.patch.object(safety, "command", side_effect=fake_command):
                with self.assertRaisesRegex(RuntimeError, "exceeded its time limit"):
                    safety.run_case("testSynchronousInterruption", [], output, owned, {}, output / "products")
            self.assertEqual(calls, ["python3", "xcodebuild"])

    def test_run_stops_owned_processes_when_a_case_fails(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "evidence"
            shared = Path(directory) / "shared"
            with mock.patch.object(safety, "command", return_value=0), \
                    mock.patch.object(safety, "SHARED", shared), \
                    mock.patch.object(safety, "run_case", side_effect=RuntimeError("control failed")) as run_case, \
                    mock.patch.object(safety, "stop_owned_fixture_processes", return_value=[7]) as stop:
                with self.assertRaisesRegex(RuntimeError, "control failed"):
                    safety.run(output)
            run_case.assert_called_once()
            stop.assert_called_once()
            self.assertFalse((output / "qualification.json").exists())

    def test_stop_signals_owned_processes_and_escalates_only_for_survivors(self):
        alive = {11, 12}  # 12 ignores SIGTERM and needs escalation.
        signals = []

        def kill(pid, sig):
            signals.append((pid, sig))
            if sig == safety.signal.SIGKILL or pid == 11:
                alive.discard(pid)

        with mock.patch.object(safety, "list_owned_fixture_processes", side_effect=lambda _: sorted(alive)), \
                mock.patch.object(safety.os, "kill", side_effect=kill), \
                mock.patch.object(safety.time, "sleep"), \
                mock.patch.object(safety, "OWNED_STOP_GRACE_SECONDS", 0):
            self.assertEqual(safety.stop_owned_fixture_processes(Path("/nonexistent")), [11, 12])
        self.assertEqual(signals, [(11, safety.signal.SIGTERM), (12, safety.signal.SIGTERM),
                                   (12, safety.signal.SIGKILL)])
        self.assertEqual(alive, set())

        signals.clear()
        alive.update({21})
        with mock.patch.object(safety, "list_owned_fixture_processes", side_effect=lambda _: sorted(alive)), \
                mock.patch.object(safety.os, "kill", side_effect=lambda pid, sig: (signals.append((pid, sig)),
                                                                                  alive.discard(pid))), \
                mock.patch.object(safety.time, "sleep"):
            safety.stop_owned_fixture_processes(Path("/nonexistent"))
        self.assertEqual(signals, [(21, safety.signal.SIGTERM)], "a cooperative process is never SIGKILLed")


    def test_product_keyboard_dispatch_cannot_bypass_owned_admission(self):
        for path in (ROOT / "Tests/PortavozUITests").glob("*.swift"):
            if path.name == "UITestKeyboardSupport.swift":
                continue
            source = "\n".join(line for line in path.read_text().splitlines()
                               if not line.lstrip().startswith("//"))
            with self.subTest(path=path.name):
                self.assertEqual(re.findall(r"\.\s*type(?:Text|Key)\s*\(", source), [])
                if path.name.startswith("UITest"):
                    self.assertEqual(re.findall(r"(?<![\w.])type(?:Text|Key)\s*\(", source), [])

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
