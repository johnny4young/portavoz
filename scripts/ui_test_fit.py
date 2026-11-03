#!/usr/bin/env python3
"""Fit a pull request's ranked UI candidates into what remains of its job after the build."""

import argparse
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
from ui_test_catalog import ALL_TESTS, UI_JOB_BUDGET_SECONDS, UI_JOB_TEARDOWN_SECONDS  # noqa: E402
from ui_test_scope import fit_ranked, hosted_seconds  # noqa: E402


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tests", required=True, help="Everything selected for this head")
    parser.add_argument("--ranked", default="", help="The candidates that may wait for nightly, best first")
    parser.add_argument("--elapsed", type=int, required=True, help="Seconds this job has already used")
    args = parser.parse_args()
    left = UI_JOB_BUDGET_SECONDS - UI_JOB_TEARDOWN_SECONDS - args.elapsed
    tests, cut = fit_ranked(tuple(args.tests.split()), tuple(args.ranked.split()), hosted_seconds(ROOT), left)
    print(f"tests={' '.join(tests)}")
    print(f"cut={' '.join(cut)}")
    print(f"deferred={len(ALL_TESTS) - len(tests)}")
    print(f"left={max(0, round(left))}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
