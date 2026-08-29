#!/usr/bin/env python3
"""Classify hosted XCUITest evidence without treating runner speed as truth."""

from __future__ import annotations

import argparse
import json
import math
import os
import re
import sys
from pathlib import Path
from typing import Any, Sequence


RECEIPT_KEYS = frozenset(
    {
        "budgetStatus",
        "budgetViolations",
        "buildDurationSeconds",
        "caseCount",
        "locale",
        "maximumSeconds",
        "measurementPolicy",
        "p50Seconds",
        "p95Seconds",
        "runtimeAdjustments",
        "schemaVersion",
        "selectorCount",
        "testDurationSeconds",
        "testWallDurationSeconds",
        "tests",
    }
)
TEST_KEYS = frozenset({"durationSeconds", "identifier", "result"})
ADJUSTMENT_KEYS = frozenset(
    {
        "attributedDurationSeconds",
        "excludedHarnessSeconds",
        "identifier",
        "reason",
        "reportedDurationSeconds",
    }
)
RECEIPT_SCHEMA_VERSION = 2
MEASUREMENT_POLICY = "xcresult-duration-with-post-teardown-exclusion-v1"
POST_TEARDOWN_NOISE_THRESHOLD_SECONDS = 1.0
CASE_RUNTIME_DRIFT_PATTERN = re.compile(
    r"^(?P<identifier>[^:]+): "
    r"[0-9]+(?:\.[0-9]+)?s > [0-9]+(?:\.[0-9]+)?s$"
)
SUITE_RUNTIME_DRIFT_PATTERNS = (
    re.compile(r"^full suite: [0-9]+(?:\.[0-9]+)?s > [0-9]+(?:\.[0-9]+)?s$"),
    re.compile(r"^full suite p95: [0-9]+(?:\.[0-9]+)?s > [0-9]+(?:\.[0-9]+)?s$"),
)
SUPPORTED_LOCALES = ("en", "es")
SUPPORTED_OUTCOMES = frozenset({"success", "failure", "cancelled", "skipped"})


class GateError(RuntimeError):
    """The hosted evidence is incomplete or malformed."""


def parser() -> argparse.ArgumentParser:
    value = argparse.ArgumentParser(description=__doc__)
    value.add_argument("--results", type=Path, required=True)
    value.add_argument("--locales", required=True)
    value.add_argument("--english-outcome", required=True)
    value.add_argument("--spanish-outcome", required=True)
    value.add_argument("--summary", type=Path)
    return value


def finite_nonnegative(value: Any) -> bool:
    return (
        isinstance(value, (int, float))
        and not isinstance(value, bool)
        and math.isfinite(value)
        and value >= 0
    )


def is_runtime_drift_violation(
    value: str,
    case_identifiers: set[str],
) -> bool:
    if any(
        pattern.fullmatch(value)
        for pattern in SUITE_RUNTIME_DRIFT_PATTERNS
    ):
        return True
    case_match = CASE_RUNTIME_DRIFT_PATTERN.fullmatch(value)
    if case_match is not None:
        return case_match.group("identifier") in case_identifiers
    return False


def load_receipt(path: Path, expected_locale: str) -> dict[str, Any]:
    try:
        receipt = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise GateError(f"{expected_locale}: runtime receipt is unreadable") from error
    if not isinstance(receipt, dict) or set(receipt) != RECEIPT_KEYS:
        raise GateError(f"{expected_locale}: runtime receipt shape differs")
    if (
        receipt["schemaVersion"] != RECEIPT_SCHEMA_VERSION
        or receipt["measurementPolicy"] != MEASUREMENT_POLICY
        or receipt["locale"] != expected_locale
    ):
        raise GateError(f"{expected_locale}: runtime receipt identity differs")
    cases = receipt["tests"]
    if (
        not isinstance(receipt["caseCount"], int)
        or isinstance(receipt["caseCount"], bool)
        or receipt["caseCount"] <= 0
        or not isinstance(cases, list)
        or len(cases) != receipt["caseCount"]
    ):
        raise GateError(f"{expected_locale}: runtime receipt case count differs")
    for case in cases:
        if not isinstance(case, dict) or set(case) != TEST_KEYS:
            raise GateError(f"{expected_locale}: runtime test case shape differs")
        if (
            not isinstance(case["identifier"], str)
            or not case["identifier"]
            or not isinstance(case["result"], str)
            or not case["result"]
            or not finite_nonnegative(case["durationSeconds"])
        ):
            raise GateError(f"{expected_locale}: runtime test case is invalid")
    tests_by_identifier = {case["identifier"]: case for case in cases}
    if len(tests_by_identifier) != len(cases):
        raise GateError(f"{expected_locale}: runtime receipt repeats a test case")
    adjustments = receipt["runtimeAdjustments"]
    if not isinstance(adjustments, list):
        raise GateError(f"{expected_locale}: runtime adjustments are invalid")
    adjusted_identifiers: set[str] = set()
    for adjustment in adjustments:
        if not isinstance(adjustment, dict) or set(adjustment) != ADJUSTMENT_KEYS:
            raise GateError(f"{expected_locale}: runtime adjustment shape differs")
        identifier = adjustment["identifier"]
        if (
            not isinstance(identifier, str)
            or identifier not in tests_by_identifier
            or identifier in adjusted_identifiers
            or tests_by_identifier[identifier]["result"] != "Passed"
            or adjustment["reason"] != "post-teardown-unattributed-time"
        ):
            raise GateError(f"{expected_locale}: runtime adjustment identity differs")
        reported = adjustment["reportedDurationSeconds"]
        attributed = adjustment["attributedDurationSeconds"]
        excluded = adjustment["excludedHarnessSeconds"]
        if (
            not finite_nonnegative(reported)
            or not finite_nonnegative(attributed)
            or not finite_nonnegative(excluded)
            or attributed > reported
            or excluded < POST_TEARDOWN_NOISE_THRESHOLD_SECONDS
            or abs((reported - attributed) - excluded) > 0.002
            or abs(tests_by_identifier[identifier]["durationSeconds"] - attributed)
            > 0.002
        ):
            raise GateError(f"{expected_locale}: runtime adjustment values differ")
        adjusted_identifiers.add(identifier)
    for key in (
        "buildDurationSeconds",
        "maximumSeconds",
        "p50Seconds",
        "p95Seconds",
        "testDurationSeconds",
        "testWallDurationSeconds",
    ):
        if not finite_nonnegative(receipt[key]):
            raise GateError(f"{expected_locale}: {key} is invalid")
    if (
        not isinstance(receipt["selectorCount"], int)
        or isinstance(receipt["selectorCount"], bool)
        or receipt["selectorCount"] < 0
    ):
        raise GateError(f"{expected_locale}: selector count is invalid")
    violations = receipt["budgetViolations"]
    if (
        receipt["budgetStatus"] not in {"passed", "failed"}
        or not isinstance(violations, list)
        or not all(isinstance(item, str) and item for item in violations)
        or (receipt["budgetStatus"] == "passed") != (not violations)
    ):
        raise GateError(f"{expected_locale}: runtime budget classification differs")
    non_runtime_violations = [
        violation
        for violation in violations
        if not is_runtime_drift_violation(violation, set(tests_by_identifier))
    ]
    if non_runtime_violations:
        raise GateError(
            f"{expected_locale}: runtime receipt has evidence-contract violations"
        )
    return receipt


