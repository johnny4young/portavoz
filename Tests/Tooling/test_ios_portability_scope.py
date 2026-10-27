import contextlib
import importlib.util
import io
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys
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
COMMENTED_TARGETS = """
        // A comment with ] and "quotes" and .target( never ends the list.
        .target(name: "PortavozCore", path: "Sources/Core"),
        .target(
            name: "StorageKit",
            dependencies: [
                "PortavozCore", // inline ] comment
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            resources: [.copy("Resources/a]b.json")]),
"""


class IOSPortabilityScopeTests(unittest.TestCase):
    def manifest(self, targets: str) -> Path:
        directory = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, directory, True)
        (directory / "scripts").mkdir()
        (directory / scope.RUNNER).write_text("targets=(StorageKit)\n")
        (directory / "Package.swift").write_text(
            "// swift-tools-version:6.2\nimport PackageDescription\n"
            "let package = Package(\n    name: \"X\",\n"
            "    products: [.library(name: \"X\", targets: [\"StorageKit\"])],\n"
            f"    targets: [\n{targets}\n    ]\n)\n")
        return directory

    def test_closure_follows_the_runner_targets_through_the_manifest(self):
        self.assertEqual(scope.roots(ROOT), ["PortavozCore", "StorageKit", "ApplicationKit", "IntegrationsKit"])
        self.assertEqual(scope.closure(ROOT), SHARED)
        graph = scope.targets(ROOT)
        self.assertEqual(graph["PortavozCLIKit"][1], "Sources/portavoz-cli")
        self.assertNotIn("FluidAudio", graph["TranscriptionKit"][0])

    @unittest.skipUnless(sys.platform == "darwin" and shutil.which("swift"), "needs the manifest evaluator")
    def test_closure_matches_swiftpm_manifest_evaluation(self):
        package = json.loads(subprocess.check_output(["swift", "package", "dump-package"], cwd=ROOT, timeout=120))
        graph = {}
        for target in package["targets"]:
            local = [entry[kind][0] for entry in target.get("dependencies", [])
                     for kind in ("byName", "target") if kind in entry]
            graph[target["name"]] = (local, target.get("path") or f"Sources/{target['name']}")
        self.assertEqual({name: value[0] for name, value in scope.targets(ROOT).items()},
                         {name: value[0] for name, value in graph.items()})
        pending, seen = scope.roots(ROOT), set()
        while pending:
            name = pending.pop()
            if name not in seen:
                seen.add(name)
                pending.extend(graph[name][0])
        self.assertEqual(scope.closure(ROOT), sorted(graph[name][1] for name in seen))

    def test_comments_strings_and_products_do_not_hide_local_edges(self):
        self.assertEqual(scope.closure(self.manifest(COMMENTED_TARGETS)), ["Sources/Core", "Sources/StorageKit"])

    def test_unprovable_dependency_forms_fail_instead_of_shrinking_the_scope(self):
        for dependency in ('.target(name: "PortavozCore")', '.byName(name: "PortavozCore")',
                           '.target(name: "PortavozCore", condition: .when(platforms: [.iOS]))'):
            root = self.manifest(
                '.target(name: "PortavozCore"),\n'
                f'.target(name: "StorageKit", dependencies: [{dependency}, "Other"]),\n'
                '.target(name: "Other"),')
            with self.subTest(dependency=dependency), self.assertRaises(ValueError):
                scope.closure(root)
        for broken in ('.target(name: "StorageKit", dependencies: ["PortavozCore"]',
                       'targetFactory("StorageKit")'):
            with self.subTest(broken=broken), self.assertRaises(ValueError):
                scope.closure(self.manifest(broken))

    def test_a_file_moved_out_of_a_shared_target_requires_the_lane(self):
        directory = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, directory, True)

        def git(*arguments):
            return subprocess.run(["git", *arguments], cwd=directory, check=True,
                                  capture_output=True, text=True).stdout
        git("init", "-q", "-b", "main")
        git("config", "user.email", "fixture@example.invalid")
        git("config", "user.name", "Fixture")
        (directory / "Sources/StorageKit").mkdir(parents=True)
        (directory / "Sources/StorageKit/Moved.swift").write_text("struct Moved { let value = 1 }\n" * 20)
        git("add", "-A")
        git("commit", "-q", "-m", "base")
        base = git("rev-parse", "HEAD").strip()
        (directory / "Sources/portavoz-app").mkdir(parents=True)
        git("mv", "Sources/StorageKit/Moved.swift", "Sources/portavoz-app/Moved.swift")
        git("commit", "-q", "-m", "move")
        changed = scope.changed_files(directory, base, "HEAD")
        self.assertIn("Sources/StorageKit/Moved.swift", changed)
        self.assertTrue(scope.required(ROOT, changed))

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
                        ["scripts/verify-ci-toolchain.sh"], [".github/workflows/ci.yml"],
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
        jobs = dict(re.findall(r"^  ([a-z][a-z-]+):\n(.*?)(?=^  [a-z][a-z-]+:\n|\Z)",
                               workflow, re.MULTILINE | re.DOTALL))
        self.assertIn("needs: [repository-hygiene, ios-scope]", jobs["ios-portability"])
        self.assertIn("!cancelled() && needs.repository-hygiene.result == 'success' &&\n"
                      "      (github.event_name != 'pull_request' || needs.ios-scope.outputs.required == 'true')",
                      jobs["ios-portability"])
        self.assertIn("if: github.event_name == 'pull_request'", jobs["ios-scope"])
        self.assertIn("fetch-depth: 0", jobs["ios-scope"])
        self.assertIn('run: python3 scripts/ios_portability_scope.py --base "$BASE_SHA" --head "$HEAD_SHA"',
                      jobs["ios-scope"])
        for name in ("build-and-test", "lint", "repository-hygiene"):
            self.assertNotIn("ios-scope", jobs[name])


if __name__ == "__main__":
    unittest.main()
