import importlib.util
import io
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "check-ui-test-host.py"
WINDOW_PROBE = ROOT / "scripts" / "ui-test-window-probe.swift"
UI_TEST_SUPPORT = ROOT / "Tests" / "PortavozUITests" / "UITestSupport.swift"
SPEC = importlib.util.spec_from_file_location("check_ui_test_host", SCRIPT)
preflight = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
sys.modules[SPEC.name] = preflight
SPEC.loader.exec_module(preflight)


class FakeProbe:
    def __init__(self, *snapshots):
        self.snapshots = list(snapshots)
        self.calls = 0

    def snapshot(self):
        self.calls += 1
        value = self.snapshots.pop(0)
        if isinstance(value, Exception):
            raise value
        return value


def process(pid: int, command: str, executable_name: str | None = None):
    if executable_name is None:
        executable_name = Path(command.split(maxsplit=1)[0]).name
    return preflight.ProcessRecord(
        pid=pid,
        executable_name=executable_name,
        command=command,
    )


def snapshot(
        *processes,
        notification_center=0,
        security_agent=0,
        secure_input=False,
):
    return preflight.HostSnapshot(
        processes=tuple(processes),
        notification_center_windows=notification_center,
        security_agent_windows=security_agent,
        secure_input=secure_input,
    )


