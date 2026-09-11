#!/usr/bin/env python3
"""Emit a content-free XCUITest runtime receipt and enforce accepted budgets."""

from __future__ import annotations

import argparse
import json
import math
import os
import subprocess
import sys
from collections import Counter
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable, Iterable, Sequence


RECEIPT_SCHEMA_VERSION = 3
MEASUREMENT_POLICY = "xcresult-duration-with-activity-boundary-exclusions-v2"
HARNESS_NOISE_THRESHOLD_SECONDS = 1.0
TIMING_PRECISION_TOLERANCE_SECONDS = 0.002


@dataclass(frozen=True)
class TestCaseRuntime:
    identifier: str
    name: str
    duration_seconds: float
    result: str


@dataclass(frozen=True)
class RuntimeAdjustment:
    identifier: str
    reported_duration_seconds: float
    attributed_duration_seconds: float
    excluded_pre_setup_seconds: float
    excluded_post_teardown_seconds: float
    excluded_harness_seconds: float


@dataclass(frozen=True)
class ActivityBoundary:
    attributed_duration_seconds: float
    excluded_pre_setup_seconds: float


def finite_nonnegative(value: Any) -> float | None:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    number = float(value)
    return number if math.isfinite(number) and number >= 0 else None


def expected_case_count(budget: dict[str, Any]) -> int | None:
    catalog = budget.get("catalog")
    if not isinstance(catalog, dict):
        return None
    value = catalog.get("expectedCaseCount")
    if isinstance(value, bool) or not isinstance(value, int) or value <= 0:
        return None
    return value


def percentile(values: Sequence[float], fraction: float) -> float:
    if not values:
        return 0.0
    ordered = sorted(values)
    index = math.ceil(fraction * len(ordered)) - 1
    return ordered[max(0, min(index, len(ordered) - 1))]


def collect_test_cases(tree: Any) -> list[TestCaseRuntime]:
    cases: list[TestCaseRuntime] = []

    def visit(node: Any) -> None:
        if isinstance(node, dict):
            if node.get("nodeType") == "Test Case":
                identifier = node.get("nodeIdentifier")
                name = node.get("name")
                duration = node.get("durationInSeconds")
                result = node.get("result")
                if (
                    isinstance(identifier, str)
                    and isinstance(name, str)
                    and isinstance(duration, (int, float))
                    and not isinstance(duration, bool)
                    and isinstance(result, str)
                ):
                    cases.append(TestCaseRuntime(
                        identifier=identifier,
                        name=name,
                        duration_seconds=float(duration),
                        result=result,
                    ))
            for value in node.values():
                visit(value)
        elif isinstance(node, list):
            for value in node:
                visit(value)

    visit(tree)
    return sorted(cases, key=lambda case: case.identifier)


def full_catalog_execution(
    budget: dict[str, Any],
    selector_count: int,
) -> bool:
    expected_count = expected_case_count(budget)
    return expected_count is not None and selector_count in {0, expected_count}


def cases_requiring_activity_review(
    cases: Sequence[TestCaseRuntime],
    budget: dict[str, Any],
    *,
    selector_count: int,
) -> tuple[str, ...]:
    raw_budgets = budget.get("testBudgetsSeconds")
    test_budgets = raw_budgets if isinstance(raw_budgets, dict) else {}
    identifiers = {
        case.identifier
        for case in cases
        if case.result == "Passed"
        and (
            (maximum := finite_nonnegative(test_budgets.get(case.identifier)))
            is not None
        )
        and (
            (duration := finite_nonnegative(case.duration_seconds)) is not None
            and duration > maximum
        )
    }

    if (
        full_catalog_execution(budget, selector_count)
        and len(cases) == expected_case_count(budget)
    ):
        raw_suite = budget.get("fullSuite")
        suite = raw_suite if isinstance(raw_suite, dict) else {}
        maximum_total = finite_nonnegative(
            suite.get("maximumTestDurationSecondsPerLocale")
        )
        maximum_p95 = finite_nonnegative(suite.get("maximumP95Seconds"))
        durations = [
            duration
            for case in cases
            if case.result == "Passed"
            and (duration := finite_nonnegative(case.duration_seconds)) is not None
        ]
        if (
            maximum_total is not None
            and sum(durations) > maximum_total
        ) or (
            maximum_p95 is not None
            and percentile(durations, 0.95) > maximum_p95
        ):
            identifiers.update(
                case.identifier
                for case in cases
                if case.result == "Passed"
            )
    return tuple(sorted(identifiers))


