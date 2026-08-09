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

    def test_database_launch_recovery_selects_failure_and_normal_shell_evidence(self):
        recovery = FEATURE_TESTS["launch-recovery"]
        for path in (
            "Sources/portavoz-app/AppLaunchModel.swift",
            "Sources/portavoz-app/AppLaunchRecoveryView.swift",
            "Sources/portavoz-app/AppServices.swift",
            "Sources/portavoz-app/PortavozApp.swift",
        ):
            selection = select_paths([path])
            self.assertTrue(set(recovery).issubset(selection.tests), path)
            self.assertTrue(
                set(FEATURE_TESTS["main-shell"]).issubset(selection.tests),
                path,
            )
        storage = select_paths(
            ["Sources/StorageKit/MeetingStore+LaunchRecovery.swift"]
        )
        self.assertEqual(storage.tests, recovery)

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
        for path in (
            "Sources/portavoz-app/MeetingPlayerBar.swift",
            "Sources/portavoz-app/MeetingDetailPlayerSection.swift",
        ):
            selection = select_paths([path])
            self.assertEqual(selection.locales, ("en",), path)
            self.assertEqual(selection.tests, FEATURE_TESTS["meeting-audio"], path)
            self.assertTrue(
                all("MeetingDetailUITests" in test for test in selection.tests),
                path,
            )

    def test_detail_secondary_sections_select_only_owned_journeys(self):
        expected = {
            "Sources/portavoz-app/MeetingDetailActionSection.swift": (
                "meeting-export",
                "meeting-processing",
                "meeting-recap",
            ),
            "Sources/portavoz-app/MeetingDetailRailSection.swift": (
                "meeting-correction",
                "meeting-evidence",
                "meeting-health",
                "meeting-processing",
            ),
            "Sources/portavoz-app/MeetingDetailFlowState.swift": (
                "meeting-export",
                "meeting-naming",
                "meeting-processing",
                "meeting-recap",
                "meeting-summary",
            ),
        }
        for path, features in expected.items():
            selection = select_paths([path])
            owned_tests = {
                test
                for feature in features
                for test in FEATURE_TESTS[feature]
            }
            self.assertEqual(selection.locales, ("en",), path)
            self.assertEqual(set(selection.tests), owned_tests, path)

    def test_detail_composition_files_select_only_their_owned_journeys(self):
        expected = {
            "Sources/portavoz-app/MeetingDetailCoordinator+Identity.swift": (
                "meeting-naming",
            ),
            "Sources/portavoz-app/MeetingDetailCoordinator+Documents.swift": (
                "meeting-correction",
                "meeting-evidence",
                "meeting-export",
                "meeting-processing",
                "meeting-recap",
                "meeting-summary",
            ),
            "Sources/portavoz-app/MeetingDetailCoordinator+Commitments.swift": (
                "meeting-commitments",
            ),
            "Sources/portavoz-app/MeetingDetailCoordinator.swift": (
                "meeting-audio",
                "meeting-evidence",
                "meeting-processing",
            ),
            "Sources/portavoz-app/MeetingDetailFlowHost.swift": (
                "meeting-export",
                "meeting-health",
                "meeting-naming",
                "meeting-processing",
                "meeting-recap",
                "meeting-summary",
            ),
            "Sources/portavoz-app/MeetingDetailNotesSection.swift": (
                "meeting-summary",
            ),
            "Sources/portavoz-app/MeetingDetailRefineReviewSheet.swift": (
                "meeting-processing",
            ),
            "Sources/portavoz-app/MeetingCommitmentInboxSection.swift": (
                "meeting-commitments",
            ),
            "Sources/portavoz-app/MeetingDetailPlaybackNavigation.swift": (
                "meeting-audio",
                "meeting-evidence",
                "meeting-performance",
            ),
        }
        for path, features in expected.items():
            selection = select_paths([path])
            owned_tests = {
                test
                for feature in features
                for test in FEATURE_TESTS[feature]
            }
            self.assertEqual(selection.locales, ("en",), path)
            self.assertEqual(set(selection.tests), owned_tests, path)

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
            + FEATURE_TESTS["meeting-correction"]
            + FEATURE_TESTS["meeting-evidence"]
            + FEATURE_TESTS["meeting-performance"]
        )
        expected = tuple(test for test in ALL_TESTS if test in selected)
        self.assertEqual(selection.tests, expected)
        self.assertEqual(selection.locales, ("en",))

    def test_meeting_detail_scene_and_presentation_select_all_detail_journeys(self):
        self.assertNotIn("meeting-brief", MEETING_FEATURES)
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
            self.assertNotIn(
                FEATURE_TESTS["meeting-brief"][0],
                selection.tests,
                path,
            )

    def test_meeting_detail_sections_select_only_owned_journeys(self):
        expected_features = {
            "Sources/portavoz-app/MeetingDetailHeaderSection.swift": {
                "meeting-export", "meeting-naming", "meeting-processing"
            },
            "Sources/portavoz-app/MeetingGeneratedDocumentSection.swift": {
                "meeting-correction", "meeting-evidence", "meeting-summary"
            },
            "Sources/portavoz-app/MeetingDetailTrustSection.swift": {
                "meeting-health", "meeting-processing", "meeting-skills"
            },
            "Sources/portavoz-app/MeetingTranscriptSection.swift": {
                "meeting-audio", "meeting-correction", "meeting-evidence",
                "meeting-health", "meeting-performance"
            },
            "Sources/ApplicationKit/MeetingGeneratedDocumentPresentation.swift": {
                "meeting-evidence", "meeting-summary"
            },
            "Sources/ApplicationKit/MeetingTranscriptContent.swift": {
                "meeting-audio", "meeting-evidence", "meeting-health", "meeting-performance"
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

    def test_composed_transcript_policy_selects_only_correction_journey(self):
        selection = select_paths(["Sources/ApplicationKit/ComposeTranscript.swift"])
        self.assertEqual(selection.tests, FEATURE_TESTS["meeting-correction"])
        self.assertEqual(selection.locales, ("en",))

        future_consumer = select_paths(["Sources/StorageKit/ComposeTranscriptStore.swift"])
        self.assertTrue(future_consumer.required)
        self.assertEqual(future_consumer.tests, ALL_TESTS)

    def test_durable_correction_storage_selects_only_correction_journey(self):
        expected = FEATURE_TESTS["meeting-correction"]
        for path in [
            "Sources/PortavozCore/TranscriptCorrection.swift",
            "Sources/PortavozCore/TranscriptCorrectionRevision.swift",
            "Sources/ApplicationKit/MeetingTranscriptGenerationMaterial.swift",
            "Sources/StorageKit/MeetingStore+TranscriptCorrections.swift",
            "Sources/StorageKit/MeetingStore+TranscriptProjection.swift",
            "Sources/StorageKit/Schema+TranscriptCorrection.swift",
            "Sources/StorageKit/TranscriptCorrectionRecords.swift",
        ]:
            selection = select_paths([path])
            self.assertEqual(selection.tests, expected, path)
            self.assertEqual(selection.locales, ("en",), path)

    def test_commitment_admission_selects_only_the_confirmation_journey(self):
        expected = FEATURE_TESTS["meeting-commitments"]
        for path in [
            "Sources/ApplicationKit/ManageMeetingCommitmentInbox.swift",
            "Sources/ApplicationKit/MeetingCommitmentInbox.swift",
        ]:
            selection = select_paths([path])
            self.assertEqual(selection.tests, expected, path)
            self.assertEqual(selection.locales, ("en",), path)

    def test_commitment_radar_selects_only_its_global_continuity_journey(self):
        expected = FEATURE_TESTS["commitment-radar"]
        for path in [
            "Sources/PortavozCore/CommitmentRadar.swift",
            "Sources/ApplicationKit/LoadCommitmentRadar.swift",
            "Sources/ApplicationKit/ManageCommitmentRadar.swift",
            "Sources/StorageKit/MeetingStore+CommitmentRadar.swift",
            "Sources/portavoz-app/AppServices+CommitmentRadar.swift",
            "Sources/portavoz-app/CommitmentRadarModel.swift",
            "Sources/portavoz-app/CommitmentRadarView.swift",
        ]:
            selection = select_paths([path])
            self.assertEqual(selection.tests, expected, path)
            self.assertEqual(selection.locales, ("en",), path)

    def test_content_composition_selects_one_canary_per_root_route(self):
        selection = select_paths(["Sources/portavoz-app/ContentView.swift"])
        self.assertEqual(set(selection.tests), set(FEATURE_TESTS["main-shell"]))
        self.assertEqual(selection.locales, ("en",))
        self.assertLess(len(selection.tests), len(ALL_TESTS))

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

    def test_skill_sources_select_the_control_and_proposal_journeys(self):
        expected_set = set(
            FEATURE_TESTS["meeting-skills"]
            + FEATURE_TESTS["menu-bar-brief"]
            + FEATURE_TESTS["settings-skills"])
        expected = tuple(test for test in ALL_TESTS if test in expected_set)
        for path in [
            "Sources/PortavozCore/SkillExecutionPolicy.swift",
            "Sources/ApplicationKit/SkillsControlCenter.swift",
            "Sources/StorageKit/MeetingStore+SkillControl.swift",
            "Sources/portavoz-app/AppServices+MeetingSkills.swift",
            "Sources/portavoz-app/SkillsSettingsSection.swift",
        ]:
            selection = select_paths([path])
            self.assertEqual(selection.tests, expected, path)
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
