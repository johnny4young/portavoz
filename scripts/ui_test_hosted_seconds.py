#!/usr/bin/env python3
"""Recompute the hosted p90 of each UI case from nightly job logs, for the runtime budget.

Refreshed by hand with: gh run view <run> --log > night.log, one file per night.
"""

from __future__ import annotations

import argparse
import collections
import json
import math
from pathlib import Path
import re
from typing import Iterable, Sequence

CASE = re.compile(r"Test [Cc]ase '-\[\w+\.(\w+) (\w+)\]' (?:passed|failed)[^\n]*?\(([\d.]+) seconds\)")


def nearest_rank_p90(samples: Sequence[float]) -> float:
    ordered = sorted(samples)
    return ordered[max(0, math.ceil(0.9 * len(ordered)) - 1)]


def hosted_seconds(logs: Iterable[str]) -> dict[str, float]:
    samples: dict[str, list[float]] = collections.defaultdict(list)
    for log in logs:
        for owner, method, seconds in CASE.findall(log):
            samples[f"{owner}/{method}()"].append(float(seconds))
    return {case: round(nearest_rank_p90(values), 1) for case, values in sorted(samples.items())}


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("logs", nargs="+", type=Path)
    arguments = parser.parse_args(argv)
    print(json.dumps(hosted_seconds(path.read_text(encoding="utf-8", errors="replace") for path in arguments.logs),
                     indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
