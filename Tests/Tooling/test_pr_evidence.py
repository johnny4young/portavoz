"""PR screenshots, lane receipts and evidence publication (no hosted services)."""

import importlib.util
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))


def load(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / f"scripts/{name}.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


screenshots = load("pr_screenshots")
lane = load("ui_test_lane_receipt")


def attachment(name, exported=None):
    return {"suggestedHumanReadableName": f"{name}_0_ABC.png", "exportedFileName": exported or f"{name}.png"}


class ScreenshotSelectionTests(unittest.TestCase):
    def test_only_named_pr_pngs_are_selected(self):
        manifest = [{"attachments": [attachment("pr-library"), attachment("public-today"), attachment("Screenshot"),
                                     attachment("pr-Bad Name"), attachment("pr-log", "pr-log.txt")]}]

        self.assertEqual(screenshots.selected_attachments(manifest), {"pr-library": "pr-library.png"})

    def test_a_repeated_name_keeps_the_first_and_the_limit_holds(self):
        manifest = [{"attachments": [attachment(f"pr-{index}") for index in range(9)]},
                    {"attachments": [attachment("pr-0", "later.png")]}]

        selected = screenshots.selected_attachments(manifest)

        self.assertEqual(len(selected), screenshots.MAX_SCREENSHOTS)
        self.assertEqual(selected["pr-0"], "pr-0.png")

    def test_a_missing_bundle_never_fails_the_lane(self):
        with tempfile.TemporaryDirectory() as scratch:
            missing = Path(scratch) / "none.xcresult"
            self.assertEqual(screenshots.main(["--result", str(missing), "--output", str(Path(scratch) / "out")]), 0)


class LaneReceiptTests(unittest.TestCase):
    SELECTED = "PortavozUITests/LibraryUITests/testA PortavozUITests/LibraryUITests/testB"

    def receipt(self, runtime):
        return lane.lane_receipt(locale="en", sha="a" * 40, attempt=2, toolchain="Xcode 26.6", outcome="success",
                                 tests=self.SELECTED, deferred=189, scope_unknown=True, runtime=runtime)

    def test_it_names_what_was_selected_executed_and_missed(self):
        runtime = {"testDurationSeconds": 3.5, "tests": [
            {"identifier": "LibraryUITests/testA()", "result": "Passed", "durationSeconds": 3.5, "private": "drop"}]}

        result = self.receipt(runtime)

        self.assertEqual((result["sha"], result["attempt"], result["toolchain"]), ("a" * 40, 2, "Xcode 26.6"))
        self.assertEqual(result["selection"]["deferred"], 189)
        self.assertTrue(result["selection"]["scopeUnknown"])
        self.assertEqual(result["executed"], [
            {"identifier": "LibraryUITests/testA()", "result": "Passed", "durationSeconds": 3.5}])
        self.assertEqual(result["notExecuted"], ["PortavozUITests/LibraryUITests/testB"])

    def test_a_lane_without_a_runtime_receipt_executed_nothing(self):
        result = self.receipt(None)

        self.assertFalse(result["runtimeReceiptPresent"])
        self.assertEqual(result["executed"], [])
        self.assertEqual(len(result["notExecuted"]), 2)

    def test_the_command_writes_beside_the_other_receipts_even_with_unreadable_runtime(self):
        with tempfile.TemporaryDirectory() as scratch:
            results = Path(scratch)
            (results / "en-runtime.json").write_text("not json")

            status = lane.main(["--locale", "en", "--results", str(results), "--sha", "abc", "--attempt", "1",
                                "--toolchain", "Xcode 26.6\n", "--outcome", "failure", "--tests", self.SELECTED])

            written = json.loads((results / "en-lane.json").read_text())
        self.assertEqual(status, 0)
        self.assertEqual(written["toolchain"], "Xcode 26.6")
        self.assertFalse(written["runtimeReceiptPresent"])


class EvidencePublicationTests(unittest.TestCase):
    def setUp(self):
        scratch = tempfile.TemporaryDirectory()
        self.addCleanup(scratch.cleanup)
        self.root = Path(scratch.name)
        self.origin = self.root / "origin.git"
        self.clone = self.root / "clone"
        self.git(self.root, "init", "-q", "--bare", "-b", "main", str(self.origin))
        self.git(self.root, "clone", "-q", str(self.origin), str(self.clone))
        self.git(self.clone, "config", "user.email", "ci@example.test")
        self.git(self.clone, "config", "user.name", "CI")
        (self.clone / "README.md").write_text("main\n")
        self.git(self.clone, "add", ".")
        self.git(self.clone, "commit", "-qm", "main")
        self.git(self.clone, "push", "-q", "origin", "HEAD:main")
        fake = self.root / "bin"
        fake.mkdir()
        gh = fake / "gh"
        gh.write_text(
            '#!/usr/bin/env bash\n'
            'if [[ "$1" == repo ]]; then echo o/r; exit 0; fi\n'
            'while [[ $# -gt 0 ]]; do if [[ "$1" == --dir ]]; then dir="$2"; fi; shift; done\n'
            'mkdir -p "$dir"\n'
            '[[ -n "${FAKE_IMAGES:-}" ]] && for name in $FAKE_IMAGES; do echo image > "$dir/$name.png"; done\n'
            'exit 0\n')
        gh.chmod(gh.stat().st_mode | stat.S_IEXEC)
        self.environment = {**os.environ, "PATH": f"{fake}:{os.environ['PATH']}"}

    def git(self, cwd, *arguments):
        return subprocess.run(["git", *arguments], cwd=cwd, check=True, capture_output=True, text=True).stdout

    def publish(self, *arguments, images="pr-library"):
        return subprocess.run([str(ROOT / "scripts/pr-evidence.sh"), *arguments], cwd=self.clone, capture_output=True,
                              text=True, env={**self.environment, "FAKE_IMAGES": images}, check=False)

    def test_it_publishes_to_an_orphan_branch_and_prints_markdown(self):
        result = self.publish("204", "99")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(),
                         "![pr-library](https://raw.githubusercontent.com/o/r/pr-evidence/pr-204/pr-library.png)")
        self.assertEqual(self.git(self.origin, "ls-tree", "-r", "--name-only", "pr-evidence").split(),
                         ["pr-204/pr-library.png"])
        self.assertEqual(self.git(self.origin, "rev-list", "--count", "pr-evidence").strip(), "1")
        self.assertNotIn("pr-evidence", self.git(self.clone, "branch", "--show-current"))
        self.assertIn("/clone", self.git(self.clone, "worktree", "list"))
        self.assertEqual(len(self.git(self.clone, "worktree", "list").splitlines()), 1)

    def test_a_later_run_adds_to_the_branch_and_repeating_it_changes_nothing(self):
        self.publish("204", "99")
        self.publish("205", "100", images="pr-settings")
        before = self.git(self.origin, "rev-parse", "pr-evidence")

        repeated = self.publish("205", "100", images="pr-settings")

        self.assertEqual(repeated.returncode, 0, repeated.stderr)
        self.assertEqual(self.git(self.origin, "rev-parse", "pr-evidence"), before)
        self.assertEqual(self.git(self.origin, "ls-tree", "-r", "--name-only", "pr-evidence").split(),
                         ["pr-204/pr-library.png", "pr-205/pr-settings.png"])

    def test_a_run_without_screenshots_fails_and_publishes_nothing(self):
        result = self.publish("204", "99", images="")

        self.assertEqual(result.returncode, 66)
        self.assertNotIn("pr-evidence", self.git(self.origin, "branch", "--list", "pr-evidence"))

    def test_arguments_must_be_numbers(self):
        self.assertEqual(self.publish("abc", "99").returncode, 64)
        self.assertEqual(self.publish("204").returncode, 64)


if __name__ == "__main__":
    unittest.main()