def activity_boundary_seconds(tree: Any) -> ActivityBoundary | None:
    if not isinstance(tree, dict):
        return None
    runs = tree.get("testRuns")
    if not isinstance(runs, list) or len(runs) != 1 or not isinstance(runs[0], dict):
        return None
    activities = runs[0].get("activities")
    if not isinstance(activities, list):
        return None
    starts = [
        activity.get("startTime")
        for activity in activities
        if isinstance(activity, dict)
        and isinstance(activity.get("title"), str)
        and activity["title"].startswith("Start Test at ")
    ]
    setups = [
        activity.get("startTime")
        for activity in activities
        if isinstance(activity, dict)
        and activity.get("title") == "Set Up"
    ]
    teardowns = [
        activity.get("startTime")
        for activity in activities
        if isinstance(activity, dict)
        and activity.get("title") == "Tear Down"
    ]
    if len(starts) != 1 or len(setups) != 1 or len(teardowns) != 1:
        return None
    start = finite_nonnegative(starts[0])
    setup = finite_nonnegative(setups[0])
    teardown = finite_nonnegative(teardowns[0])
    if (
        start is None
        or setup is None
        or teardown is None
        or setup < start
        or teardown <= setup
    ):
        return None
    return ActivityBoundary(
        attributed_duration_seconds=teardown - setup,
        excluded_pre_setup_seconds=setup - start,
    )


def load_activity_boundary(path: Path, identifier: str) -> ActivityBoundary | None:
    try:
        result = subprocess.run(
            [
                "xcrun",
                "xcresulttool",
                "get",
                "test-results",
                "activities",
                "--path",
                str(path),
                "--test-id",
                identifier,
            ],
            check=True,
            capture_output=True,
            text=True,
        )
        return activity_boundary_seconds(json.loads(result.stdout))
    except (subprocess.CalledProcessError, json.JSONDecodeError, OSError):
        return None


def reconcile_activity_boundary_noise(
    cases: Sequence[TestCaseRuntime],
    budget: dict[str, Any],
    *,
    selector_count: int,
    activity_boundary_loader: Callable[[str], ActivityBoundary | None],
) -> tuple[list[TestCaseRuntime], list[RuntimeAdjustment]]:
    review = set(cases_requiring_activity_review(
        cases,
        budget,
        selector_count=selector_count,
    ))
    adjusted_cases: list[TestCaseRuntime] = []
    adjustments: list[RuntimeAdjustment] = []
    for case in cases:
        reported = finite_nonnegative(case.duration_seconds)
        boundary = (
            activity_boundary_loader(case.identifier)
            if case.identifier in review
            else None
        )
        attributed = finite_nonnegative(
            boundary.attributed_duration_seconds if boundary is not None else None
        )
        excluded_pre_setup = finite_nonnegative(
            boundary.excluded_pre_setup_seconds if boundary is not None else None
        )
        excluded = (
            reported - attributed
            if reported is not None and attributed is not None
            else None
        )
        raw_excluded_post_teardown = (
            excluded - excluded_pre_setup
            if excluded is not None and excluded_pre_setup is not None
            else None
        )
        excluded_post_teardown = (
            max(0.0, raw_excluded_post_teardown)
            if raw_excluded_post_teardown is not None
            and raw_excluded_post_teardown >= -TIMING_PRECISION_TOLERANCE_SECONDS
            else None
        )
        if (
            case.result == "Passed"
            and reported is not None
            and attributed is not None
            and excluded_pre_setup is not None
            and attributed <= reported
            and excluded is not None
            and excluded >= HARNESS_NOISE_THRESHOLD_SECONDS
            and excluded_post_teardown is not None
            and excluded_post_teardown >= 0
        ):
            adjusted_cases.append(TestCaseRuntime(
                identifier=case.identifier,
                name=case.name,
                duration_seconds=attributed,
                result=case.result,
            ))
            adjustments.append(RuntimeAdjustment(
                identifier=case.identifier,
                reported_duration_seconds=reported,
                attributed_duration_seconds=attributed,
                excluded_pre_setup_seconds=excluded_pre_setup,
                excluded_post_teardown_seconds=excluded_post_teardown,
                excluded_harness_seconds=excluded,
            ))
        else:
            adjusted_cases.append(case)
    return adjusted_cases, adjustments


