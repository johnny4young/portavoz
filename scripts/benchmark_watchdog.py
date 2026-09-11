#!/usr/bin/env python3
"""One directly owned deadline process for a disposable benchmark launcher.

The shell owner cancels and reaps this PID after the launcher finishes. Unlike
``(sleep N; ...) &``, cancellation cannot strand a timer holding stdout open.
Only the caller's still-owned launcher may be signalled; app cleanup remains
with the shell owner. Parent death also ends the waiting timer within one second.
"""

import argparse
import math
import os
from pathlib import Path
import signal
import subprocess
import sys
import time


KILL_GRACE_SECONDS = 5.0


def wait_for_deadline(seconds, owner_pid):
    deadline = time.monotonic() + seconds
    while os.getppid() == owner_pid:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            return True
        time.sleep(min(remaining, 1.0))
    return False


def is_owned_launcher(pid, owner_pid):
    result = subprocess.run(
        ["/bin/ps", "-p", str(pid), "-o", "ppid="],
        capture_output=True, text=True, timeout=5, check=False,
    )
    return result.returncode == 0 and result.stdout.strip() == str(owner_pid)


def signal_launcher(pid, owner_pid, value):
    if is_owned_launcher(pid, owner_pid):
        try:
            os.kill(pid, value)
        except ProcessLookupError:
            pass


def run(pid, seconds, marker):
    if type(pid) is not int or not 1 < pid < 2**31:
        raise ValueError("launcher PID must identify one process")
    if not math.isfinite(seconds) or not 0 < seconds <= 7_230:
        raise ValueError("deadline must be finite and within the benchmark bound")
    if not marker.is_absolute():
        raise ValueError("timeout marker must use an absolute scratch path")
    owner_pid = os.getppid()
    if owner_pid <= 1:
        return
    if not wait_for_deadline(seconds, owner_pid):
        return
    if not is_owned_launcher(pid, owner_pid):
        return
    marker_error = None
    try:
        descriptor = os.open(marker, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(descriptor, "w") as handle:
            handle.write("timed-out\n")
    except OSError as error:
        marker_error = error
    # A marker I/O failure is also terminal. Never leave the caller waiting
    # forever merely because its diagnostic could not be published.
    signal_launcher(pid, owner_pid, signal.SIGTERM)
    if wait_for_deadline(KILL_GRACE_SECONDS, owner_pid):
        signal_launcher(pid, owner_pid, signal.SIGKILL)
    if marker_error is not None:
        raise marker_error


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pid", type=int, required=True)
    parser.add_argument("--timeout", type=float, required=True)
    parser.add_argument("--marker", type=Path, required=True)
    arguments = parser.parse_args()
    try:
        run(arguments.pid, arguments.timeout, arguments.marker)
    except (OSError, ValueError, subprocess.SubprocessError):
        # No process metadata, paths, or raw errors enter qualification output.
        print("benchmark watchdog failed", file=sys.stderr)
        return 64
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
