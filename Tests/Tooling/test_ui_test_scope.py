import sys
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))

from ui_test_scope import ALL_TESTS, HARNESS_TESTS, select_paths, validate_catalog  # noqa: E402


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

    def test_catalog_covers_every_declared_ui_test(self):
        validate_catalog(ROOT)


if __name__ == "__main__":
    unittest.main()
