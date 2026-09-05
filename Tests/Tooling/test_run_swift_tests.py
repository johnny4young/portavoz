import json
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
RUNNER = ROOT / "scripts" / "run-swift-tests.sh"


class RunSwiftTestsTests(unittest.TestCase):
    def run_runner(
        self,
        *,
        fixture_mode: str = "real",
        swift_exit_code: int = 0,
        arguments: tuple[str, ...] = (),
        startup_attempts: int = 1500,
        interrupt_after_start: bool = False,
    ) -> tuple[subprocess.CompletedProcess[str], dict[str, object] | None, Path]:
        root = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, root, True)
        binary = root / "bin"
        binary.mkdir()
        swift_log = root / "swift.json"
        fake_swift = binary / "swift"
        fake_swift.write_text(
            "#!/bin/sh\n"
            "test \"$1\" = test || exit 65\n"
            "shift\n"
            "\"$REAL_PYTHON\" - \"$SWIFT_LOG\" \"$@\" <<'PY'\n"
            "import json, os, sys\n"
            "descriptor_path = os.environ.get(\n"
            "    'PORTAVOZ_TEST_WEB_FIXTURE_DESCRIPTOR', '')\n"
            "with open(descriptor_path, encoding='utf-8') as source:\n"
            "    descriptor = json.load(source)\n"
            "os.kill(descriptor['processID'], 0)\n"
            "with open(sys.argv[1], 'w', encoding='utf-8') as destination:\n"
            "    json.dump({\n"
            "        'arguments': sys.argv[2:],\n"
            "        'descriptorPath': descriptor_path,\n"
            "        'descriptor': descriptor,\n"
            "    }, destination)\n"
            "PY\n"
            "if [ \"${SWIFT_BLOCK:-false}\" = true ]; then\n"
            "  trap 'exit 0' TERM INT\n"
            "  while :; do sleep 1; done\n"
            "fi\n"
            "exit \"$SWIFT_EXIT_CODE\"\n",
            encoding="utf-8",
        )
        fake_swift.chmod(0o755)

        if fixture_mode != "real":
            fake_python = binary / "python3"
            if fixture_mode == "exit":
                body = "echo 'synthetic fixture failure' >&2\nexit 7\n"
            elif fixture_mode == "hang":
                body = (
                    "trap 'exit 0' TERM INT\n"
                    "while :; do sleep 1; done\n"
                )
            else:
                raise ValueError(f"unsupported fixture mode: {fixture_mode}")
            fake_python.write_text("#!/bin/sh\n" + body, encoding="utf-8")
            fake_python.chmod(0o755)

        environment = os.environ.copy()
        environment.update(
            {
                "PATH": f"{binary}:{environment['PATH']}",
                "REAL_PYTHON": sys.executable,
                "SWIFT_LOG": str(swift_log),
                "SWIFT_EXIT_CODE": str(swift_exit_code),
                "SWIFT_BLOCK": str(interrupt_after_start).lower(),
                "TMPDIR": str(root),
                "PORTAVOZ_TEST_WEB_FIXTURE_STARTUP_ATTEMPTS": str(
                    startup_attempts
                ),
                # The runner must replace, never trust, an inherited value.
                "PORTAVOZ_TEST_WEB_FIXTURE_DESCRIPTOR": "/tmp/foreign.json",
            }
        )
        command = [str(RUNNER), *arguments]
        if interrupt_after_start:
            process = subprocess.Popen(
                command,
                cwd=ROOT,
                env=environment,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
            deadline = time.monotonic() + 10
            while time.monotonic() < deadline and not swift_log.exists():
                if process.poll() is not None:
                    break
                time.sleep(0.02)
            self.assertTrue(swift_log.exists(), "Swift child did not start")
            process.send_signal(signal.SIGTERM)
            stdout, stderr = process.communicate(timeout=10)
            result = subprocess.CompletedProcess(
                command,
                process.returncode,
                stdout,
                stderr,
            )
        else:
            result = subprocess.run(
                command,
                cwd=ROOT,
                env=environment,
                check=False,
                capture_output=True,
                text=True,
                timeout=20,
            )
        record = (
            json.loads(swift_log.read_text(encoding="utf-8"))
            if swift_log.exists()
            else None
        )
        return result, record, root

    def assert_fixture_was_cleaned(self, record: dict[str, object], root: Path):
        descriptor = record["descriptor"]
        self.assertIsInstance(descriptor, dict)
        process_id = descriptor["processID"]
        self.assertIsInstance(process_id, int)
        with self.assertRaises(ProcessLookupError):
            os.kill(process_id, 0)
        self.assertFalse(Path(record["descriptorPath"]).exists())
        self.assertEqual(list(root.glob("portavoz-swift-tests.*")), [])

    def test_runs_swift_with_one_live_canonical_external_fixture(self):
        result, record, root = self.run_runner(
            arguments=("--filter", "AskWebFixtureIntegrationTests")
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIsNotNone(record)
        self.assertEqual(
            record["arguments"],
            ["--filter", "AskWebFixtureIntegrationTests"],
        )
        descriptor = record["descriptor"]
        self.assertEqual(descriptor["schemaVersion"], 1)
        self.assertEqual(descriptor["generation"], "public-local-v1")
        self.assertEqual(
            descriptor["fixtureChecksum"],
            "97a560b3049bd0d2e0b41fc2e8f7664272f7d20fcf4771b6ec7940295822fd26",
        )
        self.assertTrue(descriptor["baseURL"].startswith("http://127.0.0.1:"))
        self.assertNotEqual(record["descriptorPath"], "/tmp/foreign.json")
        self.assert_fixture_was_cleaned(record, root)

    def test_preserves_swift_failure_and_still_cleans_the_fixture(self):
        result, record, root = self.run_runner(swift_exit_code=73)

        self.assertEqual(result.returncode, 73, result.stderr)
        self.assertIsNotNone(record)
        self.assert_fixture_was_cleaned(record, root)

    def test_fixture_child_failure_stops_before_swift(self):
        result, record, root = self.run_runner(fixture_mode="exit")

        self.assertEqual(result.returncode, 2)
        self.assertIsNone(record)
        self.assertIn(
            "Deterministic Apuntador Web fixture did not start",
            result.stderr,
        )
        self.assertIn("synthetic fixture failure", result.stderr)
        self.assertEqual(list(root.glob("portavoz-swift-tests.*")), [])

    def test_fixture_timeout_is_bounded_and_stops_before_swift(self):
        result, record, root = self.run_runner(
            fixture_mode="hang",
            startup_attempts=2,
        )

        self.assertEqual(result.returncode, 2)
        self.assertIsNone(record)
        self.assertIn(
            "Deterministic Apuntador Web fixture did not start",
            result.stderr,
        )
        self.assertEqual(list(root.glob("portavoz-swift-tests.*")), [])

    def test_interrupt_stops_swift_fixture_and_scratch_state(self):
        result, record, root = self.run_runner(interrupt_after_start=True)

        self.assertEqual(result.returncode, 143, result.stderr)
        self.assertIsNotNone(record)
        self.assert_fixture_was_cleaned(record, root)

    def test_invalid_startup_budget_fails_before_starting_children(self):
        result, record, root = self.run_runner(startup_attempts=0)

        self.assertEqual(result.returncode, 64)
        self.assertIsNone(record)
        self.assertIn("must be within 1...1500", result.stderr)
        self.assertEqual(list(root.glob("portavoz-swift-tests.*")), [])


if __name__ == "__main__":
    unittest.main()