def budget_violations(
    cases: Sequence[TestCaseRuntime],
    budget: dict[str, Any],
    *,
    selector_count: int = 0,
) -> list[str]:
    violations: list[str] = []
    if selector_count < 0:
        violations.append(f"invalid selector count: {selector_count}")

    expected_count = expected_case_count(budget)
    if expected_count is None:
        violations.append("invalid budget: catalog.expectedCaseCount")

    raw_test_budgets = budget.get("testBudgetsSeconds")
    test_budgets = raw_test_budgets if isinstance(raw_test_budgets, dict) else {}
    if not isinstance(raw_test_budgets, dict):
        violations.append("invalid budget: testBudgetsSeconds")

    identifiers = [case.identifier for case in cases]
    duplicate_identifiers = sorted(
        identifier
        for identifier, count in Counter(identifiers).items()
        if count > 1
    )
    if duplicate_identifiers:
        violations.append(
            "result contains duplicate cases: " + ", ".join(duplicate_identifiers)
        )

    for case in cases:
        if case.result != "Passed":
            violations.append(f"{case.identifier}: result={case.result}")
        duration = finite_nonnegative(case.duration_seconds)
        if duration is None:
            violations.append(f"{case.identifier}: invalid test duration")
        maximum = test_budgets.get(case.identifier)
        if maximum is None:
            violations.append(f"{case.identifier}: missing runtime budget")
            continue
        accepted_maximum = finite_nonnegative(maximum)
        if accepted_maximum is None:
            violations.append(f"{case.identifier}: invalid runtime budget")
        elif duration is not None and duration > accepted_maximum:
            violations.append(
                f"{case.identifier}: {duration:.3f}s > {accepted_maximum:.3f}s"
            )

    is_full_catalog_execution = full_catalog_execution(budget, selector_count)
    if is_full_catalog_execution and len(cases) != expected_count:
        violations.append(
            "full suite: "
            f"result contains {len(cases)} cases, catalog requires {expected_count}"
        )
    elif selector_count > 0 and len(cases) != selector_count:
        violations.append(
            "scoped run: "
            f"result contains {len(cases)} cases for {selector_count} selectors"
        )

    if is_full_catalog_execution and len(cases) == expected_count:
        raw_suite = budget.get("fullSuite")
        suite = raw_suite if isinstance(raw_suite, dict) else {}
        maximum_total = finite_nonnegative(
            suite.get("maximumTestDurationSecondsPerLocale")
        )
        maximum_p95 = finite_nonnegative(suite.get("maximumP95Seconds"))
        if not isinstance(raw_suite, dict) or maximum_total is None:
            violations.append(
                "invalid budget: fullSuite.maximumTestDurationSecondsPerLocale"
            )
        if not isinstance(raw_suite, dict) or maximum_p95 is None:
            violations.append("invalid budget: fullSuite.maximumP95Seconds")

        valid_durations = [
            duration
            for case in cases
            if (duration := finite_nonnegative(case.duration_seconds)) is not None
        ]
        total = sum(valid_durations)
        p95 = percentile(valid_durations, 0.95)
        if maximum_total is not None and total > maximum_total:
            violations.append(
                "full suite: "
                f"{total:.3f}s > {maximum_total:.3f}s"
            )
        if maximum_p95 is not None and p95 > maximum_p95:
            violations.append(
                f"full suite p95: {p95:.3f}s > {maximum_p95:.3f}s"
            )
    return violations


