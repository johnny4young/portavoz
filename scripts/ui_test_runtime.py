#!/usr/bin/env python3
"""Emit a content-free XCUITest runtime receipt and enforce accepted budgets."""

from __future__ import annotations

import argparse
import json
import math
import subprocess
import sys
from collections import Counter
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable, Sequence


@dataclass(frozen=True)
class TestCaseRuntime:
    identifier: str
    name: str
    duration_seconds: float
    result: str


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

    full_catalog_execution = (
        expected_count is not None
        and selector_count in {0, expected_count}
    )
    if full_catalog_execution and len(cases) != expected_count:
        violations.append(
            "full suite: "
            f"result contains {len(cases)} cases, catalog requires {expected_count}"
        )
    elif selector_count > 0 and len(cases) != selector_count:
        violations.append(
            "scoped run: "
            f"result contains {len(cases)} cases for {selector_count} selectors"
        )

    if full_catalog_execution and len(cases) == expected_count:
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
        "schemaVersion": 1,
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
        "schemaVersion": 1,
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
        "tests": [],
    }


def write_receipt(path: Path, receipt: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps(receipt, indent=2, sort_keys=True, allow_nan=False) + "\n",
        encoding="utf-8",
    )


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
    receipt = build_receipt(
        cases,
        locale=arguments.locale,
        selector_count=arguments.selector_count,
        build_duration_seconds=arguments.build_duration,
        wall_duration_seconds=arguments.wall_duration,
        budget=budget,
    )
    write_receipt(arguments.output, receipt)
    print(
        "UI runtime receipt: "
        f"{receipt['caseCount']} cases, {receipt['testDurationSeconds']:.3f}s, "
        f"p95 {receipt['p95Seconds']:.3f}s, budget {receipt['budgetStatus']}"
    )
    if arguments.enforce and receipt["budgetViolations"]:
        for violation in receipt["budgetViolations"]:
            print(f"UI runtime budget violation: {violation}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
