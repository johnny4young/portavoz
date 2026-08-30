import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "ui_test_ci_gate.py"


def receipt(locale: str, *, result: str = "Passed", drift: bool = False):
    violations = ["full suite: 20.000s > 10.000s"] if drift else []
    return {
        "budgetStatus": "failed" if drift else "passed",
        "budgetViolations": violations,
        "buildDurationSeconds": 2.0,
        "caseCount": 1,
        "locale": locale,
        "maximumSeconds": 1.0,
        "measurementPolicy": "xcresult-duration-with-activity-boundary-exclusions-v2",
        "p50Seconds": 1.0,
        "p95Seconds": 1.0,
        "runtimeAdjustments": [],
        "schemaVersion": 3,
        "selectorCount": 1,
        "testDurationSeconds": 1.0,
        "testWallDurationSeconds": 2.0,
        "tests": [
            {
                "durationSeconds": 1.0,
                "identifier": "LibraryUITests/testLibrary()",
                "result": result,
            }
        ],
    }


def execution(
    locale: str,
    *,
    classification: str = "completed",
    exit_status: int = 0,
    runtime_present: bool = True,
    signature=None,
):
    return {
        "classification": classification,
        "failureSignature": signature,
        "locale": locale,
        "logSHA256": "a" * 64,
        "resultBundlePresent": True,
        "runtimeReceiptPresent": runtime_present,
        "schemaVersion": 1,
        "selectorCount": 1,
        "xcodebuildExitStatus": exit_status,
    }