def build_receipt(
    cases: Sequence[TestCaseRuntime],
    *,
    locale: str,
    selector_count: int,
    build_duration_seconds: float,
    wall_duration_seconds: float,
    budget: dict[str, Any],
    adjustments: Sequence[RuntimeAdjustment] = (),
) -> dict[str, Any]:
    durations = [
        duration
        for case in cases
        if (duration := finite_nonnegative(case.duration_seconds)) is not None
    ]
    violations = budget_violations(
        cases,
        budget,
        selector_count=selector_count,
    )
    return {
        "schemaVersion": RECEIPT_SCHEMA_VERSION,
        "measurementPolicy": MEASUREMENT_POLICY,
        "locale": locale,
        "selectorCount": selector_count,
        "caseCount": len(cases),
        "buildDurationSeconds": round(build_duration_seconds, 3),
        "testWallDurationSeconds": round(wall_duration_seconds, 3),
        "testDurationSeconds": round(sum(durations), 3),
        "p50Seconds": round(percentile(durations, 0.50), 3),
        "p95Seconds": round(percentile(durations, 0.95), 3),
        "maximumSeconds": round(max(durations, default=0.0), 3),
        "budgetStatus": "passed" if not violations else "failed",
        "budgetViolations": violations,
        "runtimeAdjustments": [
            {
                "identifier": adjustment.identifier,
                "reportedDurationSeconds": round(
                    adjustment.reported_duration_seconds, 3
                ),
                "attributedDurationSeconds": round(
                    adjustment.attributed_duration_seconds, 3
                ),
                "excludedPreSetupSeconds": round(
                    adjustment.excluded_pre_setup_seconds, 3
                ),
                "excludedPostTeardownSeconds": round(
                    adjustment.excluded_post_teardown_seconds, 3
                ),
                "excludedHarnessSeconds": round(
                    adjustment.excluded_harness_seconds, 3
                ),
                "reason": "outside-test-activity-boundaries",
            }
            for adjustment in adjustments
        ],
        "tests": [
            {
                "identifier": case.identifier,
                "durationSeconds": (
                    round(duration, 3)
                    if (duration := finite_nonnegative(case.duration_seconds)) is not None
                    else None
                ),
                "result": case.result,
            }
            for case in cases
        ],
    }


def load_xcresult_tree(path: Path) -> Any:
    result = subprocess.run(
        [
            "xcrun",
            "xcresulttool",
            "get",
            "test-results",
            "tests",
            "--path",
            str(path),
        ],
        check=True,
        capture_output=True,
        text=True,
    )
    return json.loads(result.stdout)


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    result.add_argument("--result", type=Path, help="xcresult bundle to inspect")
    result.add_argument("--tests-json", type=Path, help="pre-extracted test tree")
    result.add_argument("--budget", required=True, type=Path)
    result.add_argument("--output", required=True, type=Path)
    result.add_argument("--locale", required=True)
    result.add_argument("--selector-count", required=True, type=int)
    result.add_argument("--build-duration", required=True, type=float)
    result.add_argument("--wall-duration", required=True, type=float)
    result.add_argument("--enforce", action="store_true")
    return result


