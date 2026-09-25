import json
import re
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))

from ui_test_runtime import (  # noqa: E402
    ActivityBoundary,
    MEASUREMENT_POLICY,
    RuntimeAdjustment,
    activity_boundary_seconds,
    budget_violations,
    build_receipt,
    cases_requiring_activity_review,
    collect_test_cases,
    reconcile_activity_boundary_noise,
    write_receipt,
)


def test_node(identifier: str, duration: float, result: str = "Passed") -> dict:
    return {
        "nodeType": "Test Case",
        "nodeIdentifier": identifier,
        "name": identifier.rsplit("/", 1)[-1],
        "durationInSeconds": duration,
        "result": result,
    }


def run_recorded_runtime_cli(activities: dict, duration: float, ceiling: float, locale: str,
                             result: str = "Passed") -> tuple[subprocess.CompletedProcess, dict]:
    identifier = "UITestStorageUITests/testSharedScratchProtectsOwnershipAndRoundTripsAppFixtures()"
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        (root / "tests.json").write_text(json.dumps({"nodes": [test_node(identifier, duration, result)]}))
        (root / "activities.json").write_text(json.dumps(activities))
        xcrun = root / "xcrun"
        xcrun.write_text(
            f"#!{sys.executable}\n"
            "import pathlib, sys\n"
            "assert sys.argv[1:4] == ['xcresulttool', 'get', 'test-results']\n"
            "assert sys.argv[4] in ['tests', 'activities']\n"
            "if sys.argv[4] == 'activities':\n"
            f"    assert sys.argv[sys.argv.index('--test-id') + 1] == {identifier!r}\n"
            "print((pathlib.Path(__file__).parent / (sys.argv[4] + '.json')).read_text())\n"
        )
        xcrun.chmod(0o700)
        budget = root / "budget.json"
        budget.write_text(json.dumps({
            "catalog": {"expectedCaseCount": 1},
            "fullSuite": {"maximumTestDurationSecondsPerLocale": ceiling,
                          "maximumP95Seconds": ceiling},
            "testBudgetsSeconds": {identifier: ceiling},
        }))
        output = root / "receipt.json"
        invocation = subprocess.run([
            sys.executable, str(ROOT / "scripts/ui_test_runtime.py"),
            "--result", str(root / "recorded.xcresult"),
            "--budget", str(budget), "--output", str(output),
            "--locale", locale, "--selector-count", "1",
            "--build-duration", "6", "--wall-duration", str(duration + 1), "--enforce",
        ], env={**os.environ, "PATH": str(root) + os.pathsep + os.environ["PATH"]},
            capture_output=True, text=True, check=False)
        return invocation, json.loads(output.read_text())


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

    def test_meeting_detail_text_reads_share_one_fallible_snapshot(self):
        source = (ROOT / "Tests/PortavozUITests/MeetingDetailUITests.swift").read_text()
        helper = source.split("private func accessibleText(", 1)[1].split("\n    }", 1)[0]
        self.assertIn("throws -> String", helper)
        self.assertEqual(helper.count("try element.snapshot()"), 1)
        self.assertIn("[snapshot.label, snapshot.value as? String]", helper)
        self.assertNotIn("element.label", helper)
        self.assertNotIn("element.value", helper)
        self.assertNotIn("try?", helper)
        self.assertNotIn("catch", helper)

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
        self.assertEqual(receipt["schemaVersion"], 3)
        self.assertEqual(receipt["measurementPolicy"], MEASUREMENT_POLICY)
        self.assertEqual(receipt["runtimeAdjustments"], [])
        self.assertEqual(receipt["caseCount"], 2)
        self.assertEqual(receipt["testDurationSeconds"], 12.0)
        self.assertEqual(receipt["p50Seconds"], 4.0)
        self.assertEqual(receipt["p95Seconds"], 8.0)
        self.assertNotIn("name", receipt["tests"][0])

    def test_extracts_one_exact_setup_to_teardown_activity_boundary(self):
        tree = {
            "testRuns": [{
                "activities": [
                    {"title": "Start Test at 2026-08-29 02:37:48", "startTime": 100.0},
                    {"title": "Set Up", "startTime": 130.015},
                    {"title": "Click exact control", "startTime": 135.0},
                    {"title": "Tear Down", "startTime": 140.353},
                ]
            }]
        }

        boundary = activity_boundary_seconds(tree)

        self.assertIsNotNone(boundary)
        self.assertAlmostEqual(boundary.attributed_duration_seconds, 10.338)
        self.assertAlmostEqual(boundary.excluded_pre_setup_seconds, 30.015)

    def test_activity_boundary_rejects_missing_or_ambiguous_boundaries(self):
        self.assertIsNone(activity_boundary_seconds({"testRuns": []}))
        self.assertIsNone(activity_boundary_seconds({
            "testRuns": [{
                "activities": [
                    {"title": "Start Test at now", "startTime": 100.0},
                    {"title": "Set Up", "startTime": 101.0},
                    {"title": "Set Up", "startTime": 101.5},
                    {"title": "Tear Down", "startTime": 102.0},
                ]
            }]
        }))
        self.assertIsNone(activity_boundary_seconds({
            "testRuns": [{
                "activities": [
                    {"title": "Start Test at now", "startTime": 100.0},
                    {"title": "Tear Down", "startTime": 101.0},
                    {"title": "Set Up", "startTime": 102.0},
                ]
            }]
        }))

    def test_teardown_work_cannot_be_classified_as_runner_noise(self):
        # Retained real-app activity shape, with relative timestamps and a
        # synthetic PID: XCTest reports only starts, not cleanup completion.
        fixture = ROOT / "Tests/Tooling/fixtures/ui-test-active-teardown.json"
        tree = json.loads(fixture.read_text())
        self.assertTrue(activity_boundary_seconds(tree).preserve_reported_teardown)
        teardown = tree["testRuns"][0]["activities"][-1]
        for children in (None, {}, False):
            with self.subTest(children=children):
                teardown["childActivities"] = children
                self.assertIsNone(activity_boundary_seconds(tree))
        teardown["childActivities"] = [{"title": "Cerrar café’s editor"}]
        self.assertTrue(activity_boundary_seconds(tree).preserve_reported_teardown)
        teardown["childActivities"] = []
        self.assertFalse(activity_boundary_seconds(tree).preserve_reported_teardown)
        tree["testRuns"][0]["activities"].append({
            "title": "Late completion", "startTime": 103.0,
        })
        self.assertTrue(activity_boundary_seconds(tree).preserve_reported_teardown)

    def test_xcresult_cli_keeps_real_cleanup_in_the_enforced_duration(self):
        fixture = ROOT / "Tests/Tooling/fixtures/ui-test-active-teardown.json"
        for locale in ("en", "es"):
            result, receipt = run_recorded_runtime_cli(json.loads(fixture.read_text()), 2.600, 2.0, locale)
            self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
            self.assertEqual(receipt["budgetStatus"], "failed")
            self.assertEqual(receipt["testDurationSeconds"], 2.600)
            self.assertEqual(receipt["runtimeAdjustments"], [])

    def test_xcresult_cli_excludes_only_pre_setup_when_cleanup_completion_is_unknown(self):
        fixture = ROOT / "Tests/Tooling/fixtures/ui-test-active-teardown.json"
        tree = json.loads(fixture.read_text())
        activities = tree["testRuns"][0]["activities"]
        activities[1]["startTime"] = 130.052
        activities[2]["startTime"] = 135.227
        activities[2]["childActivities"] = [{
            "title": "Wait for café’s editor to close", "startTime": 135.228,
        }]
        for locale in ("en", "es"):
            for reported, expected, passed in (
                (35.247, 5.195, True),
                (65.247, 35.195, False),  # Long native cleanup remains owned, not harness noise.
                (50.052, 20.000, True),
                (50.053, 20.001, False),
            ):
                with self.subTest(locale=locale, reported=reported):
                    result, receipt = run_recorded_runtime_cli(tree, reported, 20.0, locale)
                    self.assertEqual(receipt["testDurationSeconds"], expected)
                    self.assertEqual(result.returncode, 0 if passed else 1, result.stdout + result.stderr)
                    self.assertEqual(receipt["budgetStatus"], "passed" if passed else "failed")
                    self.assertEqual(len(receipt["runtimeAdjustments"]), 1)
                    adjustment = receipt["runtimeAdjustments"][0]
                    self.assertEqual(adjustment["excludedPreSetupSeconds"], 30.052)
                    self.assertEqual(adjustment["excludedPostTeardownSeconds"], 0.0)
                    self.assertEqual(adjustment["reportedDurationSeconds"], reported)
                    self.assertNotIn("café", json.dumps(receipt))
            result, receipt = run_recorded_runtime_cli(tree, 35.247, 20.0, locale, result="Failed")
            self.assertEqual(result.returncode, 1)
            self.assertEqual(receipt["testDurationSeconds"], 35.247)
            self.assertEqual(receipt["runtimeAdjustments"], [])

    def test_epoch_precision_and_late_cleanup_keep_the_exact_written_budget_boundary(self):
        for late_activity in (False, True):
            activities = [
                {"title": "Start Test at synthetic epoch", "startTime": 1700000000.000},
                {"title": "Set Up", "startTime": 1700000030.052},
                {"title": "Tear Down", "startTime": 1700000035.227},
            ]
            cleanup = {"title": "Finish owned cleanup", "startTime": 1700000035.228}
            if late_activity:
                activities.append(cleanup)
            else:
                activities[-1]["childActivities"] = [cleanup]
            tree = {"testRuns": [{"activities": activities}]}
            with self.subTest(late_activity=late_activity):
                result, receipt = run_recorded_runtime_cli(tree, 50.052, 20.0, "en")
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(receipt["testDurationSeconds"], 20.0)
                self.assertEqual(receipt["runtimeAdjustments"][0]["excludedPreSetupSeconds"], 30.052)
                self.assertEqual(receipt["runtimeAdjustments"][0]["excludedPostTeardownSeconds"], 0.0)

    def test_base_case_cleanup_activity_keeps_owned_teardown_in_the_budget(self):
        source = (ROOT / "Tests/PortavozUITests/PortavozUITestCase.swift").read_text(encoding="utf-8")
        match = re.search(r'XCTContext\.runActivity\(named: "([^"]+)"\)', source)
        self.assertIsNotNone(match, "the shared base must name its owned cleanup")
        tree = {"testRuns": [{"activities": [
            {"title": "Start Test at synthetic epoch", "startTime": 100.0},
            {"title": "Set Up", "startTime": 101.5},
            {"title": "Tear Down", "startTime": 110.0,
             "childActivities": [{"title": match.group(1), "startTime": 110.001}]},
        ]}]}
        boundary = activity_boundary_seconds(tree)
        self.assertTrue(boundary.preserve_reported_teardown)
        # Ten seconds of app exit and scratch removal after the marker stay owned:
        # only the empty pre-setup interval is excluded.
        for locale in ("en", "es"):
            with self.subTest(locale=locale):
                result, receipt = run_recorded_runtime_cli(tree, 20.0, 18.5, locale)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(receipt["testDurationSeconds"], 18.5)
                adjustment = receipt["runtimeAdjustments"][0]
                self.assertEqual(adjustment["excludedPreSetupSeconds"], 1.5)
                self.assertEqual(adjustment["excludedPostTeardownSeconds"], 0.0)
                result, receipt = run_recorded_runtime_cli(tree, 20.0, 18.0, locale)
                self.assertEqual(result.returncode, 1, "owned cleanup must not be subtracted to pass")
                self.assertEqual(receipt["testDurationSeconds"], 18.5)
        # Without the named child the same shape would subtract that cleanup.
        tree["testRuns"][0]["activities"][-1]["childActivities"] = []
        self.assertFalse(activity_boundary_seconds(tree).preserve_reported_teardown)

    def test_pre_setup_attribution_rejects_prelude_work_and_inconsistent_clocks(self):
        fixture = ROOT / "Tests/Tooling/fixtures/ui-test-active-teardown.json"
        base = json.loads(fixture.read_text())
        base["testRuns"][0]["activities"][1]["startTime"] = 130.052
        base["testRuns"][0]["activities"][2]["startTime"] = 135.227
        for shape in ("intervening-work", "start-children", "invalid-children", "short-duration"):
            tree = json.loads(json.dumps(base))
            activities = tree["testRuns"][0]["activities"]
            reported = 35.247
            if shape == "intervening-work":
                activities.insert(1, {"title": "Launch owned app", "startTime": 105.0})
            elif shape == "start-children":
                activities[0]["childActivities"] = [{"title": "Work before setup", "startTime": 105.0}]
            elif shape == "invalid-children":
                activities[-1]["childActivities"] = None
            else:
                reported = 32.0
            with self.subTest(shape=shape):
                result, receipt = run_recorded_runtime_cli(tree, reported, 20.0, "es")
                self.assertEqual(result.returncode, 1)
                self.assertEqual(receipt["testDurationSeconds"], reported)
                self.assertEqual(receipt["runtimeAdjustments"], [])

    def test_reconciles_only_passing_pre_setup_harness_noise(self):
        cases = collect_test_cases({
            "nodes": [
                test_node("LibraryUITests/testLibrary()", 40.353),
                test_node("InsightsUITests/testInsights()", 8.0),
            ]
        })

        adjusted, adjustments = reconcile_activity_boundary_noise(
            cases,
            self.budget,
            selector_count=2,
            activity_boundary_loader=lambda identifier: (
                ActivityBoundary(10.338, 30.013)
                if identifier == "LibraryUITests/testLibrary()" else None
            ),
        )

        self.assertAlmostEqual(adjusted[1].duration_seconds, 10.338)
        self.assertEqual(len(adjustments), 1)
        self.assertEqual(adjustments[0].identifier, "LibraryUITests/testLibrary()")
        self.assertAlmostEqual(adjustments[0].excluded_pre_setup_seconds, 30.013)
        self.assertAlmostEqual(adjustments[0].excluded_post_teardown_seconds, 0.002)
        self.assertAlmostEqual(adjustments[0].excluded_harness_seconds, 30.015)

    def test_reconciles_only_passing_post_teardown_harness_noise(self):
        cases = collect_test_cases({
            "nodes": [test_node("LibraryUITests/testLibrary()", 40.353)]
        })
        budget = json.loads(json.dumps(self.budget))
        budget["catalog"]["expectedCaseCount"] = 1
        budget["testBudgetsSeconds"] = {
            "LibraryUITests/testLibrary()": 20.0,
        }

        adjusted, adjustments = reconcile_activity_boundary_noise(
            cases,
            budget,
            selector_count=1,
            activity_boundary_loader=lambda _: ActivityBoundary(10.338, 0.002),
        )

        self.assertAlmostEqual(adjusted[0].duration_seconds, 10.338)
        self.assertEqual(len(adjustments), 1)
        self.assertAlmostEqual(adjustments[0].excluded_pre_setup_seconds, 0.002)
        self.assertAlmostEqual(adjustments[0].excluded_post_teardown_seconds, 30.013)

    def test_legitimate_slow_activity_remains_a_budget_failure(self):
        cases = collect_test_cases({
            "nodes": [test_node("LibraryUITests/testLibrary()", 40.353)]
        })
        budget = json.loads(json.dumps(self.budget))
        budget["catalog"]["expectedCaseCount"] = 1
        budget["testBudgetsSeconds"] = {
            "LibraryUITests/testLibrary()": 20.0,
        }

        adjusted, adjustments = reconcile_activity_boundary_noise(
            cases,
            budget,
            selector_count=1,
            activity_boundary_loader=lambda _: ActivityBoundary(40.35, 0.0),
        )

        self.assertEqual(adjusted, cases)
        self.assertEqual(adjustments, [])
        self.assertIn(
            "LibraryUITests/testLibrary(): 40.353s > 20.000s",
            budget_violations(adjusted, budget, selector_count=1),
        )

    def test_missing_activity_evidence_fails_closed_on_reported_duration(self):
        cases = collect_test_cases({
            "nodes": [test_node("LibraryUITests/testLibrary()", 40.353)]
        })
        budget = json.loads(json.dumps(self.budget))
        budget["catalog"]["expectedCaseCount"] = 1
        budget["testBudgetsSeconds"] = {
            "LibraryUITests/testLibrary()": 20.0,
        }

        adjusted, adjustments = reconcile_activity_boundary_noise(
            cases,
            budget,
            selector_count=1,
            activity_boundary_loader=lambda _: None,
        )

        self.assertEqual(adjusted, cases)
        self.assertEqual(adjustments, [])
        self.assertTrue(budget_violations(adjusted, budget, selector_count=1))

    def test_aggregate_overage_reviews_every_passing_case(self):
        cases = collect_test_cases(self.tree)
        budget = json.loads(json.dumps(self.budget))
        budget["fullSuite"]["maximumTestDurationSecondsPerLocale"] = 10.0

        self.assertEqual(
            cases_requiring_activity_review(cases, budget, selector_count=2),
            (
                "InsightsUITests/testInsights()",
                "LibraryUITests/testLibrary()",
            ),
        )

    def test_receipt_preserves_content_free_runtime_adjustment(self):
        cases = collect_test_cases({
            "nodes": [test_node("LibraryUITests/testLibrary()", 10.338)]
        })
        budget = json.loads(json.dumps(self.budget))
        budget["catalog"]["expectedCaseCount"] = 1
        budget["fullSuite"]["maximumTestDurationSecondsPerLocale"] = 20.0
        budget["fullSuite"]["maximumP95Seconds"] = 20.0
        budget["testBudgetsSeconds"] = {
            "LibraryUITests/testLibrary()": 20.0,
        }
        receipt = build_receipt(
            cases,
            locale="en",
            selector_count=1,
            build_duration_seconds=3.0,
            wall_duration_seconds=50.0,
            budget=budget,
            adjustments=[RuntimeAdjustment(
                identifier="LibraryUITests/testLibrary()",
                reported_duration_seconds=40.353,
                attributed_duration_seconds=10.338,
                excluded_pre_setup_seconds=30.013,
                excluded_post_teardown_seconds=0.002,
                excluded_harness_seconds=30.015,
            )],
        )

        self.assertEqual(receipt["budgetStatus"], "passed")
        self.assertEqual(receipt["runtimeAdjustments"], [{
            "identifier": "LibraryUITests/testLibrary()",
            "reportedDurationSeconds": 40.353,
            "attributedDurationSeconds": 10.338,
            "excludedPreSetupSeconds": 30.013,
            "excludedPostTeardownSeconds": 0.002,
            "excludedHarnessSeconds": 30.015,
            "reason": "outside-test-activity-boundaries",
        }])

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

    def test_permissioned_native_dictation_has_a_strict_one_case_budget(self):
        budget = json.loads((
            ROOT / "docs/evidence/ui-test-native-dictation-runtime-budget.json"
        ).read_text(encoding="utf-8"))
        identifier = "DictationUITests/testNativeInserterUsesDisposableReceiverAndClipboard()"
        for duration, expected_failure in ((19.999, False), (20.001, True)):
            with self.subTest(duration=duration):
                cases = collect_test_cases({"nodes": [test_node(identifier, duration)]})
                violations = budget_violations(cases, budget, selector_count=1)
                self.assertEqual(bool(violations), expected_failure, violations)
        missing = collect_test_cases({"nodes": [test_node("OtherUITests/testUnbudgeted()", 1.0)]})
        self.assertTrue(any(
            "missing runtime budget" in violation
            for violation in budget_violations(missing, budget, selector_count=1)
        ))

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
            self.assertEqual(os.stat(receipt).st_mode & 0o777, 0o600)
            self.assertEqual(os.stat(receipt.parent).st_mode & 0o777, 0o700)

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

    def test_atomic_receipt_keeps_previous_file_when_serialization_fails(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "runtime.json"
            path.write_text("previous\n", encoding="utf-8")

            with self.assertRaises(ValueError):
                write_receipt(path, {"duration": float("nan")})

            self.assertEqual(path.read_text(encoding="utf-8"), "previous\n")
            self.assertEqual(list(path.parent.glob(".*.tmp")), [])


if __name__ == "__main__":
    unittest.main()
