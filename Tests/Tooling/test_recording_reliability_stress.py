import os
import pathlib
import subprocess
import tempfile
import textwrap
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "run-recording-reliability-stress.sh"


class RecordingReliabilityStressTests(unittest.TestCase):
    def run_script(self, fake_swift: str, *arguments: str):
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary = pathlib.Path(temporary_directory)
            binary_directory = temporary / "bin"
            binary_directory.mkdir()
            invocation_log = temporary / "invocations"
            log_directory = temporary / "stress-logs"
            swift = binary_directory / "swift"
            swift.write_text(
                "#!/usr/bin/env bash\nset -euo pipefail\n" + fake_swift,
                encoding="utf-8",
            )
            swift.chmod(0o755)

            environment = os.environ.copy()
            environment.update(
                {
                    "PATH": f"{binary_directory}:{environment['PATH']}",
                    "FAKE_SWIFT_INVOCATIONS": str(invocation_log),
                    "PORTAVOZ_STRESS_LOG_DIR": str(log_directory),
                }
            )
            result = subprocess.run(
                [str(SCRIPT), *arguments],
                cwd=ROOT,
                env=environment,
                text=True,
                capture_output=True,
                check=False,
            )
            invocations = (
                invocation_log.read_text(encoding="utf-8").splitlines()
                if invocation_log.exists()
                else []
            )
            logs = {
                path.name: path.read_text(encoding="utf-8")
                for path in log_directory.glob("*.log")
            }
            return result, invocations, logs

    def test_reuses_the_first_build_and_enforces_the_test_floor(self):
        result, invocations, logs = self.run_script(
            textwrap.dedent(
                """
                printf '%s\\n' "$*" >> "$FAKE_SWIFT_INVOCATIONS"
                echo "Executed 95 tests, with 0 failures (0 unexpected)"
                """
            ),
            "--iterations",
            "3",
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(invocations), 3)
        self.assertNotIn("--skip-build", invocations[0])
        self.assertIn("--skip-build", invocations[1])
        self.assertIn("--skip-build", invocations[2])
        self.assertEqual(set(logs), {"iteration-1.log", "iteration-2.log", "iteration-3.log"})
        self.assertIn("3/3 iterations", result.stdout)

    def test_fails_closed_when_the_filter_matches_too_few_tests(self):
        result, invocations, _ = self.run_script(
            textwrap.dedent(
                """
                printf '%s\\n' "$*" >> "$FAKE_SWIFT_INVOCATIONS"
                echo "Executed 4 tests, with 0 failures (0 unexpected)"
                """
            ),
            "--iterations",
            "2",
        )

        self.assertEqual(result.returncode, 1)
        self.assertEqual(len(invocations), 1)
        self.assertIn("expected at least 90", result.stderr)
        self.assertIn("Failure logs preserved", result.stderr)

    def test_rejects_invalid_iteration_counts_before_running_swift(self):
        result, invocations, _ = self.run_script("exit 99\n", "--iterations", "0")

        self.assertEqual(result.returncode, 2)
        self.assertEqual(invocations, [])
        self.assertIn("positive integer", result.stderr)


if __name__ == "__main__":
    unittest.main()