def input_failure_receipt(
    *,
    locale: str,
    selector_count: int,
    build_duration_seconds: float,
    wall_duration_seconds: float,
    error_class: str,
) -> dict[str, Any]:
    return {
        "schemaVersion": RECEIPT_SCHEMA_VERSION,
        "measurementPolicy": MEASUREMENT_POLICY,
        "locale": locale,
        "selectorCount": selector_count,
        "caseCount": 0,
        "buildDurationSeconds": finite_nonnegative(build_duration_seconds),
        "testWallDurationSeconds": finite_nonnegative(wall_duration_seconds),
        "testDurationSeconds": 0.0,
        "p50Seconds": 0.0,
        "p95Seconds": 0.0,
        "maximumSeconds": 0.0,
        "budgetStatus": "failed",
        "budgetViolations": [f"runtime input error: {error_class}"],
        "runtimeAdjustments": [],
        "tests": [],
    }


def write_receipt(path: Path, receipt: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(path.parent, 0o700)
    temporary = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    try:
        temporary.write_text(
            json.dumps(receipt, indent=2, sort_keys=True, allow_nan=False) + "\n",
            encoding="utf-8",
        )
        os.chmod(temporary, 0o600)
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def main(argv: Iterable[str] | None = None) -> int:
    arguments = parser().parse_args(argv)
    if (arguments.result is None) == (arguments.tests_json is None):
        print("Provide exactly one of --result or --tests-json.", file=sys.stderr)
        return 2

    input_error: str | None = None
    if arguments.selector_count < 0:
        input_error = "invalid-selector-count"
    elif finite_nonnegative(arguments.build_duration) is None:
        input_error = "invalid-build-duration"
    elif finite_nonnegative(arguments.wall_duration) is None:
        input_error = "invalid-wall-duration"

    tree: Any = None
    budget: Any = None
    if input_error is None:
        try:
            tree = (
                load_xcresult_tree(arguments.result)
                if arguments.result is not None
                else json.loads(arguments.tests_json.read_text(encoding="utf-8"))
            )
            budget = json.loads(arguments.budget.read_text(encoding="utf-8"))
        except subprocess.CalledProcessError:
            input_error = "unreadable-xcresult"
        except json.JSONDecodeError:
            input_error = "invalid-json"
        except OSError:
            input_error = "unreadable-input"

    if input_error is not None or not isinstance(budget, dict):
        receipt = input_failure_receipt(
            locale=arguments.locale,
            selector_count=arguments.selector_count,
            build_duration_seconds=arguments.build_duration,
            wall_duration_seconds=arguments.wall_duration,
            error_class=input_error or "invalid-budget-root",
        )
        write_receipt(arguments.output, receipt)
        print(f"UI runtime receipt failed closed: {receipt['budgetViolations'][0]}", file=sys.stderr)
        return 2

    cases = collect_test_cases(tree)
    adjustments: list[RuntimeAdjustment] = []
    if arguments.result is not None:
        cases, adjustments = reconcile_activity_boundary_noise(
            cases,
            budget,
            selector_count=arguments.selector_count,
            activity_boundary_loader=lambda identifier: load_activity_boundary(
                arguments.result,
                identifier,
            ),
        )
    receipt = build_receipt(
        cases,
        locale=arguments.locale,
        selector_count=arguments.selector_count,
        build_duration_seconds=arguments.build_duration,
        wall_duration_seconds=arguments.wall_duration,
        budget=budget,
        adjustments=adjustments,
    )
    write_receipt(arguments.output, receipt)
    print(
        "UI runtime receipt: "
        f"{receipt['caseCount']} cases, {receipt['testDurationSeconds']:.3f}s, "
        f"p95 {receipt['p95Seconds']:.3f}s, budget {receipt['budgetStatus']}, "
        f"harness adjustments {len(receipt['runtimeAdjustments'])}"
    )
    if arguments.enforce and receipt["budgetViolations"]:
        for violation in receipt["budgetViolations"]:
            print(f"UI runtime budget violation: {violation}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
