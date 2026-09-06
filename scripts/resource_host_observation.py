#!/usr/bin/env python3
"""Observe a finite host window without storing executable names, PIDs or arguments.

This is diagnostic context, NOT readiness, phase-level attribution or a gate.
Run in a separately owned terminal alongside a bounded resource experiment.
It samples closed CPU contributor classes every two seconds, never stops other
processes, ends on parent death, and retains interruption as adverse evidence.
"""

from __future__ import annotations

import argparse
import json
import math
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import threading
import time

from perf_host_readiness import parse_process_cpu


INTERVAL_SECONDS = 2.0
MAXIMUM_DURATION_SECONDS = 900


def snapshot():
    result = subprocess.run(
        ["/bin/ps", "-A", "-o", "pcpu=,comm="],
        capture_output=True, text=True, timeout=2, check=True,
    )
    total, interference, contributors, active = parse_process_cpu(result.stdout)
    if not all(math.isfinite(value) for value in (total, interference)):
        raise ValueError("invalid CPU inventory")
    return {
        "totalCPUPercent": total,
        "recognizedInterferenceCPUPercent": interference,
        "contributors": dict(contributors),
        "activePortavozAppCount": active,
    }


def observe(duration, stopped, *, read=snapshot, now=time.monotonic,
            parent_alive=lambda: True):
    if type(duration) is not int or not 2 <= duration <= MAXIMUM_DURATION_SECONDS:
        raise ValueError("duration must be an integer between 2 and 900 seconds")
    started = now()
    samples = []
    errors = 0
    outcome = "window-ended"
    # The sample bound is independent of scheduler delay or injected clocks.
    for _ in range(math.ceil(duration / INTERVAL_SECONDS)):
        if not parent_alive():
            outcome = "parent-lost"
            break
        if stopped.is_set():
            outcome = "interrupted"
            break
        if now() - started >= duration:
            break
        try:
            row = read()
            row["elapsedMilliseconds"] = round((now() - started) * 1_000, 3)
            samples.append(row)
        except (OSError, ValueError, subprocess.SubprocessError):
            errors += 1
        remaining = duration - (now() - started)
        if remaining > 0:
            stopped.wait(min(INTERVAL_SECONDS, remaining))
    if stopped.is_set():
        outcome = "interrupted"
    elif not parent_alive():
        outcome = "parent-lost"
    elapsed = now() - started
    if not math.isfinite(elapsed) or elapsed < 0:
        raise ValueError("invalid monotonic observation clock")
    if outcome == "window-ended" and elapsed < duration:
        outcome = "incomplete-window"
    return {
        "schemaVersion": 1,
        "kind": "resource-host-window",
        "qualificationAuthority": False,
        "phaseAttributionAvailable": False,
        "requestedDurationSeconds": duration,
        "elapsedMilliseconds": round(elapsed * 1_000, 3),
        "sampleIntervalSeconds": INTERVAL_SECONDS,
        "sampleErrors": errors,
        "outcome": outcome,
        "samples": samples,
    }


def write(document, output):
    if not output.is_absolute():
        raise ValueError("output must use an absolute scratch path")
    data = json.dumps(document, indent=2, sort_keys=True, allow_nan=False) + "\n"
    output.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    descriptor, name = tempfile.mkstemp(prefix=".host-observation-", dir=output.parent)
    temporary = Path(name)
    try:
        with os.fdopen(descriptor, "w") as handle:
            handle.write(data)
        # Atomic no-replace publication, including a pre-existing symlink.
        os.link(temporary, output)
    finally:
        temporary.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--duration", type=int, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    stopped = threading.Event()
    owner = os.getppid()
    for value in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(value, lambda *_: stopped.set())
    try:
        if owner <= 1 or not args.output.is_absolute() or os.path.lexists(args.output):
            raise ValueError("invalid observation owner or output")
        document = observe(
            args.duration, stopped, parent_alive=lambda: os.getppid() == owner)
        write(document, args.output)
        return 0 if (document["outcome"] == "window-ended"
                     and document["sampleErrors"] == 0 and document["samples"]) else 1
    except (OSError, ValueError):
        # Never serialize raw subprocess errors, paths or process inventory.
        print("resource host observation failed", file=sys.stderr)
        return 64


if __name__ == "__main__":
    raise SystemExit(main())