def annotation(message: str) -> str:
    return message.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")


def classify_failure(receipt: dict[str, Any] | None) -> str:
    if receipt is None:
        return "infrastructure-or-harness"
    if any(case["result"] != "Passed" for case in receipt["tests"]):
        return "product-or-test-regression"
    if receipt["budgetStatus"] == "failed":
        return "hosted-runtime-drift"
    return "infrastructure-or-harness"


def write_summary(path: Path | None, rows: Sequence[str]) -> None:
    if path is None:
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as output:
        output.write("## Scoped UI evidence\n\n")
        output.write(
            "| Locale | Step | Cases | Functional | Hosted runtime | "
            "Excluded harness stalls |\n"
        )
        output.write("| --- | --- | ---: | --- | --- | ---: |\n")
        for row in rows:
            output.write(row + "\n")


def main(argv: Sequence[str] | None = None) -> int:
    arguments = parser().parse_args(argv)
    selected = tuple(dict.fromkeys(arguments.locales.split()))
    if not selected or any(locale not in SUPPORTED_LOCALES for locale in selected):
        print("UI CI gate failed: unsupported selected locales.", file=sys.stderr)
        return 2
    outcomes = {
        "en": arguments.english_outcome,
        "es": arguments.spanish_outcome,
    }
    if any(outcome not in SUPPORTED_OUTCOMES for outcome in outcomes.values()):
        print("UI CI gate failed: unsupported step outcome.", file=sys.stderr)
        return 2

    failures: list[str] = []
    summary_rows: list[str] = []
    for locale in SUPPORTED_LOCALES:
        outcome = outcomes[locale]
        if locale not in selected:
            if outcome != "skipped":
                failures.append(f"{locale}: unselected locale ran with outcome {outcome}")
            summary_rows.append(
                f"| {locale} | {outcome} | - | not selected | - | - |"
            )
            continue

        receipt: dict[str, Any] | None = None
        receipt_error: str | None = None
        try:
            receipt = load_receipt(arguments.results / f"{locale}-runtime.json", locale)
        except GateError as error:
            receipt_error = str(error)

        if outcome != "success" or receipt_error is not None:
            classification = classify_failure(receipt)
            detail = receipt_error or f"step outcome {outcome}"
            failures.append(f"{locale}: {classification}: {detail}")
            summary_rows.append(
                f"| {locale} | {outcome} | "
                f"{receipt['caseCount'] if receipt else '-'} | "
                f"{classification} | unavailable | - |"
            )
            continue

        assert receipt is not None
        nonpassing = [case for case in receipt["tests"] if case["result"] != "Passed"]
        if nonpassing:
            failures.append(f"{locale}: product-or-test-regression: non-passing cases")
            functional = "failed"
        else:
            functional = "passed"
        runtime_status = receipt["budgetStatus"]
        if runtime_status == "failed":
            detail = "; ".join(receipt["budgetViolations"])
            print(
                "::warning title=Hosted UI runtime advisory::"
                + annotation(f"{locale}: {detail}")
            )
        summary_rows.append(
            f"| {locale} | {outcome} | {receipt['caseCount']} | "
            f"{functional} | advisory {runtime_status} | "
            f"{len(receipt['runtimeAdjustments'])} |"
        )

    summary_path = arguments.summary
    if summary_path is None and os.environ.get("GITHUB_STEP_SUMMARY"):
        summary_path = Path(os.environ["GITHUB_STEP_SUMMARY"])
    write_summary(summary_path, summary_rows)
    if failures:
        for failure in failures:
            print(f"UI CI gate failed: {failure}", file=sys.stderr)
        return 1
    print(
        "Hosted UI functional gate passed; wall-clock budgets remain advisory "
        "outside controlled performance authority."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
