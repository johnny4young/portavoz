import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))

from ui_test_runtime import (  # noqa: E402
    budget_violations,
    build_receipt,
    collect_test_cases,
)


def test_node(identifier: str, duration: float, result: str = "Passed") -> dict:
    return {
        "nodeType": "Test Case",
        "nodeIdentifier": identifier,
        "name": identifier.rsplit("/", 1)[-1],
        "durationInSeconds": duration,
        "result": result,
    }


class UITestRuntimeTests(unittest.TestCase):
    def setUp(self):
        self.tree = {
            "nodes": [
                test_node("LibraryUITests/testLibrary()", 4.0),
                {"children": [test_node("InsightsUITests/testInsights()", 8.0)]},
            ]
        }
        self.budget = {
            "catalog": {"expectedCaseCount": 2},
            "fullSuite": {
                "maximumTestDurationSecondsPerLocale": 15.0,
                "maximumP95Seconds": 10.0,
            },
            "testBudgetsSeconds": {
                "LibraryUITests/testLibrary()": 6.0,
                "InsightsUITests/testInsights()": 9.0,
            },
        }

    def test_collects_content_free_case_identity_duration_and_result(self):
        cases = collect_test_cases(self.tree)

        self.assertEqual([case.identifier for case in cases], [
            "InsightsUITests/testInsights()",
            "LibraryUITests/testLibrary()",
        ])
        self.assertEqual(sum(case.duration_seconds for case in cases), 12.0)

    def test_receipt_reports_distribution_and_passed_budget(self):
        receipt = build_receipt(
            collect_test_cases(self.tree),
            locale="en",
            selector_count=0,
            build_duration_seconds=3.2,
            wall_duration_seconds=14.1,
            budget=self.budget,
        )

        self.assertEqual(receipt["budgetStatus"], "passed")
        self.assertEqual(receipt["caseCount"], 2)
        self.assertEqual(receipt["testDurationSeconds"], 12.0)
        self.assertEqual(receipt["p50Seconds"], 4.0)
        self.assertEqual(receipt["p95Seconds"], 8.0)
        self.assertNotIn("name", receipt["tests"][0])

    def test_budget_fails_slow_missing_and_failed_cases(self):
        cases = collect_test_cases({
            "nodes": [
                test_node("LibraryUITests/testLibrary()", 7.0),
                test_node("UnknownUITests/testMissingBudget()", 1.0, "Failed"),
            ]
        })

        violations = budget_violations(cases, self.budget)

        self.assertTrue(any("7.000s > 6.000s" in item for item in violations))
        self.assertTrue(any("missing runtime budget" in item for item in violations))
        self.assertTrue(any("result=Failed" in item for item in violations))

    def test_full_suite_budget_fails_total_and_p95_regression(self):
        slow = collect_test_cases({
            "nodes": [
                test_node("LibraryUITests/testLibrary()", 7.0),
                test_node("InsightsUITests/testInsights()", 11.0),
            ]
        })

        violations = budget_violations(slow, self.budget)

        self.assertTrue(any(item.startswith("full suite:") for item in violations))
        self.assertTrue(any(item.startswith("full suite p95:") for item in violations))

    def test_explicit_full_catalog_selectors_enforce_aggregate_budgets(self):
        slow = collect_test_cases({
            "nodes": [
                test_node("LibraryUITests/testLibrary()", 7.0),
                test_node("InsightsUITests/testInsights()", 11.0),
            ]
        })

        violations = budget_violations(
            slow,
            self.budget,
            selector_count=self.budget["catalog"]["expectedCaseCount"],
        )

        self.assertTrue(any(item.startswith("full suite:") for item in violations))
        self.assertTrue(any(item.startswith("full suite p95:") for item in violations))

    def test_full_suite_rejects_a_missing_catalog_case(self):
        cases = collect_test_cases({
            "nodes": [test_node("LibraryUITests/testLibrary()", 4.0)]
        })

        violations = budget_violations(cases, self.budget)

        self.assertIn(
            "full suite: result contains 1 cases, catalog requires 2",
            violations,
        )

    def test_scoped_run_rejects_a_missing_selected_case(self):
        cases = collect_test_cases({
            "nodes": [test_node("LibraryUITests/testLibrary()", 4.0)]
        })
        scoped_budget = json.loads(json.dumps(self.budget))
        scoped_budget["catalog"]["expectedCaseCount"] = 3

        violations = budget_violations(
            cases,
            scoped_budget,
            selector_count=2,
        )

        self.assertIn(
            "scoped run: result contains 1 cases for 2 selectors",
            violations,
        )

    def test_runtime_receipt_rejects_duplicate_case_identifiers(self):
        duplicate = test_node("LibraryUITests/testLibrary()", 4.0)

        violations = budget_violations(
            collect_test_cases({"nodes": [duplicate, duplicate]}),
            self.budget,
            selector_count=2,
        )

        self.assertTrue(any("duplicate cases" in item for item in violations))

    def test_runtime_receipt_rejects_nonfinite_and_negative_durations(self):
        cases = collect_test_cases({
            "nodes": [
                test_node("LibraryUITests/testLibrary()", float("nan")),
                test_node("InsightsUITests/testInsights()", -1.0),
            ]
        })

        receipt = build_receipt(
            cases,
            locale="en",
            selector_count=2,
            build_duration_seconds=1.0,
            wall_duration_seconds=2.0,
            budget=self.budget,
        )

        self.assertEqual(receipt["budgetStatus"], "failed")
        self.assertEqual(
            [test["durationSeconds"] for test in receipt["tests"]],
            [None, None],
        )
        self.assertTrue(
            all("invalid test duration" in item for item in receipt["budgetViolations"])
        )
        json.dumps(receipt, allow_nan=False)

    def test_boolean_duration_cannot_masquerade_as_a_numeric_result(self):
        cases = collect_test_cases({
            "nodes": [
                test_node("LibraryUITests/testLibrary()", True),
                test_node("InsightsUITests/testInsights()", 8.0),
            ]
        })

        violations = budget_violations(
            cases,
            self.budget,
            selector_count=2,
        )

        self.assertEqual(
            [case.identifier for case in cases],
            ["InsightsUITests/testInsights()"],
        )
        self.assertIn(
            "full suite: result contains 1 cases, catalog requires 2",
            violations,
        )

    def test_runtime_receipt_rejects_nonfinite_and_negative_budgets(self):
        invalid_budget = json.loads(json.dumps(self.budget))
        invalid_budget["testBudgetsSeconds"]["LibraryUITests/testLibrary()"] = -1
        invalid_budget["fullSuite"]["maximumP95Seconds"] = float("inf")

        violations = budget_violations(
            collect_test_cases(self.tree),
            invalid_budget,
        )

        self.assertTrue(any("invalid runtime budget" in item for item in violations))
        self.assertIn("invalid budget: fullSuite.maximumP95Seconds", violations)

    def test_cli_enforcement_returns_nonzero_and_keeps_receipt(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            tests = root / "tests.json"
            budget = root / "budget.json"
            receipt = root / "receipt.json"
            tests.write_text(json.dumps({
                "nodes": [test_node("LibraryUITests/testLibrary()", 7.0)]
            }))
            budget.write_text(json.dumps({
                "catalog": {"expectedCaseCount": 1},
                "fullSuite": {
                    "maximumTestDurationSecondsPerLocale": 6.0,
                    "maximumP95Seconds": 6.0,
                },
                "testBudgetsSeconds": {
                    "LibraryUITests/testLibrary()": 6.0,
                },
            }))

            result = subprocess.run(
                [
                    str(ROOT / "scripts" / "ui_test_runtime.py"),
                    "--tests-json", str(tests),
                    "--budget", str(budget),
                    "--output", str(receipt),
                    "--locale", "en",
                    "--selector-count", "1",
                    "--build-duration", "2",
                    "--wall-duration", "8",
                    "--enforce",
                ],
                check=False,
                capture_output=True,
                text=True,
            )

            self.assertEqual(result.returncode, 1)
            self.assertEqual(json.loads(receipt.read_text())["budgetStatus"], "failed")

    def test_cli_invalid_json_fails_closed_with_content_free_receipt(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            tests = root / "tests.json"
            budget = root / "budget.json"
            receipt = root / "receipt.json"
            tests.write_text("{private transcript", encoding="utf-8")
            budget.write_text(json.dumps(self.budget), encoding="utf-8")

            result = subprocess.run(
                [
                    str(ROOT / "scripts" / "ui_test_runtime.py"),
                    "--tests-json", str(tests),
                    "--budget", str(budget),
                    "--output", str(receipt),
                    "--locale", "en",
                    "--selector-count", "2",
                    "--build-duration", "2",
                    "--wall-duration", "8",
                    "--enforce",
                ],
                check=False,
                capture_output=True,
                text=True,
            )

            payload = json.loads(receipt.read_text(encoding="utf-8"))
            self.assertEqual(result.returncode, 2)
            self.assertEqual(payload["budgetStatus"], "failed")
            self.assertEqual(
                payload["budgetViolations"],
                ["runtime input error: invalid-json"],
            )
            self.assertNotIn("transcript", json.dumps(payload))


if __name__ == "__main__":
    unittest.main()
