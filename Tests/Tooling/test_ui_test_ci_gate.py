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
        "p50Seconds": 1.0,
        "p95Seconds": 1.0,
        "schemaVersion": 1,
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


class UITestCIGateTests(unittest.TestCase):
    def run_gate(
        self,
        *,
        locales: str = "en",
        english_outcome: str = "success",
        spanish_outcome: str = "skipped",
        receipts: dict[str, dict] | None = None,
    ) -> subprocess.CompletedProcess[str]:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            documents = {"en": receipt("en")} if receipts is None else receipts
            for locale, document in documents.items():
                (root / f"{locale}-runtime.json").write_text(
                    json.dumps(document),
                    encoding="utf-8",
                )
            summary = root / "summary.md"
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
                ],
                cwd=ROOT,
                check=False,
                capture_output=True,
                text=True,
            )
            self.summary = summary.read_text(encoding="utf-8") if summary.exists() else ""
            return result

    def test_functional_receipt_passes(self):
        result = self.run_gate()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("functional gate passed", result.stdout)
        self.assertIn("| en | success | 1 | passed | advisory passed |", self.summary)

    def test_hosted_runtime_drift_is_advisory_when_functional_tests_pass(self):
        result = self.run_gate(receipts={"en": receipt("en", drift=True)})

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Hosted UI runtime advisory", result.stdout)
        self.assertIn("advisory failed", self.summary)

    def test_nonpassing_case_is_a_product_or_test_regression(self):
        result = self.run_gate(receipts={"en": receipt("en", result="Failed")})

        self.assertEqual(result.returncode, 1)
        self.assertIn("product-or-test-regression", result.stderr)

    def test_missing_receipt_is_an_infrastructure_or_harness_failure(self):
        result = self.run_gate(receipts={})

        self.assertEqual(result.returncode, 1)
        self.assertIn("infrastructure-or-harness", result.stderr)

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
        self.assertIn("| es | success | 1 | passed | advisory passed |", self.summary)

    def test_unknown_receipt_keys_fail_closed(self):
        document = receipt("en")
        document["unknown"] = True
        result = self.run_gate(receipts={"en": document})

        self.assertEqual(result.returncode, 1)
        self.assertIn("receipt shape differs", result.stderr)


if __name__ == "__main__":
    unittest.main()