class UITestCIGateTests(unittest.TestCase):
    def run_gate(
        self,
        *,
        locales: str = "en",
        english_outcome: str = "success",
        spanish_outcome: str = "skipped",
        receipts: dict[str, dict] | None = None,
        executions: dict[str, dict] | None = None,
    ) -> subprocess.CompletedProcess[str]:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            documents = {"en": receipt("en")} if receipts is None else receipts
            for locale, document in documents.items():
                (root / f"{locale}-runtime.json").write_text(
                    json.dumps(document),
                    encoding="utf-8",
                )
            if executions is None:
                execution_documents = {}
                for locale in locales.split():
                    has_runtime = locale in documents
                    outcome = english_outcome if locale == "en" else spanish_outcome
                    if outcome == "failure" and has_runtime:
                        execution_documents[locale] = execution(
                            locale,
                            classification="test-failure",
                            exit_status=65,
                        )
                    elif has_runtime:
                        execution_documents[locale] = execution(locale)
                    else:
                        execution_documents[locale] = execution(
                            locale,
                            classification="evidence-failure",
                            runtime_present=False,
                        )
            else:
                execution_documents = executions
            for locale, document in execution_documents.items():
                (root / f"{locale}-execution.json").write_text(
                    json.dumps(document),
                    encoding="utf-8",
                )
            summary = root / "summary.md"
            github_output = root / "github-output.txt"
            github_output.touch()
            result = subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT),
                    "--results",
                    str(root),
                    "--locales",
                    locales,
                    "--english-outcome",
                    english_outcome,
                    "--spanish-outcome",
                    spanish_outcome,
                    "--summary",
                    str(summary),
                    "--github-output",
                    str(github_output),
                ],
                cwd=ROOT,
                check=False,
                capture_output=True,
                text=True,
            )
            self.summary = summary.read_text(encoding="utf-8") if summary.exists() else ""
            self.outputs = dict(
                line.split("=", 1)
                for line in github_output.read_text(encoding="utf-8").splitlines()
            )
            return result

    def test_functional_receipt_passes(self):
        result = self.run_gate()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("functional gate passed", result.stdout)
        self.assertIn(
            "| en | success | 1 | passed | advisory passed | 0 |",
            self.summary,
        )
        self.assertEqual(self.outputs, {"verified": "true", "state": "passed"})

    def test_hosted_runtime_drift_is_advisory_when_functional_tests_pass(self):
        result = self.run_gate(receipts={"en": receipt("en", drift=True)})

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Hosted UI runtime advisory", result.stdout)
        self.assertIn("advisory failed | 0 |", self.summary)

    def test_catalog_completeness_violation_is_never_a_runtime_advisory(self):
        document = receipt("en", drift=True)
        document["budgetViolations"] = [
            "scoped run: result contains 1 cases for 2 selectors"
        ]

        result = self.run_gate(receipts={"en": document})

        self.assertEqual(result.returncode, 1)
        self.assertIn("evidence-contract violations", result.stderr)

    def test_missing_budget_violation_is_never_a_runtime_advisory(self):
        document = receipt("en", drift=True)
        document["budgetViolations"] = [
            "LibraryUITests/testLibrary(): missing runtime budget"
        ]

        result = self.run_gate(receipts={"en": document})

        self.assertEqual(result.returncode, 1)
        self.assertIn("evidence-contract violations", result.stderr)

    def test_runtime_advisory_must_name_a_case_in_the_receipt(self):
        document = receipt("en", drift=True)
        document["budgetViolations"] = [
            "ForgedUITests/testUnknown(): 20.000s > 10.000s"
        ]

        result = self.run_gate(receipts={"en": document})

        self.assertEqual(result.returncode, 1)
        self.assertIn("evidence-contract violations", result.stderr)

    def test_duplicate_test_identity_fails_closed(self):
        document = receipt("en")
        document["tests"].append(dict(document["tests"][0]))
        document["caseCount"] = 2

        result = self.run_gate(receipts={"en": document})

        self.assertEqual(result.returncode, 1)
        self.assertIn("repeats a test case", result.stderr)

    def test_nonpassing_case_is_a_product_or_test_regression(self):
        result = self.run_gate(receipts={"en": receipt("en", result="Failed")})

        self.assertEqual(result.returncode, 1)
        self.assertIn("product-or-test-regression", result.stderr)

    def test_missing_receipt_without_known_signature_fails_closed(self):
        result = self.run_gate(receipts={})

        self.assertEqual(result.returncode, 1)
        self.assertIn("infrastructure-or-harness", result.stderr)
        self.assertEqual(self.outputs["verified"], "false")

    def test_exact_known_host_failure_is_advisory_and_never_verified(self):
        result = self.run_gate(
            english_outcome="failure",
            receipts={},
            executions={
                "en": execution(
                    "en",
                    classification="known-host-infrastructure",
                    exit_status=65,
                    runtime_present=False,
                    signature="automation-mode-timeout",
                )
            },
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("infrastructure was unavailable", result.stdout)
        self.assertEqual(
            self.outputs,
            {"verified": "false", "state": "infrastructure-advisory"},
        )

    def test_selected_locale_cannot_be_skipped(self):
        result = self.run_gate(english_outcome="skipped")

        self.assertEqual(result.returncode, 1)
        self.assertIn("step outcome skipped", result.stderr)

    def test_unselected_locale_must_remain_skipped(self):
        result = self.run_gate(spanish_outcome="success")

        self.assertEqual(result.returncode, 1)
        self.assertIn("unselected locale ran", result.stderr)

    def test_bilingual_gate_requires_both_exact_receipts(self):
        result = self.run_gate(
            locales="en es",
            spanish_outcome="success",
            receipts={"en": receipt("en"), "es": receipt("es")},
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(
            "| es | success | 1 | passed | advisory passed | 0 |",
            self.summary,
        )
        self.assertEqual(self.outputs["verified"], "true")

    def test_nonpassing_result_violation_is_functional_not_malformed_evidence(self):
        document = receipt("en", result="Failed", drift=True)
        document["budgetViolations"] = [
            "LibraryUITests/testLibrary(): result=Failed"
        ]
        result = self.run_gate(
            english_outcome="failure",
            receipts={"en": document},
        )

        self.assertEqual(result.returncode, 1)
        self.assertIn("product-or-test-regression", result.stderr)
        self.assertNotIn("evidence-contract violations", result.stderr)

    def test_execution_and_runtime_selector_counts_must_match(self):
        document = execution("en")
        document["selectorCount"] = 2
        result = self.run_gate(executions={"en": document})

        self.assertEqual(result.returncode, 1)
        self.assertIn("selector counts disagree", result.stderr)

    def test_valid_activity_boundary_adjustment_is_visible_and_accepted(self):
        document = receipt("en")
        document["tests"][0]["durationSeconds"] = 10.338
        document["testDurationSeconds"] = 10.338
        document["p50Seconds"] = 10.338
        document["p95Seconds"] = 10.338
        document["maximumSeconds"] = 10.338
        document["runtimeAdjustments"] = [{
            "identifier": "LibraryUITests/testLibrary()",
            "reportedDurationSeconds": 40.353,
            "attributedDurationSeconds": 10.338,
            "excludedPreSetupSeconds": 30.013,
            "excludedPostTeardownSeconds": 0.002,
            "excludedHarnessSeconds": 30.015,
            "reason": "outside-test-activity-boundaries",
        }]

        result = self.run_gate(receipts={"en": document})

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("advisory passed | 1 |", self.summary)

    def test_forged_runtime_adjustment_fails_closed(self):
        document = receipt("en")
        document["runtimeAdjustments"] = [{
            "identifier": "LibraryUITests/testLibrary()",
            "reportedDurationSeconds": 40.353,
            "attributedDurationSeconds": 10.338,
            "excludedPreSetupSeconds": 0.5,
            "excludedPostTeardownSeconds": 0.5,
            "excludedHarnessSeconds": 1.0,
            "reason": "outside-test-activity-boundaries",
        }]

        result = self.run_gate(receipts={"en": document})

        self.assertEqual(result.returncode, 1)
        self.assertIn("runtime adjustment values differ", result.stderr)

    def test_split_harness_durations_must_sum_to_the_total_exclusion(self):
        document = receipt("en")
        document["tests"][0]["durationSeconds"] = 10.338
        document["testDurationSeconds"] = 10.338
        document["p50Seconds"] = 10.338
        document["p95Seconds"] = 10.338
        document["maximumSeconds"] = 10.338
        document["runtimeAdjustments"] = [{
            "identifier": "LibraryUITests/testLibrary()",
            "reportedDurationSeconds": 40.353,
            "attributedDurationSeconds": 10.338,
            "excludedPreSetupSeconds": 29.0,
            "excludedPostTeardownSeconds": 0.002,
            "excludedHarnessSeconds": 30.015,
            "reason": "outside-test-activity-boundaries",
        }]

        result = self.run_gate(receipts={"en": document})

        self.assertEqual(result.returncode, 1)
        self.assertIn("runtime adjustment values differ", result.stderr)

    def test_unknown_receipt_keys_fail_closed(self):
        document = receipt("en")
        document["unknown"] = True
        result = self.run_gate(receipts={"en": document})

        self.assertEqual(result.returncode, 1)
        self.assertIn("receipt shape differs", result.stderr)


if __name__ == "__main__":
    unittest.main()
