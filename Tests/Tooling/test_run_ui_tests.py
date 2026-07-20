import os
import subprocess
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
    ) -> tuple[subprocess.CompletedProcess[str], list[str]]:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            binary = root / "bin"
            binary.mkdir()
            log = root / "xcodebuild.log"
            fake = binary / "xcodebuild"
            fake.write_text(
                "#!/bin/sh\nprintf '%s\\n' \"$*\" >> \"$XCODEBUILD_LOG\"\n",
                encoding="utf-8",
            )
            fake.chmod(0o755)

            environment = os.environ.copy()
            environment.update(
                {
                    "PATH": f"{binary}:{environment['PATH']}",
                    "UI_TEST_LOCALES": locales,
                    "UI_TEST_RESULTS_DIR": str(root / "results"),
                    "UI_TESTS": tests,
                    "XCODEBUILD_LOG": str(log),
                }
            )
            result = subprocess.run(
                [str(RUNNER)],
                cwd=ROOT,
                env=environment,
                check=False,
                capture_output=True,
                text=True,
            )
            calls = log.read_text(encoding="utf-8").splitlines()
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

    def test_default_locale_does_not_expand_an_empty_language_array(self):
        result, calls = self.run_runner("", locales="default")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(calls), 2)
        self.assertNotIn("-testLanguage", calls[1])
        self.assertIn("Running all tests in locale: default", result.stdout)


if __name__ == "__main__":
    unittest.main()
