#!/usr/bin/env python3
"""Classify hosted XCUITest evidence without treating runner speed as truth."""

from __future__ import annotations

import argparse
import json
import math
import os
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
        "p50Seconds",
        "p95Seconds",
        "schemaVersion",
        "selectorCount",
        "testDurationSeconds",
        "testWallDurationSeconds",
        "tests",
    }
)
TEST_KEYS = frozenset({"durationSeconds", "identifier", "result"})
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


def load_receipt(path: Path, expected_locale: str) -> dict[str, Any]:
    try:
        receipt = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise GateError(f"{expected_locale}: runtime receipt is unreadable") from error
    if not isinstance(receipt, dict) or set(receipt) != RECEIPT_KEYS:
        raise GateError(f"{expected_locale}: runtime receipt shape differs")
    if receipt["schemaVersion"] != 1 or receipt["locale"] != expected_locale:
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
        output.write("| Locale | Step | Cases | Functional | Hosted runtime |\n")
        output.write("| --- | --- | ---: | --- | --- |\n")
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
            summary_rows.append(f"| {locale} | {outcome} | - | not selected | - |")
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
                f"{classification} | unavailable |"
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
            f"{functional} | advisory {runtime_status} |"
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