class UITestHostPreflightTests(unittest.TestCase):
    def run_fake(self, *snapshots):
        output = io.StringIO()
        sleeps = []
        probe = FakeProbe(*snapshots)
        result = preflight.run_preflight(
            probe,
            output=output,
            sleeper=sleeps.append,
        )
        return result, output.getvalue(), probe.calls, sleeps

    def test_clean_host_must_remain_clean_across_bounded_settle(self):
        result, output, calls, sleeps = self.run_fake(snapshot(), snapshot())

        self.assertEqual(result, 0)
        self.assertEqual(calls, 2)
        self.assertEqual(sleeps, [1.0])
        self.assertIn("stayed clear for one second", output)

    def test_security_agent_window_fails_without_a_second_probe(self):
        result, output, calls, sleeps = self.run_fake(
            snapshot(security_agent=1)
        )

        self.assertEqual(result, 1)
        self.assertEqual(calls, 1)
        self.assertEqual(sleeps, [])
        self.assertIn("SecurityAgent authentication window", output)
        self.assertIn("no process was terminated", output)

    def test_notification_alert_fails_without_reading_its_content(self):
        result, output, _, _ = self.run_fake(snapshot(notification_center=2))

        self.assertEqual(result, 1)
        self.assertIn("Notification Center alert", output)
        self.assertNotIn("window title", output.lower())

    def test_secure_input_fails_without_identifying_or_terminating_its_owner(self):
        result, output, calls, sleeps = self.run_fake(
            snapshot(secure_input=True)
        )

        self.assertEqual(result, 1)
        self.assertEqual(calls, 1)
        self.assertEqual(sleeps, [])
        self.assertIn("Another app owns Secure Input", output)
        self.assertIn("no process was terminated", output)

    def test_xcodebuild_test_actions_are_blockers(self):
        for command in (
                "/usr/bin/xcodebuild -project Other.xcodeproj test",
                "/Applications/Xcode Beta.app/Contents/Developer/usr/bin/xcodebuild "
                "test-without-building -scheme Other",
        ):
            with self.subTest(command=command):
                blockers = preflight.classify(
                    snapshot(process(10, command, executable_name="xcodebuild"))
                )
                self.assertEqual(blockers.xcode_test_process_count, 1)

    def test_xcodebuild_build_and_xcodebuildmcp_are_not_blockers(self):
        blockers = preflight.classify(
            snapshot(
                process(
                    10,
                    "/usr/bin/xcodebuild build-for-testing -scheme Other",
                    executable_name="xcodebuild",
                ),
                process(11, "npm exec xcodebuildmcp@latest mcp", "node"),
                process(12, "node /tmp/xcodebuildmcp mcp", "node"),
                process(13, "/bin/zsh -c /usr/bin/xcodebuild test", "zsh"),
            )
        )

        self.assertTrue(blockers.is_empty)

    def test_ui_runner_processes_are_blockers(self):
        for command in (
            "/tmp/OtherUITests-Runner.app/Contents/MacOS/OtherUITests-Runner",
            "/usr/bin/XCTRunner /tmp/OtherUITests.xctest",
            "/usr/bin/xctest /tmp/OtherUITests.xctest",
        ):
            with self.subTest(command=command):
                executable_name = (
                    "xctest" if command.startswith("/usr/bin/xctest") else None
                )
                blockers = preflight.classify(
                    snapshot(process(20, command, executable_name))
                )
                self.assertEqual(blockers.ui_test_runner_count, 1)

    def test_unit_xctest_and_persistent_testmanagerd_are_not_blockers(self):
        blockers = preflight.classify(
            snapshot(
                process(10, "/usr/bin/xctest /tmp/PortavozTests.xctest", "xctest"),
                process(11, "/usr/libexec/testmanagerd", "testmanagerd"),
            )
        )

        self.assertTrue(blockers.is_empty)

    def test_blocker_appearing_during_settle_fails_before_launch(self):
        result, output, calls, sleeps = self.run_fake(
            snapshot(),
            snapshot(process(30, "/usr/bin/xcodebuild test", "xcodebuild")),
        )

        self.assertEqual(result, 1)
        self.assertEqual(calls, 2)
        self.assertEqual(sleeps, [1.0])
        self.assertIn("Another xcodebuild test command", output)

    def test_probe_failure_is_fail_closed_and_content_free(self):
        result, output, calls, sleeps = self.run_fake(
            preflight.ProbeFailure("blocking-window inventory unavailable")
        )

        self.assertEqual(result, 2)
        self.assertEqual(calls, 1)
        self.assertEqual(sleeps, [])
        self.assertIn("blocking-window inventory unavailable", output)
        self.assertIn("No UI test was started", output)

    def test_system_probe_compiles_once_then_observes_twice(self):
        calls = []

        def command_runner(arguments, **options):
            calls.append((arguments, options))
            if arguments[0:2] == ["/usr/bin/xcrun", "swiftc"]:
                binary = Path(arguments[-1])
                binary.write_text("fixture", encoding="utf-8")
                binary.chmod(0o700)
                return subprocess.CompletedProcess(arguments, 0, "", "")
            return subprocess.CompletedProcess(
                arguments,
                0,
                '{"notificationCenter": 0, "securityAgent": 0, '
                '"secureInput": false}\n',
                "",
            )

        with tempfile.TemporaryDirectory() as directory:
            probe = preflight.SystemHostProbe(
                workspace=Path(directory),
                command_runner=command_runner,
            )

            first = probe._blocking_window_counts()
            second = probe._blocking_window_counts()

        self.assertEqual(first, second)
        self.assertEqual(
            first,
            {
                "notification_center_windows": 0,
                "security_agent_windows": 0,
                "secure_input": False,
            },
        )
        self.assertEqual(len(calls), 3)
        compiled_binary = calls[1][0][0]
        self.assertEqual(
            calls[0][0],
            [
                "/usr/bin/xcrun",
                "swiftc",
                "-warnings-as-errors",
                str(WINDOW_PROBE),
                "-o",
                compiled_binary,
            ],
        )
        self.assertEqual(calls[1][0], [compiled_binary])
        self.assertEqual(calls[2][0], [compiled_binary])
        self.assertEqual(
            [call[1]["timeout"] for call in calls],
            [60.0, 3.0, 3.0],
        )
        self.assertEqual(calls[1][0], calls[2][0])

    def test_system_probe_rejects_missing_compiled_binary(self):
        def command_runner(arguments, **_):
            return subprocess.CompletedProcess(arguments, 0, "", "")

        with tempfile.TemporaryDirectory() as directory:
            probe = preflight.SystemHostProbe(
                workspace=Path(directory),
                command_runner=command_runner,
            )

            with self.assertRaisesRegex(
                preflight.ProbeFailure,
                "blocking-window probe build unavailable",
            ):
                probe._blocking_window_counts()

    def test_system_probe_build_timeout_fails_closed(self):
        def command_runner(arguments, **options):
            raise subprocess.TimeoutExpired(arguments, options["timeout"])

        with tempfile.TemporaryDirectory() as directory:
            probe = preflight.SystemHostProbe(
                workspace=Path(directory),
                command_runner=command_runner,
            )

            with self.assertRaisesRegex(
                preflight.ProbeFailure,
                "blocking-window probe build unavailable",
            ):
                probe._blocking_window_counts()

    def test_system_probe_observation_timeout_fails_closed(self):
        def command_runner(arguments, **options):
            if arguments[0:2] == ["/usr/bin/xcrun", "swiftc"]:
                binary = Path(arguments[-1])
                binary.write_text("fixture", encoding="utf-8")
                binary.chmod(0o700)
                return subprocess.CompletedProcess(arguments, 0, "", "")
            raise subprocess.TimeoutExpired(arguments, options["timeout"])

        with tempfile.TemporaryDirectory() as directory:
            probe = preflight.SystemHostProbe(
                workspace=Path(directory),
                command_runner=command_runner,
            )

            with self.assertRaisesRegex(
                preflight.ProbeFailure,
                "blocking-window inventory unavailable",
            ):
                probe._blocking_window_counts()

    def test_window_payload_requires_exact_nonnegative_integers(self):
        self.assertEqual(
            preflight.exact_nonnegative_int({"securityAgent": 0}, "securityAgent"),
            0,
        )
        for payload in (
            {},
            {"securityAgent": True},
            {"securityAgent": -1},
            {"securityAgent": "1"},
            [],
        ):
            with self.subTest(payload=payload):
                with self.assertRaises((TypeError, ValueError)):
                    preflight.exact_nonnegative_int(payload, "securityAgent")

    def test_window_payload_rejects_missing_or_additional_keys(self):
        self.assertEqual(
            preflight.parse_window_inventory(
                '{"notificationCenter": 2, "securityAgent": 1, '
                '"secureInput": true}'
            ),
            (2, 1, True),
        )
        for payload in (
                '{"notificationCenter": 0, "securityAgent": 0}',
                '{"notificationCenter": 0, "securityAgent": 0, '
                '"secureInput": false, "title": "hidden"}',
        ):
            with self.subTest(payload=payload):
                with self.assertRaises(TypeError):
                    preflight.parse_window_inventory(payload)

    def test_window_payload_requires_an_exact_secure_input_boolean(self):
        for value in (0, 1, "true", None):
            with self.subTest(value=value):
                payload = {
                    "notificationCenter": 0,
                    "securityAgent": 0,
                    "secureInput": value,
                }
                with self.assertRaises(ValueError):
                    preflight.parse_window_inventory(
                        json.dumps(payload)
                    )

    def test_process_inventory_ignores_malformed_rows(self):
        records = preflight.parse_process_inventory(
            " 12 xcodebuild /usr/bin/xcodebuild test\n"
            "not-a-pid xcodebuild /usr/bin/xcodebuild test\n"
            "42\n"
            "-1 XCTRunner /usr/bin/XCTRunner\n"
        )

        self.assertEqual(
            records,
            (process(12, "/usr/bin/xcodebuild test", "xcodebuild"),),
        )

    def test_swift_window_probe_reads_no_title_or_dialog_content(self):
        source = WINDOW_PROBE.read_text(encoding="utf-8")
        checker = SCRIPT.read_text(encoding="utf-8")

        self.assertIn("kCGWindowOwnerName", source)
        self.assertIn("kCGWindowLayer", source)
        self.assertIn("import Carbon.HIToolbox", source)
        self.assertIn("IsSecureEventInputEnabled()", source)
        self.assertNotIn("CGSessionCopyCurrentDictionary", source)
        self.assertNotIn("kCGSSessionSecureInputPID", source)
        self.assertIn("layer >= 0", source)
        self.assertNotIn("kCGWindowName", source)
        self.assertNotIn("kCGWindowBounds", source)
        self.assertNotIn("System Events", source)
        self.assertNotIn("?? []", source)
        self.assertIn("exit(EXIT_FAILURE)", source)
        self.assertIn('"swiftc"', checker)
        self.assertIn("WINDOW_PROBE_BUILD_TIMEOUT_SECONDS = 60.0", checker)
        self.assertIn("WINDOW_PROBE_OBSERVATION_TIMEOUT_SECONDS = 3.0", checker)
        self.assertIn("self._window_probe_is_ready = True", checker)

    def test_make_preflight_uses_read_only_checker_and_never_kills_testmanagerd(self):
        makefile = (ROOT / "Makefile").read_text(encoding="utf-8")
        target = makefile.split("test-ui-preflight:", 1)[1].split(
            "\npublic-screenshots:", 1
        )[0]

        self.assertIn("scripts/check-ui-test-host.py", target)
        self.assertIn("with timeout of 3 seconds", target)
        self.assertNotIn("killall testmanagerd", target)
        self.assertNotIn("System Events", target)

    def test_ui_test_bundle_never_answers_external_prompts(self):
        source = UI_TEST_SUPPORT.read_text(encoding="utf-8")

        self.assertNotIn("addUIInterruptionMonitor", source)
        self.assertNotIn("com.apple.UserNotificationCenter", source)
        self.assertNotIn("typeKey(.escape", source)
        self.assertIn("installs no interruption monitor", source)

    def test_hygiene_owns_preflight_policy_without_ui_workflow_duplication(self):
        workflow = (ROOT / ".github/workflows/ui-tests.yml").read_text(
            encoding="utf-8"
        )
        hygiene = (ROOT / "scripts/check-repository-hygiene.sh").read_text(
            encoding="utf-8"
        )

        command = "python3 -m unittest Tests.Tooling.test_ui_test_host_preflight"
        self.assertIn(command, hygiene)
        self.assertNotIn(command, workflow)
        self.assertIn("make test-ui-run", workflow)
        self.assertIn("timeout-minutes: 60", workflow)


if __name__ == "__main__":
    unittest.main()
