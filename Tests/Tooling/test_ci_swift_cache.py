"""Cache compatibility and execution-policy regressions (no macOS required)."""

import contextlib
import importlib.util
import io
import os
from pathlib import Path
import re
import subprocess
import tempfile
import textwrap
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("ci_swift_cache_key", ROOT / "scripts/ci_swift_cache_key.py")
cache = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(cache)


class SwiftCacheIdentityTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory()
        self.addCleanup(self.scratch.cleanup)
        self.root = Path(self.scratch.name)
        for name in cache.INPUTS:
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(name)
        self.environment = patch.dict(os.environ, {
            "DEVELOPER_DIR": str(self.root), "ImageOS": "macos26", "ImageVersion": "20261001.1",
        })
        self.environment.start()
        self.addCleanup(self.environment.stop)
        self.commands = patch.object(cache, "command_output", side_effect=lambda command: " ".join(command))
        self.commands.start()
        self.addCleanup(self.commands.stop)
        self.machine = patch.object(cache.platform, "machine", return_value="arm64")
        self.machine.start()
        self.addCleanup(self.machine.stop)

    def key(self, lane="build-and-test"):
        return cache.cache_key(self.root, lane)

    def test_key_is_deterministic_bounded_and_safe_for_github_output(self):
        self.assertEqual(self.key(), self.key())
        self.assertRegex(self.key(), r"^swift-build-v1-build-and-test-[a-f0-9]{64}$")
        self.assertLess(len(self.key()), 512)

    def test_each_build_policy_input_invalidates_the_key(self):
        baseline = self.key()
        for name in cache.INPUTS:
            with self.subTest(name=name):
                path = self.root / name
                original = path.read_bytes()
                path.write_bytes(original + b"\nchanged")
                self.assertNotEqual(self.key(), baseline)
                path.write_bytes(original)
                self.assertEqual(self.key(), baseline)

    def test_lane_image_architecture_and_developer_directory_are_separate(self):
        baseline = self.key()
        self.assertNotEqual(self.key("sequoia-compatibility"), baseline)
        for name in ("ImageOS", "ImageVersion", "DEVELOPER_DIR"):
            with self.subTest(name=name):
                changed = self.root / "other-xcode"
                changed.mkdir(exist_ok=True)
                with patch.dict(os.environ, {name: str(changed)}):
                    self.assertNotEqual(self.key(), baseline)
        with patch.object(cache.platform, "machine", return_value="x86_64"):
            self.assertNotEqual(self.key(), baseline)

    def test_each_tool_and_sdk_identity_invalidates_the_key(self):
        baseline = self.key()
        for changed in cache.COMMANDS:
            with self.subTest(command=changed), patch.object(
                cache, "command_output",
                side_effect=lambda command: "changed" if command == changed else " ".join(command),
            ):
                self.assertNotEqual(self.key(), baseline)

    def test_workspace_path_cannot_reuse_absolute_compiler_state(self):
        baseline = self.key()
        with patch.object(cache.Path, "resolve", return_value=Path("/different/workspace")):
            self.assertNotEqual(self.key(), baseline)

    def test_first_party_changes_do_not_create_a_multi_gigabyte_cache_per_push(self):
        baseline = self.key()
        source = self.root / "Sources/Example.swift"
        source.parent.mkdir()
        source.write_text("let value = 1")
        self.assertEqual(self.key(), baseline)
        source.write_text("let value = 2")
        self.assertEqual(self.key(), baseline)
        source.unlink()
        self.assertEqual(self.key(), baseline)
        # This only proves key policy. Native fresh-checkout/changed-source runs
        # separately qualify SwiftPM invalidation; cache state is never test proof.

    def test_missing_input_or_tool_identity_fails_instead_of_a_broad_fallback(self):
        with patch.object(cache, "command_output", side_effect=subprocess.CalledProcessError(1, "xcrun")):
            with self.assertRaises(subprocess.CalledProcessError):
                self.key()
        (self.root / "Package.resolved").unlink()
        with self.assertRaises(FileNotFoundError):
            self.key()

    def test_unknown_lane_and_missing_developer_directory_are_rejected(self):
        with self.assertRaises(ValueError):
            self.key("ios-portability")
        with patch.dict(os.environ, {"DEVELOPER_DIR": ""}):
            with self.assertRaises(ValueError):
                self.key()

    def test_cli_emits_only_one_key_line_and_fails_closed(self):
        with patch.object(cache, "ROOT", self.root), patch("sys.argv", ["cache", "--lane", "build-and-test"]):
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                self.assertEqual(cache.main(), 0)
            self.assertEqual(output.getvalue(), f"key={self.key()}\n")
            with patch.object(cache, "cache_key", side_effect=ValueError("invalid")):
                with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as error:
                    cache.main()
                self.assertEqual(error.exception.code, 1)


