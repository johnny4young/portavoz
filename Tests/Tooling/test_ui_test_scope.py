import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))

from ui_test_scope import (  # noqa: E402
    ALL_TESTS,
    HARNESS_TESTS,
    select_paths,
    validate_catalog,
    working_tree_paths,
)


class UITestScopeTests(unittest.TestCase):
    def test_empty_change_set_requires_no_ui_runner(self):
        self.assertFalse(select_paths([]).required)

    def test_docs_governance_and_local_tooling_do_not_spend_a_ui_runner(self):
        selection = select_paths(
            [
                "README.md",
                "docs/ARCHITECTURE.md",
                ".github/dependabot.yml",
                ".design-sync/config.json",
                "Tests/Tooling/test_ui_test_scope.py",
            ]
        )
        self.assertFalse(selection.required)

    def test_audio_view_selects_only_audio_detail_evidence(self):
        selection = select_paths(["Sources/portavoz-app/MeetingPlayerBar.swift"])
        self.assertEqual(selection.locales, ("en",))
        self.assertEqual(len(selection.tests), 3)
        self.assertTrue(all("MeetingDetailUITests" in test for test in selection.tests))

    def test_localization_selects_bilingual_canaries_at_the_real_catalog_path(self):
        selection = select_paths(["Resources/Localization/Portavoz/Localizable.xcstrings"])
        self.assertEqual(selection.tests, HARNESS_TESTS)
        self.assertEqual(selection.locales, ("en", "es"))

    def test_recording_sources_select_callback_recovery_evidence(self):
        selection = select_paths(["Sources/AudioCaptureKit/RecordingSession.swift"])
        self.assertIn(
            "PortavozUITests/LibraryUITests/testRecordingWarnsWhenRemoteAudioCallbacksStop",
            selection.tests,
        )

    def test_subtitle_export_selects_only_its_meeting_export_smoke(self):
        selection = select_paths(["Sources/IntegrationsKit/SubtitleExport.swift"])
        self.assertEqual(
            selection.tests,
            (
                "PortavozUITests/MeetingDetailUITests/"
                "testExportMenuOffersSubtitleFormats",
            ),
        )
        self.assertEqual(selection.locales, ("en",))

    def test_harness_change_selects_two_bilingual_canaries(self):
        selection = select_paths(["Makefile"])
        self.assertEqual(selection.tests, HARNESS_TESTS)
        self.assertEqual(selection.locales, ("en", "es"))

    def test_changed_ui_test_file_selects_only_its_class(self):
        selection = select_paths(["Tests/PortavozUITests/InsightsUITests.swift"])
        self.assertEqual(len(selection.tests), 2)
        self.assertTrue(all("InsightsUITests" in test for test in selection.tests))

    def test_unknown_production_source_falls_back_to_full_english(self):
        selection = select_paths(["Sources/NewCapabilityKit/Unknown.swift"])
        self.assertEqual(selection.tests, ALL_TESTS)
        self.assertEqual(selection.locales, ("en",))

    def test_working_tree_paths_keeps_staged_change_hidden_from_worktree_diff(self):
        with tempfile.TemporaryDirectory() as directory:
            repository = Path(directory)
            path = repository / "Sources/portavoz-app/RecordingView.swift"
            path.parent.mkdir(parents=True)
            subprocess.run(["git", "init", "-q"], cwd=repository, check=True)
            subprocess.run(
                ["git", "config", "user.email", "ui-scope@example.invalid"],
                cwd=repository,
                check=True,
            )
            subprocess.run(
                ["git", "config", "user.name", "UI Scope Test"],
                cwd=repository,
                check=True,
            )
            path.write_text("base\n", encoding="utf-8")
            subprocess.run(["git", "add", "."], cwd=repository, check=True)
            subprocess.run(["git", "commit", "-qm", "base"], cwd=repository, check=True)

            path.write_text("staged\n", encoding="utf-8")
            subprocess.run(["git", "add", str(path)], cwd=repository, check=True)
            subprocess.run(
                ["git", "restore", "--worktree", "--source=HEAD", "--", str(path)],
                cwd=repository,
                check=True,
            )

            self.assertEqual(
                working_tree_paths("HEAD", cwd=repository),
                ["Sources/portavoz-app/RecordingView.swift"],
            )

    def test_catalog_covers_every_declared_ui_test(self):
        validate_catalog(ROOT)


if __name__ == "__main__":
    unittest.main()
