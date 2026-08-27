import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
RUNNER = ROOT / "scripts" / "run-ui-tests.sh"


class RunUITestsTests(unittest.TestCase):
    def run_runner(
        self,
        tests: str,
        locales: str = "en",
        developer_dir: str | None = None,
        selected_developer_dir: str = "/Applications/Xcode_26.0.app/Contents/Developer",
        test_exit_code: int = 0,
        initial_keyboard_mode: str | None = "0",
        require_runtime_receipt: bool = False,
    ) -> tuple[subprocess.CompletedProcess[str], list[str]]:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            binary = root / "bin"
            binary.mkdir()
            log = root / "xcodebuild.log"
            fake = binary / "xcodebuild"
            fake.write_text(
                "#!/bin/sh\n"
                "printf 'DEVELOPER_DIR=%s | %s | WEB_FIXTURE_PAYLOAD_LENGTH=%s "
                "| TEST_RUNNER_WEB_FIXTURE_PAYLOAD_LENGTH=%s | PORTAVOZ_UI_TEST_LOCALE=%s "
                "| TEST_RUNNER_PORTAVOZ_UI_TEST_LOCALE=%s\\n' "
                "\"${DEVELOPER_DIR:-unset}\" \"$*\" "
                "\"${#PORTAVOZ_UI_WEB_FIXTURE_PAYLOAD}\" "
                "\"${#TEST_RUNNER_PORTAVOZ_UI_WEB_FIXTURE_PAYLOAD}\" "
                "\"${PORTAVOZ_UI_TEST_LOCALE:-unset}\" "
                "\"${TEST_RUNNER_PORTAVOZ_UI_TEST_LOCALE:-unset}\" "
                ">> \"$XCODEBUILD_LOG\"\n"
                "previous=''\n"
                "for argument in \"$@\"; do\n"
                "  if [ \"$previous\" = '-resultBundlePath' ]; then\n"
                "    mkdir -p \"$argument\"\n"
                "  fi\n"
                "  previous=\"$argument\"\n"
                "done\n"
                "case \"$*\" in *test-without-building*) "
                "exit \"$XCODEBUILD_TEST_EXIT_CODE\" ;; esac\n",
                encoding="utf-8",
            )
            fake.chmod(0o755)
            fake_xcode_select = binary / "xcode-select"
            fake_xcode_select.write_text(
                "#!/bin/sh\n"
                "test \"$1\" = '-p' || exit 2\n"
                "printf '%s\\n' \"$XCODE_SELECT_PATH\"\n",
                encoding="utf-8",
            )
            fake_xcode_select.chmod(0o755)
            defaults_log = root / "defaults.log"
            fake_defaults = binary / "defaults"
            fake_defaults.write_text(
                "#!/bin/sh\n"
                "printf '%s\\n' \"$*\" >> \"$DEFAULTS_LOG\"\n"
                "if [ \"$1\" = read ]; then\n"
                "  [ \"$DEFAULTS_MODE_PRESENT\" = true ] || exit 1\n"
                "  printf '%s\\n' \"$DEFAULTS_INITIAL_MODE\"\n"
                "fi\n",
                encoding="utf-8",
            )
            fake_defaults.chmod(0o755)
            fake_xcrun = binary / "xcrun"
            fake_xcrun.write_text(
                "#!/bin/sh\n"
                "cat <<'JSON'\n"
                '{"nodes":[{"nodeType":"Test Case",'
                '"nodeIdentifier":"LibraryUITests/testLibrary()",'
                '"name":"testLibrary()","durationInSeconds":1.0,'
                '"result":"Passed"}]}\n'
                "JSON\n",
                encoding="utf-8",
            )
            fake_xcrun.chmod(0o755)
            fake_python = binary / "python3"
            fake_python.write_text(
                "#!/bin/sh\n"
                "exec \"$REAL_PYTHON\" \"$@\"\n",
                encoding="utf-8",
            )
            fake_python.chmod(0o755)
            runtime_budget = root / "runtime-budget.json"
            runtime_budget.write_text(
                '{"catalog":{"expectedCaseCount":1},'
                '"fullSuite":{"maximumTestDurationSecondsPerLocale":10.0,'
                '"maximumP95Seconds":10.0},'
                '"testBudgetsSeconds":{"LibraryUITests/testLibrary()":10.0}}',
                encoding="utf-8",
            )

            environment = os.environ.copy()
            environment.pop("DEVELOPER_DIR", None)
            environment.pop("PORTAVOZ_UI_TEST_LOCALE", None)
            environment.pop("TEST_RUNNER_PORTAVOZ_UI_TEST_LOCALE", None)
            environment.pop("PORTAVOZ_UI_WEB_FIXTURE_PAYLOAD", None)
            environment.pop(
                "TEST_RUNNER_PORTAVOZ_UI_WEB_FIXTURE_PAYLOAD", None
            )
            environment.update(
                {
                    "PATH": f"{binary}:{environment['PATH']}",
                    "UI_TEST_LOCALES": locales,
                    "UI_TEST_RESULTS_DIR": str(root / "results"),
                    "UI_TESTS": tests,
                    "XCODEBUILD_LOG": str(log),
                    "XCODEBUILD_TEST_EXIT_CODE": str(test_exit_code),
                    "XCODE_SELECT_PATH": selected_developer_dir,
                    "DEFAULTS_LOG": str(defaults_log),
                    "DEFAULTS_INITIAL_MODE": initial_keyboard_mode or "",
                    "DEFAULTS_MODE_PRESENT": str(
                        initial_keyboard_mode is not None
                    ).lower(),
                    "UI_TEST_REQUIRE_RUNTIME_RECEIPT": str(
                        require_runtime_receipt
                    ).lower(),
                    "UI_TEST_RUNTIME_BUDGET": str(runtime_budget),
                    "REAL_PYTHON": sys.executable,
                }
            )
            if developer_dir is not None:
                environment["DEVELOPER_DIR"] = developer_dir
            result = subprocess.run(
                [str(RUNNER)],
                cwd=ROOT,
                env=environment,
                check=False,
                capture_output=True,
                text=True,
            )
            calls = log.read_text(encoding="utf-8").splitlines()
            self.defaults_calls = (
                defaults_log.read_text(encoding="utf-8").splitlines()
                if defaults_log.exists()
                else []
            )
            self.runtime_receipts = {
                path.name: path.read_text(encoding="utf-8")
                for path in (root / "results").glob("*-runtime.json")
            }
            return result, calls

    def test_empty_selector_runs_the_complete_suite(self):
        result, calls = self.run_runner("")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(calls), 2)
        self.assertIn("build-for-testing", calls[0])
        self.assertIn("test-without-building", calls[1])
        self.assertNotIn("-only-testing:", calls[1])
        self.assertIn("Running all tests in locale: en", result.stdout)

    def test_explicit_selector_is_forwarded(self):
        selector = "PortavozUITests/LibraryUITests/testSeededMeetingsGroupByRecency"
        result, calls = self.run_runner(selector)

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(calls), 2)
        self.assertIn(f"-only-testing:{selector}", calls[1])
        self.assertIn("Running 1 scoped selectors in locale: en", result.stdout)
        self.assertEqual(self.defaults_calls, [])

    def test_web_journey_uses_one_validated_payload_after_the_shared_build(self):
        selector = (
            "PortavozUITests/LibraryUITests/"
            "testAskConversationAnswersAndSeeksToExactCitation"
        )
        result, calls = self.run_runner(selector, locales="en es")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(calls), 3)
        self.assertIn("WEB_FIXTURE_PAYLOAD_LENGTH=0", calls[0])
        for call in calls[1:]:
            self.assertRegex(call, r"WEB_FIXTURE_PAYLOAD_LENGTH=[1-9][0-9]+")
            self.assertRegex(
                call,
                r"TEST_RUNNER_WEB_FIXTURE_PAYLOAD_LENGTH=[1-9][0-9]+",
            )

    def test_unrelated_scope_does_not_load_the_web_fixture(self):
        selector = "PortavozUITests/LibraryUITests/testSeededMeetingsGroupByRecency"
        result, calls = self.run_runner(selector)

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(
            all("WEB_FIXTURE_PAYLOAD_LENGTH=0" in call for call in calls)
        )

    def test_complete_suite_restores_keyboard_navigation(self):
        result, _ = self.run_runner("")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            self.defaults_calls,
            [
                "read -g AppleKeyboardUIMode",
                "write -g AppleKeyboardUIMode -int 3",
                "write -g AppleKeyboardUIMode -int 0",
            ],
        )

    def test_focused_keyboard_journey_restores_preference_after_failure(self):
        selector = (
            "PortavozUITests/SkillsSettingsUITests/"
            "testSkillReceiptRestoresKeyboardFocusAndPassesAccessibilityAudit"
        )
        result, _ = self.run_runner(selector, test_exit_code=65)

        self.assertEqual(result.returncode, 65)
        self.assertEqual(
            self.defaults_calls,
            [
                "read -g AppleKeyboardUIMode",
                "write -g AppleKeyboardUIMode -int 3",
                "write -g AppleKeyboardUIMode -int 0",
            ],
        )

    def test_complete_suite_removes_keyboard_mode_when_it_was_absent(self):
        result, _ = self.run_runner("", initial_keyboard_mode=None)

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            self.defaults_calls,
            [
                "read -g AppleKeyboardUIMode",
                "write -g AppleKeyboardUIMode -int 3",
                "delete -g AppleKeyboardUIMode",
            ],
        )

    def test_default_locale_does_not_expand_an_empty_language_array(self):
        result, calls = self.run_runner("", locales="default")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(calls), 2)
        self.assertNotIn("-testLanguage", calls[1])
        self.assertTrue(
            calls[1].endswith(
                "| PORTAVOZ_UI_TEST_LOCALE=unset "
                "| TEST_RUNNER_PORTAVOZ_UI_TEST_LOCALE=unset"
            )
        )
        self.assertIn("Running all tests in locale: default", result.stdout)

    def test_explicit_locale_reaches_each_test_runner_process(self):
        result, calls = self.run_runner("", locales="en es")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(calls), 3)
        self.assertTrue(
            calls[1].endswith(
                "| PORTAVOZ_UI_TEST_LOCALE=en "
                "| TEST_RUNNER_PORTAVOZ_UI_TEST_LOCALE=en"
            )
        )
        self.assertTrue(
            calls[2].endswith(
                "| PORTAVOZ_UI_TEST_LOCALE=es "
                "| TEST_RUNNER_PORTAVOZ_UI_TEST_LOCALE=es"
            )
        )

    def test_active_xcode_select_toolchain_is_not_overridden(self):
        result, calls = self.run_runner("")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(all(call.startswith("DEVELOPER_DIR=unset |") for call in calls))

    def test_explicit_developer_dir_is_preserved(self):
        developer_dir = "/Applications/Xcode_Custom.app/Contents/Developer"
        result, calls = self.run_runner("", developer_dir=developer_dir)

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(
            all(call.startswith(f"DEVELOPER_DIR={developer_dir} |") for call in calls)
        )

    def test_command_line_tools_selection_falls_back_to_full_xcode(self):
        result, calls = self.run_runner(
            "", selected_developer_dir="/Library/Developer/CommandLineTools"
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(
            all(
                call.startswith(
                    "DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer |"
                )
                for call in calls
            )
        )

    def test_real_runner_reuses_one_build_and_requires_runtime_receipts(self):
        source = RUNNER.read_text(encoding="utf-8")

        self.assertEqual(source.count("xcodebuild build-for-testing"), 1)
        self.assertIn("xcodebuild test-without-building", source)
        self.assertIn("UI_TEST_REQUIRE_RUNTIME_RECEIPT:-true", source)
        self.assertIn("scripts/ui_test_runtime.py", source)
        self.assertIn("-resultBundlePath", source)

    def test_failed_xctest_still_emits_receipt_and_preserves_exit_code(self):
        selector = "PortavozUITests/LibraryUITests/testLibrary"
        result, _ = self.run_runner(
            selector,
            test_exit_code=65,
            require_runtime_receipt=True,
        )

        self.assertEqual(result.returncode, 65)
        self.assertIn("en-runtime.json", self.runtime_receipts)
        self.assertEqual(
            json.loads(self.runtime_receipts["en-runtime.json"])["budgetStatus"],
            "passed",
        )


if __name__ == "__main__":
    unittest.main()
