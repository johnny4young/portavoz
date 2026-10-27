import contextlib
import importlib.util
import io
from pathlib import Path
import re
import shutil
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("ios_portability_scope", ROOT / "scripts/ios_portability_scope.py")
scope = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(scope)

SHARED = [
    "Sources/ApplicationKit", "Sources/AudioPlaybackKit", "Sources/DiarizationKit",
    "Sources/IntegrationsKit", "Sources/IntelligenceKit", "Sources/ModelStoreKit",
    "Sources/PortavozCore", "Sources/StorageKit", "Sources/TranscriptionKit",
]


class IOSPortabilityScopeTests(unittest.TestCase):
    def test_closure_follows_the_runner_targets_through_the_manifest(self):
        self.assertEqual(scope.roots(ROOT), ["PortavozCore", "StorageKit", "ApplicationKit", "IntegrationsKit"])
        self.assertEqual(scope.closure(ROOT), SHARED)
        graph = scope.targets(ROOT)
        self.assertEqual(graph["PortavozCLIKit"][1], "Sources/portavoz-cli")
        self.assertNotIn("FluidAudio", graph["TranscriptionKit"][0])

    def test_app_cli_tests_docs_and_tooling_changes_skip_the_lane(self):
        for changed in (["Sources/portavoz-app/DictationController.swift"],
                        ["Sources/portavoz-cli/Main.swift", "Sources/AudioCaptureKit/Tap.swift"],
                        ["Tests/PortavozTests/StorageTests.swift", "docs/specs/08-quality.md"],
                        ["Sources/StorageKitExtra/Sibling.swift"],
                        [".github/workflows/ui-tests.yml", "site/index.html"], []):
            with self.subTest(changed=changed):
                self.assertFalse(scope.required(ROOT, changed))

    def test_shared_sources_and_lane_policy_require_the_lane(self):
        for changed in (["Sources/StorageKit/MeetingStore.swift"],
                        ["Sources/IntelligenceKit/Resources/Model.json"],
                        ["Package.swift"], ["Package.resolved"],
                        ["scripts/check-ios-portability.sh"], ["scripts/ios_portability_scope.py"],
                        [".github/workflows/ci.yml"],
                        ["docs/a.md", "Sources/ModelStoreKit/Catalog.swift"]):
            with self.subTest(changed=changed):
                self.assertTrue(scope.required(ROOT, changed))

    def test_an_undeclared_runner_target_fails_instead_of_shrinking_the_scope(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "scripts").mkdir()
            shutil.copy(ROOT / "Package.swift", root / "Package.swift")
            (root / scope.RUNNER).write_text("targets=(PortavozCore MissingKit)\n")
            with self.assertRaises(ValueError):
                scope.closure(root)
            (root / scope.RUNNER).write_text("echo no targets\n")
            with self.assertRaises(ValueError):
                scope.closure(root)

    def test_cli_fails_closed_when_the_diff_cannot_be_read(self):
        output, errors = io.StringIO(), io.StringIO()
        arguments = ["scope", "--base", "0" * 40, "--head", "f" * 40]
        with patch("sys.argv", arguments), contextlib.redirect_stdout(output), contextlib.redirect_stderr(errors):
            self.assertEqual(scope.main(), 0)
        self.assertEqual(output.getvalue(), "required=true\n")
        self.assertIn("failed closed", errors.getvalue())

    def test_workflow_gates_only_the_ios_lane_and_always_runs_it_outside_prs(self):
        workflow = (ROOT / ".github/workflows/ci.yml").read_text()
        jobs = dict(re.findall(r"^  ([a-z][a-z-]+):\n(.*?)(?=^  [a-z][a-z-]+:\n|\Z)", workflow, re.MULTILINE | re.DOTALL))
        self.assertIn("needs: [repository-hygiene, ios-scope]", jobs["ios-portability"])
        self.assertIn("if: needs.ios-scope.outputs.required == 'true'", jobs["ios-portability"])
        self.assertIn("fetch-depth: 0", jobs["ios-scope"])
        self.assertIn('if [[ "$EVENT_NAME" != "pull_request" ]]; then\n            echo "required=true"', jobs["ios-scope"])
        self.assertIn('scripts/ios_portability_scope.py --base "$BASE_SHA" --head "$HEAD_SHA"', jobs["ios-scope"])
        for name in ("build-and-test", "lint", "repository-hygiene"):
            self.assertNotIn("ios-scope", jobs[name])


if __name__ == "__main__":
    unittest.main()
