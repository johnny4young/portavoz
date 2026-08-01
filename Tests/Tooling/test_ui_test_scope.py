import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))

from ui_test_scope import (  # noqa: E402
    ALL_TESTS,
    FEATURE_TESTS,
    HARNESS_TESTS,
    MEETING_FEATURES,
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
        self.assertEqual(selection.tests, FEATURE_TESTS["meeting-audio"])
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

    def test_recording_use_cases_skip_unrelated_settings_surfaces(self):
        for path in (
            "Sources/ApplicationKit/StartRecording.swift",
            "Sources/ApplicationKit/StopRecording.swift",
        ):
            selection = select_paths([path])
            self.assertEqual(
                selection.tests,
                tuple(dict.fromkeys(
                    FEATURE_TESTS["library"]
                    + FEATURE_TESTS["recording-recovery"]
                )),
                path,
            )

    def test_mic_bleed_selects_live_and_refine_evidence_without_full_fallback(self):
        selection = select_paths(["Sources/TranscriptionKit/MicBleedFilter.swift"])
        self.assertEqual(
            selection.tests,
            tuple(dict.fromkeys(
                FEATURE_TESTS["recording-recovery"]
                + FEATURE_TESTS["meeting-processing"]
            )),
        )
        self.assertLess(len(selection.tests), len(ALL_TESTS))

    def test_query_expander_selects_only_search_consumers(self):
        selection = select_paths(
            ["Sources/ApplicationKit/BilingualSearchQueryExpander.swift"]
        )
        expected = tuple(dict.fromkeys(
            FEATURE_TESTS["library"]
            + FEATURE_TESTS["meeting-brief"]
            + FEATURE_TESTS["ask"]
        ))
        self.assertEqual(selection.tests, expected)
        self.assertEqual(selection.locales, ("en",))
        self.assertLess(len(selection.tests), len(ALL_TESTS))

    def test_summary_storage_selects_its_consumers_without_full_fallback(self):
        selection = select_paths(["Sources/StorageKit/MeetingStore+Summaries.swift"])
        self.assertIn(
            "PortavozUITests/MeetingDetailUITests/testMostRecentRecipeRemainsVisibleAfterReload",
            selection.tests,
        )
        self.assertIn(
            "PortavozUITests/LibraryUITests/testSeededMeetingsGroupByRecency",
            selection.tests,
        )
        self.assertLess(len(selection.tests), len(ALL_TESTS))

    def test_legacy_scroll_bridge_selects_only_recording_recovery_evidence(self):
        selection = select_paths(
            ["Sources/portavoz-app/LegacyScrollInteractionTracker.swift"]
        )
        self.assertEqual(selection.tests, FEATURE_TESTS["recording-recovery"])
        self.assertEqual(selection.locales, ("en",))

    def test_detail_performance_harness_selects_only_scale_journeys(self):
        for path in (
            "Sources/portavoz-app/MeetingDetailPerformanceTrace.swift",
            "Sources/portavoz-app/AppServices+ScaleBenchmark.swift",
        ):
            selection = select_paths([path])
            self.assertEqual(selection.tests, FEATURE_TESTS["meeting-performance"])
            self.assertEqual(selection.locales, ("en",))

    def test_transcript_view_selects_navigation_audio_and_scale_evidence(self):
        selection = select_paths(
            ["Sources/portavoz-app/TranscriptSegmentsView.swift"]
        )
        selected = set(
            FEATURE_TESTS["meeting-audio"]
            + FEATURE_TESTS["meeting-evidence"]
            + FEATURE_TESTS["meeting-performance"]
        )
        expected = tuple(test for test in ALL_TESTS if test in selected)
        self.assertEqual(selection.tests, expected)
        self.assertEqual(selection.locales, ("en",))

    def test_meeting_detail_scene_and_presentation_select_all_detail_journeys(self):
        for path in [
            "Sources/portavoz-app/MeetingDetailScene.swift",
            "Sources/portavoz-app/MeetingDetailPresentation.swift",
        ]:
            selection = select_paths([path])
            expected = tuple(
                test for test in ALL_TESTS
                if test in {
                    item
                    for feature in MEETING_FEATURES
                    for item in FEATURE_TESTS[feature]
                }
            )
            self.assertEqual(selection.tests, expected, path)
            self.assertEqual(selection.locales, ("en",), path)

    def test_meeting_detail_sections_select_only_owned_journeys(self):
        expected_features = {
            "Sources/portavoz-app/MeetingDetailHeaderSection.swift": {
                "meeting-export", "meeting-naming", "meeting-processing"
            },
            "Sources/portavoz-app/MeetingGeneratedDocumentSection.swift": {
                "meeting-evidence", "meeting-summary"
            },
            "Sources/portavoz-app/MeetingDetailTrustSection.swift": {
                "meeting-health", "meeting-processing"
            },
            "Sources/ApplicationKit/MeetingGeneratedDocumentPresentation.swift": {
                "meeting-evidence", "meeting-summary"
            },
        }
        for path, features in expected_features.items():
            selection = select_paths([path])
            selected = {
                test
                for feature in features
                for test in FEATURE_TESTS[feature]
            }
            expected = tuple(test for test in ALL_TESTS if test in selected)
            self.assertEqual(selection.tests, expected, path)
            self.assertEqual(selection.locales, ("en",), path)

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

    def test_dictation_surfaces_select_only_the_audio_pane_evidence(self):
        for path in [
            "Sources/portavoz-app/DictationSection.swift",
            "Sources/portavoz-app/MouseButtonPTT.swift",
            "Sources/portavoz-app/MousePTTGesture.swift",
            "Sources/portavoz-app/DictationController.swift",
            "Sources/TranscriptionKit/DictationTextRules.swift",
        ]:
            selection = select_paths([path])
            self.assertEqual(
                selection.tests,
                (
                    "PortavozUITests/SettingsUITests/"
                    "testAudioPaneOffersCaptureSourceControls",
                    "PortavozUITests/SettingsUITests/"
                    "testDictationOffersTriggersLanguageAndDictionary",
                ),
                path,
            )
            self.assertEqual(selection.locales, ("en",), path)

    def test_harness_change_selects_three_bilingual_canaries(self):
        selection = select_paths(["Makefile"])
        self.assertEqual(selection.tests, HARNESS_TESTS)
        self.assertEqual(selection.locales, ("en", "es"))

    def test_app_intents_selects_only_the_external_recording_handoff(self):
        selection = select_paths(
            ["Sources/portavoz-app/PortavozAppIntents.swift"]
        )
        self.assertEqual(
            selection.tests,
            FEATURE_TESTS["automation-entry"],
        )
        self.assertEqual(selection.locales, ("en",))

    def test_recording_toolbar_selects_geometry_and_live_control_contracts(self):
        selection = select_paths(
            ["Sources/portavoz-app/RecordingToolbar.swift"]
        )
        self.assertEqual(
            selection.tests,
            tuple(dict.fromkeys(
                FEATURE_TESTS["automation-entry"]
                + FEATURE_TESTS["recording-recovery"]
            )),
        )
        self.assertEqual(selection.locales, ("en",))

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