class SwiftCacheCommandTests(unittest.TestCase):
    def test_command_collection_is_bounded_and_rejects_empty_or_failed_output(self):
        with patch.object(cache.subprocess, "run") as run:
            run.return_value.stdout = "identity\n"
            self.assertEqual(cache.command_output(("xcrun", "swift", "--version")), "identity")
            run.assert_called_once_with(("xcrun", "swift", "--version"), check=True,
                                        text=True, capture_output=True, timeout=30)
            run.return_value.stdout = " \n"
            with self.assertRaises(ValueError):
                cache.command_output(("xcrun",))
            run.side_effect = subprocess.TimeoutExpired("xcrun", 30)
            with self.assertRaises(subprocess.TimeoutExpired):
                cache.command_output(("xcrun",))


class SwiftCacheWorkflowTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.workflow = (ROOT / ".github/workflows/ci.yml").read_text()
        cls.jobs = dict(re.findall(r"^  ([a-z][a-z-]+):\n(.*?)(?=^  [a-z][a-z-]+:\n|\Z)",
                                  cls.workflow, re.MULTILINE | re.DOTALL))

    def test_only_complete_swift_test_lanes_use_the_cache(self):
        for name, job in self.jobs.items():
            with self.subTest(job=name):
                self.assertEqual("actions/cache/restore@" in job, name in cache.LANES)
                self.assertEqual("actions/cache/save@" in job, name in cache.LANES)

    def test_main_is_cold_no_cross_toolchain_prefix_and_tests_are_unconditional(self):
        for lane in cache.LANES:
            with self.subTest(lane=lane):
                job = self.jobs[lane]
                steps = job.split("      - ")[1:]
                compile_steps = [step for step in steps if "run: scripts/run-swift-tests.sh" in step]
                self.assertEqual(len(compile_steps), 1)
                self.assertNotIn("if:", compile_steps[0])
                self.assertNotIn("continue-on-error:", compile_steps[0])
                self.assertNotIn("--skip-build", compile_steps[0])
                self.assertNotIn("--filter", compile_steps[0])
                restore = next(step for step in steps if "actions/cache/restore@" in step)
                self.assertIn("lookup-only: ${{ github.event_name != 'pull_request' }}", restore)
                self.assertIn('SEGMENT_DOWNLOAD_TIMEOUT_MINS: "2"', restore)
                self.assertNotIn("restore-keys", job)
                self.assertNotIn("enableCrossOsArchive", job)
                self.assertEqual(job.count("          path: .build\n"), 2)
                self.assertEqual(job.count("key: ${{ steps.swift_cache_key.outputs.key }}"), 2)
                save = next(step for step in steps if "actions/cache/save@" in step)
                self.assertIn("if: steps.swift_cache_size.outputs.save == 'true'", save)
                self.assertNotIn("always()", job)
                self.assertLess(job.index("run: scripts/run-swift-tests.sh"), job.index("id: swift_cache_size"))
                self.assertLess(job.index("id: swift_cache_size"), job.index("actions/cache/save@"))
                self.assertIn(f"--lane {lane}", job)
                self.assertNotIn("touch ", job)

    def test_actual_size_gate_does_not_save_oversize_or_failed_measurements(self):
        for lane in cache.LANES:
            step = self.jobs[lane].split("      - name: Check Swift cache size\n", 1)[1].split("      - name:", 1)[0]
            self.assertIn("if: steps.swift_cache.outputs.cache-hit != 'true'", step)
            shell = textwrap.dedent(step.split("        run: |\n", 1)[1])
            with tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                binary = root / "du"
                binary.write_text('#!/bin/sh\nprintf "%s\\t.build\\n" "$SIZE"\nexit "$DU_EXIT"\n')
                binary.chmod(0o755)
                for size, status, admitted in ((1, 0, True), (6291456, 0, True),
                                               (6291457, 0, False), (1, 1, False)):
                    with self.subTest(lane=lane, size=size, status=status):
                        output = root / "output"
                        output.write_text("")
                        env = dict(os.environ, PATH=f"{root}:{os.environ['PATH']}",
                                   SIZE=str(size), DU_EXIT=str(status), GITHUB_OUTPUT=str(output))
                        result = subprocess.run(["bash", "-euo", "pipefail", "-c", shell],
                                                env=env, capture_output=True, text=True, timeout=5)
                        self.assertEqual(output.read_text() == "save=true\n", admitted)
                        self.assertEqual(result.returncode == 0, status == 0)

    def test_cache_policy_runs_in_repository_hygiene(self):
        self.assertIn("python3 -m unittest Tests.Tooling.test_ci_swift_cache\n",
                      (ROOT / "scripts/check-repository-hygiene.sh").read_text())


if __name__ == "__main__":
    unittest.main()
