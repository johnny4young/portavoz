#!/usr/bin/env python3
"""Write one small, content-free receipt of what a UI lane was asked to run and ran.

Kept on every run, unlike the large result bundle, so a later gate can verify
coverage for this exact head and attempt without downloading evidence.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import sys
from typing import Any, Sequence

sys.path.insert(0, str(Path(__file__).resolve().parent))
from ui_test_runtime import write_receipt  # noqa: E402
from ui_test_scope import runtime_budget_key  # noqa: E402

SCHEMA_VERSION = 1
CASE_KEYS = frozenset({"identifier", "result", "durationSeconds"})


def lane_receipt(*, locale: str, sha: str, attempt: int, toolchain: str, outcome: str, tests: str, deferred: int,
                 scope_unknown: bool, runtime: dict[str, Any] | None) -> dict[str, Any]:
    selected = {runtime_budget_key(selector): selector for selector in tests.split()}
    executed = [{key: case[key] for key in sorted(CASE_KEYS)}
                for case in (runtime or {}).get("tests", [])]
    ran = {case["identifier"] for case in executed}
    return {
        "schemaVersion": SCHEMA_VERSION,
        "locale": locale,
        "sha": sha,
        "attempt": attempt,
        "toolchain": toolchain,
        "outcome": outcome,
        "selection": {"selected": sorted(selected.values()), "deferred": deferred, "scopeUnknown": scope_unknown},
        "runtimeReceiptPresent": runtime is not None,
        "testDurationSeconds": (runtime or {}).get("testDurationSeconds"),
        "executed": executed,
        "notExecuted": sorted(selector for key, selector in selected.items() if key not in ran),
    }


def is_complete(receipt: dict[str, Any]) -> bool:
    """Whether the large result bundle has nothing left to explain."""
    return (receipt["outcome"] == "success" and receipt["runtimeReceiptPresent"] and not receipt["notExecuted"]
            and all(case["result"] == "Passed" for case in receipt["executed"]))


def read_runtime(path: Path) -> dict[str, Any] | None:
    try:
        document = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    cases = document.get("tests") if isinstance(document, dict) else None
    if not isinstance(cases, list) or not all(isinstance(case, dict) and CASE_KEYS <= case.keys() for case in cases):
        return None
    return document


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--locale", required=True)
    parser.add_argument("--results", type=Path, required=True)
    parser.add_argument("--sha", required=True)
    parser.add_argument("--attempt", type=int, required=True)
    parser.add_argument("--toolchain", required=True)
    parser.add_argument("--outcome", required=True)
    parser.add_argument("--tests", default="")
    parser.add_argument("--deferred", type=int, default=0)
    parser.add_argument("--scope-unknown", choices=("true", "false"), default="false")
    parser.add_argument("--github-output", type=Path)
    arguments = parser.parse_args(argv)
    receipt = lane_receipt(
        locale=arguments.locale, sha=arguments.sha, attempt=arguments.attempt, toolchain=arguments.toolchain.strip(),
        outcome=arguments.outcome, tests=arguments.tests, deferred=arguments.deferred,
        scope_unknown=arguments.scope_unknown == "true",
        runtime=read_runtime(arguments.results / f"{arguments.locale}-runtime.json"))
    write_receipt(arguments.results / f"{arguments.locale}-lane.json", receipt)
    if arguments.github_output:
        with arguments.github_output.open("a", encoding="utf-8") as output:
            output.write(f"complete={'true' if is_complete(receipt) else 'false'}\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
