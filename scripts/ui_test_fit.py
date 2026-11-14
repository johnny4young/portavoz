#!/usr/bin/env python3
"""Fit a pull request's ranked UI candidates into what remains of its job after the build."""

import argparse
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
from ui_test_catalog import (  # noqa: E402
    ALL_TESTS,
    UI_JOB_BUDGET_SECONDS,
    UI_JOB_CEILING_MINUTES,
    UI_JOB_TEARDOWN_SECONDS,
    UI_TEST_OVERHEAD_SECONDS,
)
from ui_test_scope import case_seconds, fit_ranked, hosted_seconds  # noqa: E402


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tests", required=True, help="Everything selected for this head")
    parser.add_argument("--ranked", default="", help="The candidates that may wait for nightly, best first")
    parser.add_argument("--elapsed", type=int, required=True, help="Seconds this job has already used")
    parser.add_argument("--ceiling-minutes", type=int, default=UI_JOB_CEILING_MINUTES,
                        help="The job's timeout; what must run has to end inside it")
    args = parser.parse_args()
    seconds = hosted_seconds(ROOT)
    ranked = tuple(args.ranked.split())
    required = [test for test in args.tests.split() if test not in ranked]
    needed = UI_TEST_OVERHEAD_SECONDS + sum(case_seconds(test, seconds) for test in required)
    room = args.ceiling_minutes * 60 - UI_JOB_TEARDOWN_SECONDS - args.elapsed
    if needed > room:
        # Fail here, by name, rather than let the timeout kill the job mid-test.
        print(f"::error title=ui-late-build::The build ended {args.elapsed} s into the job; the {len(required)} "
              f"cases that must run need {needed:.0f} s and only {max(0, room):.0f} s remain before the "
              f"{args.ceiling_minutes}-minute timeout.", file=sys.stderr)
        return 1
    left = UI_JOB_BUDGET_SECONDS - UI_JOB_TEARDOWN_SECONDS - args.elapsed
    tests, cut = fit_ranked(tuple(args.tests.split()), ranked, seconds, left)
    print(f"tests={' '.join(tests)}")
    print(f"cut={' '.join(cut)}")
    print(f"deferred={len(ALL_TESTS) - len(tests)}")
    print(f"left={max(0, round(left))}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
