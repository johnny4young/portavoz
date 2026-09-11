"""Executable pipe-lifetime tests for the actual benchmark shell owners."""

import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
import benchmark_watchdog as watchdog  # noqa: E402


class BenchmarkWatchdogShellTests(unittest.TestCase):
    def test_resource_completion_closes_inherited_output_without_waiting_for_deadline(self):
        self.assert_owner_closes_pipe("run-resource-baseline.sh", "run_benchmark_app")

    def test_leak_completion_closes_inherited_output_without_waiting_for_deadline(self):
        self.assert_owner_closes_pipe("run-apuntador-leak-baseline.sh", "run_under_leaks")

    def test_resource_timeout_cannot_accept_a_zero_exit_launcher(self):
        self.assert_owner_closes_pipe("run-resource-baseline.sh", "run_benchmark_app", expires=True)

    def test_leak_timeout_cannot_accept_a_zero_exit_launcher(self):
        self.assert_owner_closes_pipe("run-apuntador-leak-baseline.sh", "run_under_leaks", expires=True)

    def test_resource_parent_cancellation_reaps_owned_processes(self):
        self.assert_owner_closes_pipe("run-resource-baseline.sh", "run_benchmark_app", cancelled=True)

    def test_leak_parent_cancellation_reaps_owned_processes(self):
        self.assert_owner_closes_pipe("run-apuntador-leak-baseline.sh", "run_under_leaks", cancelled=True)

    def test_resource_watchdog_failure_cannot_publish_a_successful_launcher(self):
        self.assert_owner_closes_pipe("run-resource-baseline.sh", "run_benchmark_app", guard_fails=True)

    def test_leak_watchdog_failure_cannot_publish_a_successful_launcher(self):
        self.assert_owner_closes_pipe("run-apuntador-leak-baseline.sh", "run_under_leaks", guard_fails=True)

    def assert_owner_closes_pipe(self, filename, function, *, expires=False, cancelled=False, guard_fails=False):
        source = (ROOT / "scripts" / filename).read_text()
        body = re.search(rf"^{function}\(\) \{{\n.*?^\}}", source, re.M | re.S)
        self.assertIsNotNone(body)
        with tempfile.TemporaryDirectory(prefix="portavoz-watchdog-test-") as temp:
            directory = Path(temp)
            ready = directory / "timer-ready"
            for name, executable in [("sleep", "/bin/sleep"), ("python3", sys.executable)]:
                script = directory / name
                script.write_text(
                    '#!/bin/bash\nprintf ready > "$WATCHDOG_READY"\n'
                    + ('exit 78\n' if guard_fails and name == "python3" else f'exec "{executable}" "$@"\n')
                )
                script.chmod(0o700)
            target_ready = directory / "target-ready"
            target_terminated = directory / "target-terminated"
            waiter = directory / "wait.py"
            waiter.write_text(
                "import os, signal, sys, time\nfrom pathlib import Path\n"
                "def finish(*args):\n"
                "    Path(os.environ['TARGET_TERMINATED']).write_text('exit-zero')\n"
                "    sys.exit(0)\n"
                "signal.signal(signal.SIGTERM, finish)\n"
                "Path(os.environ['TARGET_READY']).touch()\n"
                "ready = Path(os.environ['WATCHDOG_READY'])\n"
                "deadline = time.monotonic() + 3\n"
                "while not ready.exists():\n"
                "    if time.monotonic() >= deadline: raise SystemExit(77)\n"
                "    time.sleep(0.01)\n"
                + ("while True: signal.pause()\n" if expires or cancelled else "")
            )
            command = '\n'.join([
                'set -euo pipefail',
                'ROOT="$REPOSITORY_ROOT"; RUN_ROOT="$WATCHDOG_DIRECTORY"',
                'APP="$RUN_ROOT/Disposable.app"; APP_EXECUTABLE="$APP/Contents/MacOS/probe"',
                'PROCESS_TIMEOUT=-29; TIMEOUT_SECONDS=-4' if expires else 'PROCESS_TIMEOUT=-10; TIMEOUT_SECONDS=15',
                'ACTIVE_PID=""; GUARD_PID=""; ACTIVE_GUARD_PID=""; ACTIVE_LAUNCH_PID=""',
                'terminate_benchmark_processes() { :; }',
                'terminate_probe_processes() { :; }',
                'fail() { echo "$*" >&2; exit 64; }',
                'open() { exec "$REAL_PYTHON" "$WATCHDOG_DIRECTORY/wait.py"; }',
                'xcrun() { exec "$REAL_PYTHON" "$WATCHDOG_DIRECTORY/wait.py"; }',
                re.search(r"^cleanup\(\) \{\n.*?^\}", source, re.M | re.S).group(),
                *re.findall(r"^trap .+$", source[:body.start()], re.M),
                body.group(),
                f'{function} example',
                'printf "owner completed\\n"',
            ])
            env = {**os.environ, "PATH": str(directory) + os.pathsep + os.environ['PATH'],
                   "WATCHDOG_READY": str(ready), "WATCHDOG_DIRECTORY": temp,
                   "REPOSITORY_ROOT": str(ROOT), "REAL_PYTHON": sys.executable,
                   "TARGET_READY": str(target_ready),
                   "TARGET_TERMINATED": str(target_terminated),
                   "PORTAVOZ_KEEP_RESOURCE_BENCH": "1", "PORTAVOZ_KEEP_LEAK_BENCH": "1"}
            process = subprocess.Popen(
                ["/bin/bash", "-c", command], env=env, text=True,
                stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True,
            )
            try:
                if cancelled:
                    deadline = time.monotonic() + 3
                    while not (ready.exists() and target_ready.exists()):
                        if time.monotonic() >= deadline:
                            self.fail("target and deadline must be armed before cancellation")
                        time.sleep(0.01)
                    process.send_signal(signal.SIGTERM)
                try:
                    stdout, stderr = process.communicate(timeout=5)
                except subprocess.TimeoutExpired:
                    self.fail("finished benchmark retained its output pipe until watchdog deadline")
                if cancelled:
                    self.assertEqual(process.returncode, 143, stderr)
                    self.assertNotIn("owner completed", stdout)
                elif guard_fails:
                    self.assertEqual(process.returncode, 64, stderr)
                    self.assertIn("deadline owner failed", stderr)
                    self.assertNotIn("owner completed", stdout)
                elif expires:
                    self.assertEqual(target_terminated.read_text(), "exit-zero")
                    self.assertEqual(process.returncode, 124 if function == "run_benchmark_app" else 64, stderr)
                    self.assertNotIn("owner completed", stdout)
                    self.assertIn("watchdog grace" if function == "run_benchmark_app" else "timed out", stderr)
                else:
                    self.assertEqual(process.returncode, 0, stderr)
                    self.assertIn("owner completed", stdout)
                self.assertTrue(ready.exists(), "test must actually arm the timer")
            finally:
                # This new process group contains only this disposable test.
                # Reap even an intentionally reproduced orphan without touching
                # any shared-host process or another test's process group.
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                process.communicate(timeout=5)


