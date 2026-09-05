import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "ui_test_execution.py"


class UITestExecutionTests(unittest.TestCase):
    def run_writer(
        self,
        *,
        exit_status: int,
        log: str = "ordinary xcodebuild output",
        result: bool = False,
        runtime_cases: int | None = None,
        precreate_output: bool = False,
    ):
        temporary = tempfile.TemporaryDirectory()
        root = Path(temporary.name)
        log_path = root / "run.log"
        log_path.write_text(log, encoding="utf-8")
        result_path = root / "run.xcresult"
        if result:
            result_path.mkdir()
        runtime_path = root / "runtime.json"
        if runtime_cases is not None:
            runtime_path.write_text(
                json.dumps(
                    {
                        "caseCount": runtime_cases,
                        "tests": [
                            {"identifier": f"test-{index}"}
                            for index in range(runtime_cases)
                        ],
                    }
                ),
                encoding="utf-8",
            )
        output = root / "execution.json"
        if precreate_output:
            output.write_text("existing", encoding="utf-8")
        completed = subprocess.run(
            [
                sys.executable,
                str(SCRIPT),
                "--locale",
                "en",
                "--selector-count",
                "1",
                "--exit-status",
                str(exit_status),
                "--log",
                str(log_path),
                "--result",
                str(result_path),
                "--runtime-receipt",
                str(runtime_path),
                "--output",
                str(output),
            ],
            cwd=ROOT,
            check=False,
            capture_output=True,
            text=True,
        )
        document = None
        if output.is_file() and not precreate_output:
            document = json.loads(output.read_text(encoding="utf-8"))
        return temporary, completed, document

    def test_complete_invocation_requires_result_and_runtime_receipts(self):
        temporary, completed, document = self.run_writer(
            exit_status=0,
            result=True,
            runtime_cases=1,
        )
        self.addCleanup(temporary.cleanup)

        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual(document["classification"], "completed")
        self.assertIsNone(document["failureSignature"])
        self.assertEqual(len(document["logSHA256"]), 64)

    def test_exact_automation_mode_timeout_is_host_infrastructure(self):
        temporary, completed, document = self.run_writer(
            exit_status=65,
            log="error: Timed out while enabling automation mode",
            result=True,
        )
        self.addCleanup(temporary.cleanup)

        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual(document["classification"], "known-host-infrastructure")
        self.assertEqual(document["failureSignature"], "automation-mode-timeout")

    def test_any_executed_case_keeps_failure_in_the_test_lane(self):
        temporary, completed, document = self.run_writer(
            exit_status=65,
            log="Timed out while enabling automation mode",
            result=True,
            runtime_cases=1,
        )
        self.addCleanup(temporary.cleanup)

        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual(document["classification"], "test-failure")
        self.assertIsNone(document["failureSignature"])

    def test_unknown_nonzero_exit_never_becomes_an_advisory(self):
        temporary, completed, document = self.run_writer(exit_status=70)
        self.addCleanup(temporary.cleanup)

        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual(document["classification"], "unclassified-failure")

    def test_success_without_complete_evidence_is_not_completed(self):
        temporary, completed, document = self.run_writer(exit_status=0, result=True)
        self.addCleanup(temporary.cleanup)

        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual(document["classification"], "evidence-failure")

    def test_existing_receipt_is_never_replaced(self):
        temporary, completed, _document = self.run_writer(
            exit_status=0,
            result=True,
            runtime_cases=1,
            precreate_output=True,
        )
        self.addCleanup(temporary.cleanup)

        self.assertEqual(completed.returncode, 2)
        self.assertIn("already exists", completed.stderr)


if __name__ == "__main__":
    unittest.main()
