import contextlib
import importlib.util
import io
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("swift_test_scope", ROOT / "scripts/swift_test_scope.py")
scope = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(scope)

REPOSITORY_PATH = re.compile(
    r'"(docs|site|scripts|\.github|Tests/Tooling|README|CHANGELOG|AGENTS|CONTRIBUTING|Makefile|project\.yml)[/."]')


class SwiftTestScopeTests(unittest.TestCase):
    def test_documentation_site_and_tooling_diffs_select_only_checkout_readers(self):
        for changed in (["docs/GAPS.md"], ["README.md", "site/index.html"],
                        ["Tests/Tooling/test_ci_workflow.py", "docs/specs/08-quality.md"], ["LICENSE"]):
            with self.subTest(changed=changed):
                selected = scope.selection(ROOT, changed)
                self.assertTrue(selected.startswith(r"^PortavozTests\.("))
                for name in ("ArchitectureDependencyTests", "EnglishSourceTests", "LocalizationTests"):
                    self.assertIn(name, selected)
                self.assertNotIn("WaveformTests", selected)

    def test_anything_that_can_change_the_build_or_runner_selects_everything(self):
        for changed in (["Sources/StorageKit/MeetingStore.swift"], ["Tests/PortavozTests/StorageTests.swift"],
                        ["Package.resolved"], ["scripts/run-swift-tests.sh"], ["scripts/run_xctest_pool.py"],
                        [".github/workflows/ci.yml"], ["Resources/Localization/Portavoz/Localizable.xcstrings"],
                        ["Fixtures/AskQuality/corpus.json"], ["docs/a.md", "Makefile"], ["Sources/README.md"], []):
            with self.subTest(changed=changed):
                self.assertEqual(scope.selection(ROOT, changed), "")

    def test_every_class_that_names_a_repository_path_is_selected(self):
        selected = set(scope.reading_classes(ROOT))
        for source in (ROOT / scope.TESTS).rglob("*.swift"):
            text = source.read_text(encoding="utf-8")
            if REPOSITORY_PATH.search(text):
                names = {name for name in scope.DECLARATION.findall(text) if name.endswith("Tests")}
                with self.subTest(source=source.name):
                    self.assertLessEqual(names, selected)

    def test_a_tree_without_checkout_readers_fails_instead_of_selecting_nothing(self):
        with tempfile.TemporaryDirectory() as directory:
            (Path(directory) / scope.TESTS).mkdir(parents=True)
            (Path(directory) / scope.TESTS / "PlainTests.swift").write_text("final class PlainTests {}\n")
            with self.assertRaises(ValueError):
                scope.selection(Path(directory), ["docs/a.md"])

    def test_cli_fails_closed_to_the_complete_suite(self):
        output, errors = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(output), contextlib.redirect_stderr(errors):
            self.assertEqual(scope.main(["--base", "0" * 40, "--head", "f" * 40]), 0)
        self.assertEqual(output.getvalue(), "filter=\n")
        self.assertIn("failed closed", errors.getvalue())

    def test_renames_report_both_sides(self):
        directory = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, directory, True)

        def git(*arguments):
            return subprocess.run(["git", *arguments], cwd=directory, check=True,
                                  capture_output=True, text=True).stdout
        git("init", "-q", "-b", "main")
        git("config", "user.email", "fixture@example.invalid")
        git("config", "user.name", "Fixture")
        (directory / "Sources").mkdir()
        (directory / "Sources/Note.md").write_text("note\n" * 20)
        git("add", "-A")
        git("commit", "-q", "-m", "base")
        base = git("rev-parse", "HEAD").strip()
        (directory / "docs").mkdir()
        git("mv", "Sources/Note.md", "docs/Note.md")
        git("commit", "-q", "-m", "move")
        self.assertEqual(sorted(scope.changed_files(directory, base, "HEAD")), ["Sources/Note.md", "docs/Note.md"])


if __name__ == "__main__":
    unittest.main()