class BenchmarkWatchdogTests(unittest.TestCase):
    def test_invalid_arguments_fail_before_wait_or_signal(self):
        with mock.patch.object(watchdog, "wait_for_deadline") as wait:
            for pid, duration, marker in [
                (0, 1, Path("/tmp/unused")),
                (1, 1, Path("/tmp/unused")),
                (-1, 1, Path("/tmp/unused")),
                (True, 1, Path("/tmp/unused")),
                (2**31, 1, Path("/tmp/unused")),
                (42, 0, Path("/tmp/unused")),
                (42, float("inf"), Path("/tmp/unused")),
                (42, float("nan"), Path("/tmp/unused")),
                (42, 7231, Path("/tmp/unused")),
                (42, 1, Path("relative")),
            ]:
                with self.subTest(pid=pid, duration=duration, marker=marker):
                    with self.assertRaises(ValueError):
                        watchdog.run(pid, duration, marker)
            wait.assert_not_called()

    def test_parent_death_ends_timer_without_waiting_for_original_deadline(self):
        with mock.patch.object(watchdog.os, "getppid", side_effect=[10, 11]), \
             mock.patch.object(watchdog.time, "monotonic", side_effect=[100, 100]), \
             mock.patch.object(watchdog.time, "sleep") as sleep:
            self.assertFalse(watchdog.wait_for_deadline(60, 10))
            sleep.assert_called_once_with(1)

    def test_already_orphaned_start_never_arms_a_timer(self):
        with mock.patch.object(watchdog.os, "getppid", return_value=1), \
             mock.patch.object(watchdog, "wait_for_deadline") as wait, \
             mock.patch.object(watchdog, "signal_launcher") as send:
            watchdog.run(42, 60, Path("/tmp/unused"))
            wait.assert_not_called()
            send.assert_not_called()

    def test_deadline_uses_remaining_monotonic_duration(self):
        with mock.patch.object(watchdog.os, "getppid", return_value=10), \
             mock.patch.object(watchdog.time, "monotonic", side_effect=[100, 100.5, 101]), \
             mock.patch.object(watchdog.time, "sleep") as sleep:
            self.assertTrue(watchdog.wait_for_deadline(1, 10))
            sleep.assert_called_once_with(0.5)

    def test_disappeared_or_foreign_launcher_is_never_signalled(self):
        for status, parent in [(1, ""), (0, "99"), (0, "")]:
            result = subprocess.CompletedProcess([], status, stdout=parent)
            with self.subTest(status=status, parent=parent), \
                 mock.patch.object(watchdog.subprocess, "run", return_value=result), \
                 mock.patch.object(watchdog.os, "kill") as kill:
                watchdog.signal_launcher(42, 10, signal.SIGTERM)
                kill.assert_not_called()

    def test_signal_tolerates_launcher_exit_after_identity_check(self):
        with mock.patch.object(watchdog, "is_owned_launcher", return_value=True), \
             mock.patch.object(watchdog.os, "kill", side_effect=ProcessLookupError):
            watchdog.signal_launcher(42, 10, signal.SIGTERM)

    def test_timeout_marks_before_termination_and_preserves_five_second_grace(self):
        with tempfile.TemporaryDirectory() as temp, \
             mock.patch.object(watchdog.os, "getppid", return_value=10), \
             mock.patch.object(watchdog, "wait_for_deadline", return_value=True) as wait, \
             mock.patch.object(watchdog, "is_owned_launcher", return_value=True):
            marker = Path(temp) / "timed-out"
            delivered = []

            def receive_signal(pid, value):
                self.assertEqual(marker.read_text(), "timed-out\n")
                self.assertEqual(marker.stat().st_mode & 0o777, 0o600)
                delivered.append((pid, value))

            with mock.patch.object(watchdog.os, "kill", side_effect=receive_signal):
                watchdog.run(42, 12, marker)
            self.assertEqual(delivered, [(42, signal.SIGTERM), (42, signal.SIGKILL)])
            self.assertEqual(wait.call_args_list, [mock.call(12, 10), mock.call(5, 10)])

    def test_foreign_pid_after_grace_cannot_receive_kill(self):
        with tempfile.TemporaryDirectory() as temp, \
             mock.patch.object(watchdog.os, "getppid", return_value=10), \
             mock.patch.object(watchdog, "wait_for_deadline", return_value=True), \
             mock.patch.object(watchdog, "is_owned_launcher", side_effect=[True, True, False]), \
             mock.patch.object(watchdog.os, "kill") as kill:
            watchdog.run(42, 12, Path(temp) / "timed-out")
            kill.assert_called_once_with(42, signal.SIGTERM)

    def test_cancelled_timer_never_creates_marker_or_signals_launcher(self):
        with tempfile.TemporaryDirectory() as temp, \
             mock.patch.object(watchdog, "wait_for_deadline", return_value=False), \
             mock.patch.object(watchdog, "signal_launcher") as send:
            marker = Path(temp) / "timed-out"
            watchdog.run(42, 12, marker)
            self.assertFalse(marker.exists())
            send.assert_not_called()

    def test_marker_failure_does_not_overwrite_evidence_or_abandon_launcher(self):
        with tempfile.TemporaryDirectory() as temp, \
             mock.patch.object(watchdog.os, "getppid", return_value=10), \
             mock.patch.object(watchdog, "wait_for_deadline", return_value=True), \
             mock.patch.object(watchdog, "is_owned_launcher", return_value=True), \
             mock.patch.object(watchdog.os, "kill") as kill:
            marker = Path(temp) / "timed-out"
            marker.write_text("existing evidence")
            with self.assertRaises(FileExistsError):
                watchdog.run(42, 12, marker)
            self.assertEqual(marker.read_text(), "existing evidence")
            self.assertEqual(kill.call_args_list, [mock.call(42, signal.SIGTERM), mock.call(42, signal.SIGKILL)])


if __name__ == "__main__":
    unittest.main()
