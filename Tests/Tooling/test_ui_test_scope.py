import hashlib
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))

import ui_test_scope as ui_scope  # noqa: E402
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
    def minimal_catalog_root(self, *methods: str, with_owner: bool = True):
        temporary = tempfile.TemporaryDirectory()
        root = Path(temporary.name)
        tests = root / "Tests" / "PortavozUITests"
        tests.mkdir(parents=True)
        declarations = "\n".join(f"    func {method}() {{}}" for method in methods)
        (tests / "InsightsUITests.swift").write_text(
            "final class InsightsUITests: PortavozUITestCase {\n"
            f"{declarations}\n"
            "}\n",
            encoding="utf-8",
        )
        if with_owner:
            owner = root / "Sources" / "portavoz-app" / "InsightsView.swift"
            owner.parent.mkdir(parents=True)
            owner.write_text("// production owner\n", encoding="utf-8")
        return temporary, root

    def test_empty_change_set_requires_no_ui_runner(self):
        self.assertFalse(select_paths([]).required)

    def test_github_summary_is_bounded_without_weakening_selected_evidence(self):
        reasons = tuple(
            f"Sources/Feature{index}.swift: " + ("mapped-impact " * 80).strip()
            for index in range(200)
        )
        selection = ui_scope.Selection(
            tests=ui_scope.ALL_TESTS,
            locales=("en", "es"),
            reasons=reasons,
        )

        rendered = ui_scope.render(selection, "github")
        outputs = dict(line.split("=", 1) for line in rendered.splitlines())

        self.assertEqual(outputs["required"], "true")
        self.assertEqual(outputs["tests"].split(), list(ui_scope.ALL_TESTS))
        self.assertEqual(outputs["locales"], "en es")
        self.assertLessEqual(
            len(outputs["summary"].encode("utf-8")),
            ui_scope.MAX_SUMMARY_BYTES,
        )
        self.assertIn("additional reasons omitted", outputs["summary"])
        full_summary = "; ".join(reasons)
        digest = hashlib.sha256(full_summary.encode("utf-8")).hexdigest()
        self.assertTrue(outputs["summary"].endswith(f"full-summary-sha256={digest}"))
        kept_summary = outputs["summary"].split("; ... ", 1)[0]
        self.assertTrue(
            all(reason in reasons for reason in kept_summary.split("; "))
        )

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

    def test_resource_benchmark_owners_select_startup_canaries(self):
        expected = set(FEATURE_TESTS["launch-recovery"])
        expected.update(FEATURE_TESTS["main-shell"])
        for path in (
            "Sources/portavoz-app/BenchMode.swift",
            "Sources/portavoz-app/BenchMode+ResourceRefinePreparation.swift",
            "Sources/portavoz-app/BenchResourceLaunchProbe.swift",
            "Sources/portavoz-app/BenchResourceProcessWatchdog.swift",
            "Sources/portavoz-app/BenchResourceScenarioProbe.swift",
        ):
            selection = select_paths([path])
            self.assertEqual(selection.locales, ("en",), path)
            self.assertEqual(set(selection.tests), expected, path)
            self.assertLess(len(selection.tests), len(ALL_TESTS), path)

    def test_production_sync_stage_owners_select_only_the_sync_settings_journey(self):
        expected = FEATURE_TESTS["production-sync"]
        for path in (
            "Sources/portavoz-app/ProductionSyncQualificationCorpus.swift",
            "Sources/portavoz-app/ProductionSyncQualificationEvidence.swift",
            "Sources/portavoz-app/ProductionSyncQualificationProcess.swift",
            "Sources/portavoz-app/ProductionSyncQualificationRunner.swift",
        ):
            selection = select_paths([path])
            self.assertEqual(selection.locales, ("en",), path)
            self.assertEqual(selection.tests, expected, path)
            self.assertEqual(len(selection.tests), 1, path)
            self.assertLess(len(selection.tests), len(ALL_TESTS), path)

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
                "meeting-correction",
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
                "meeting-correction",
                "meeting-evidence",
                "meeting-processing",
            ),
            "Sources/portavoz-app/MeetingDetailFlowHost.swift": (
                "meeting-correction",
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

    def test_localization_expands_to_the_complete_bilingual_catalog(self):
        selection = select_paths(["Resources/Localization/Portavoz/Localizable.xcstrings"])
        self.assertEqual(selection.tests, HARNESS_TESTS)
        self.assertEqual(selection.locales, ("en", "es"))

    def test_feature_handshake_support_selects_only_ask_and_skills(self):
        expected = set(FEATURE_TESTS["ask"])
        expected.update(FEATURE_TESTS["settings-skills"])
        for path in (
            "Sources/portavoz-app/UITestFeatureHandshake.swift",
            "Tests/PortavozUITests/FeatureUITestHandshakeSupport.swift",
        ):
            selection = select_paths([path])
            self.assertEqual(set(selection.tests), expected, path)
            self.assertEqual(selection.locales, ("en",), path)
            self.assertLess(len(selection.tests), len(ALL_TESTS), path)

    def test_pr_scope_advances_only_from_verified_ancestor_artifacts(self):
        workflow = (ROOT / ".github/workflows/ui-tests.yml").read_text(
            encoding="utf-8"
        )

        self.assertNotIn("PREVIOUS_HEAD_SHA", workflow)
        self.assertNotIn("github.event.before", workflow)
        self.assertIn("actions: read", workflow)
        self.assertIn("scripts/ui_test_verified_base.py", workflow)
        self.assertIn('--base "$VERIFIED_BASE_SHA"', workflow)
        self.assertIn("github.run_attempt == 1", workflow)
        self.assertIn("ui-verification-${{", workflow)
        self.assertIn("retention-days: 90", workflow)
        self.assertIn(
            "python3 scripts/ui_test_scope.py --all --format github",
            workflow,
        )

    def test_hosted_ui_builds_once_runs_both_locales_and_gates_after_artifacts(self):
        workflow = (ROOT / ".github/workflows/ui-tests.yml").read_text(
            encoding="utf-8"
        )

        self.assertEqual(workflow.count("run: make test-ui-build"), 1)
        self.assertEqual(workflow.count("run: make test-ui-run"), 2)
        self.assertEqual(workflow.count("continue-on-error: true"), 2)
        self.assertEqual(
            workflow.count('UI_TEST_ENFORCE_RUNTIME_BUDGET: "false"'),
            2,
        )
        self.assertIn("id: ui_en", workflow)
        self.assertIn("id: ui_es", workflow)
        self.assertIn("ENGLISH_OUTCOME: ${{ steps.ui_en.outcome }}", workflow)
        self.assertIn("SPANISH_OUTCOME: ${{ steps.ui_es.outcome }}", workflow)
        self.assertIn("runs-on: macos-26", workflow)
        self.assertIn("Xcode_26.6.app/Contents/Developer", workflow)
        self.assertIn("scripts/install-ci-xcodegen.sh", workflow)
        self.assertNotIn("brew install xcodegen", workflow)
        artifact = workflow.index("Preserve scoped UI evidence")
        gate = workflow.index("Classify functional evidence and hosted runtime drift")
        self.assertLess(artifact, gate)
        self.assertNotIn("run: make test-ui-scoped", workflow)

    def test_ui_scope_does_not_duplicate_repository_tooling_suites(self):
        workflow = (ROOT / ".github/workflows/ui-tests.yml").read_text(
            encoding="utf-8"
        )

        self.assertEqual(
            workflow.count("scripts/ui_test_scope.py --validate-catalog"),
            1,
        )
        self.assertNotIn("python3 -m unittest Tests.Tooling", workflow)

    def test_semantic_asset_preparation_selects_its_settings_journey(self):
        expected = FEATURE_TESTS["settings-intelligence"]
        for path in (
            "Sources/ApplicationKit/SemanticSearchAssetPreparation.swift",
            "Sources/portavoz-app/SemanticSearchPreparationModel.swift",
        ):
            selection = select_paths([path])
            self.assertEqual(selection.tests, expected, path)
            self.assertEqual(selection.locales, ("en",), path)

    def test_decision_relationship_sources_select_exact_ask_journeys(self):
        selection = select_paths([
            "Sources/ApplicationKit/LoadDecisionRelationships.swift",
            "Sources/StorageKit/MeetingStore+DecisionRelationshipQuery.swift",
        ])
        self.assertEqual(selection.tests, FEATURE_TESTS["ask"])
        self.assertEqual(selection.locales, ("en",))

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

    def test_typed_note_ask_layers_select_only_the_consolidated_ask_scope(self):
        for path in (
            "Sources/ApplicationKit/AskNotes.swift",
            "Sources/ApplicationKit/LocalAskNoteRetrieval.swift",
            "Sources/StorageKit/Schema+ContextItemSearch.swift",
            "Sources/StorageKit/MeetingStore+NoteSearch.swift",
        ):
            selection = select_paths([path])
            self.assertEqual(selection.tests, FEATURE_TESTS["ask"], path)
            self.assertEqual(selection.locales, ("en",), path)
            self.assertLess(len(selection.tests), len(ALL_TESTS), path)

    def test_shared_cited_answering_selects_ask_and_interview_only(self):
        selected = set(
            FEATURE_TESTS["ask"] + FEATURE_TESTS["recording-interview"]
        )
        expected = tuple(test for test in ALL_TESTS if test in selected)
        for path in (
            "Sources/ApplicationKit/NumberedCitationAnswer.swift",
            "Sources/IntelligenceKit/RAGTextAnswering.swift",
            "Sources/IntelligenceKit/RAGAnswerer.swift",
        ):
            selection = select_paths([path])
            self.assertEqual(selection.tests, expected, path)
            self.assertEqual(selection.locales, ("en",), path)
            self.assertLess(len(selection.tests), len(ALL_TESTS), path)

    def test_proactive_assist_layers_select_only_consolidated_recording_evidence(self):
        expected = FEATURE_TESTS["recording-recovery"]
        for path in (
            "Sources/IntelligenceKit/ProactiveMeetingAssist.swift",
            "Sources/portavoz-app/RecordingProactiveAssistModel.swift",
        ):
            selection = select_paths([path])
            self.assertEqual(selection.tests, expected, path)
            self.assertEqual(selection.locales, ("en",), path)
            self.assertLess(len(selection.tests), len(ALL_TESTS), path)

    def test_confirmed_topic_catalog_selects_only_exact_ask_journeys(self):
        expected = FEATURE_TESTS["ask"]
        for path in (
            "Sources/ApplicationKit/LoadConfirmedTopicCatalog.swift",
            "Sources/StorageKit/MeetingStore+ConfirmedTopicCatalog.swift",
        ):
            selection = select_paths([path])
            self.assertEqual(selection.tests, expected, path)
            self.assertEqual(selection.locales, ("en",), path)
            self.assertLess(len(selection.tests), len(ALL_TESTS), path)

    def test_topic_first_discussion_selects_only_exact_ask_journeys(self):
        expected = FEATURE_TESTS["ask"]
        for path in (
            "Sources/ApplicationKit/LoadTopicFirstDiscussion.swift",
            "Sources/StorageKit/MeetingStore+TopicFirstDiscussionQuery.swift",
        ):
            selection = select_paths([path])
            self.assertEqual(selection.tests, expected, path)
            self.assertEqual(selection.locales, ("en",), path)
            self.assertLess(len(selection.tests), len(ALL_TESTS), path)

    def test_commitment_blocker_query_selects_only_exact_ask_journeys(self):
        selection = select_paths([
            "Sources/ApplicationKit/LoadCommitmentBlockers.swift",
        ])
        self.assertEqual(selection.tests, FEATURE_TESTS["ask"])
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

    def test_companion_refresh_selects_correction_publication_evidence(self):
        expected = {
            "PortavozUITests/MeetingDetailUITests/"
            "testExplicitApuntadorRefreshUsesCorrectedTranscript",
            "PortavozUITests/MeetingDetailUITests/"
            "testSequoiaApuntadorRefreshPreservesStaleAnswers",
        }
        for path in (
            "Sources/ApplicationKit/RegenerateCompanionCards.swift",
            "Sources/StorageKit/MeetingStore+Companion.swift",
            "Sources/portavoz-app/AppServices+CompanionRegeneration.swift",
            "Sources/portavoz-app/CompanionRefresh.swift",
            "Sources/portavoz-app/MeetingDetailCoordinator.swift",
            "Sources/portavoz-app/MeetingDetailFlowState.swift",
        ):
            selection = select_paths([path])
            self.assertTrue(expected.issubset(selection.tests), path)
            self.assertEqual(selection.locales, ("en",), path)
            self.assertLess(len(selection.tests), len(ALL_TESTS), path)

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
            "Sources/portavoz-app/CommitmentRadarView+ReminderDraft.swift",
            "Sources/portavoz-app/ReminderDraftModel.swift",
            "Sources/portavoz-app/ReminderDraftSheet.swift",
            "Sources/portavoz-app/AppReminderDraftEventKitAdapter.swift",
            "Sources/portavoz-app/AppServices+ReminderDraft.swift",
        ]:
            selection = select_paths([path])
            self.assertEqual(selection.tests, expected, path)
            self.assertEqual(selection.locales, ("en",), path)

    def test_content_composition_selects_one_canary_per_root_route(self):
        selection = select_paths(["Sources/portavoz-app/ContentView.swift"])
        expected = set(FEATURE_TESTS["main-shell"])
        expected.update(FEATURE_TESTS["background-work"])
        self.assertEqual(set(selection.tests), expected)
        self.assertEqual(selection.locales, ("en",))
        self.assertLess(len(selection.tests), len(ALL_TESTS))

    def test_background_work_owners_select_only_the_consolidated_journeys(self):
        expected = FEATURE_TESTS["background-work"]
        for path in (
            "Sources/portavoz-app/BackgroundWorkCenterModel.swift",
            "Sources/portavoz-app/BackgroundWorkCenterView.swift",
            "Sources/portavoz-app/PostCaptureProcessingCoordinator.swift",
            "Sources/portavoz-app/RecordingRecoveryCoordinator.swift",
            "Sources/portavoz-app/SemanticCorpusIndexingSupervisor.swift",
            "Sources/portavoz-app/SpotlightIndexer.swift",
            "Sources/ApplicationKit/ProcessSemanticCorpusMaintenance.swift",
            "Sources/ApplicationKit/ProcessMeetingMemoryGraphMaintenance.swift",
            "Sources/ApplicationKit/RecoverInterruptedMeetings.swift",
        ):
            selection = select_paths([path])
            self.assertEqual(selection.tests, expected, path)
            self.assertEqual(selection.locales, ("en",), path)

    def test_window_placement_expands_to_the_complete_bilingual_catalog(self):
        selection = select_paths(
            ["Sources/portavoz-app/UITestWindowPlacement.swift"]
        )
        self.assertEqual(selection.tests, HARNESS_TESTS)
        self.assertEqual(selection.locales, ("en", "es"))

    def test_seed_fixtures_expand_to_the_complete_bilingual_catalog(self):
        for path in (
            "Sources/portavoz-app/AppServices+UITestFixtures.swift",
            "Sources/portavoz-app/AppServices+AskTopicMemoryUITestFixture.swift",
            "Sources/portavoz-app/UITestDefaults.swift",
        ):
            with self.subTest(path=path):
                selection = select_paths([path])
                self.assertEqual(selection.tests, HARNESS_TESTS)
                self.assertEqual(selection.locales, ("en", "es"))
                self.assertIn("seed-fixture fallback", selection.reasons[0])

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
            FEATURE_TESTS["commitment-radar"]
            + FEATURE_TESTS["meeting-skills"]
            + FEATURE_TESTS["menu-bar-brief"]
            + FEATURE_TESTS["settings-skills"])
        expected = tuple(test for test in ALL_TESTS if test in expected_set)
        for path in [
            "Sources/PortavozCore/SkillExecutionPolicy.swift",
            "Sources/ApplicationKit/SkillsControlCenter.swift",
            "Sources/StorageKit/MeetingStore+SkillControl.swift",
            "Sources/portavoz-app/AppServices+MeetingSkills.swift",
            "Sources/portavoz-app/SkillActivitySection.swift",
            "Sources/portavoz-app/SkillsSettingsSection.swift",
        ]:
            selection = select_paths([path])
            self.assertEqual(selection.tests, expected, path)
            self.assertEqual(selection.locales, ("en",), path)

    def test_harness_change_expands_to_the_complete_bilingual_catalog(self):
        selection = select_paths(["Makefile"])
        self.assertEqual(selection.tests, HARNESS_TESTS)
        self.assertEqual(selection.locales, ("en", "es"))

    def test_app_intents_selects_only_the_bilingual_recording_handoff(self):
        selection = select_paths(
            ["Sources/portavoz-app/PortavozAppIntents.swift"]
        )
        self.assertEqual(
            selection.tests,
            FEATURE_TESTS["automation-entry"],
        )
        self.assertEqual(selection.locales, ("en", "es"))

    def test_app_entity_catalog_files_select_only_entry_and_radar(self):
        expected_set = set(
            FEATURE_TESTS["automation-entry"]
            + FEATURE_TESTS["commitment-radar"]
        )
        expected = tuple(test for test in ALL_TESTS if test in expected_set)
        for path in [
            "Sources/ApplicationKit/LoadAutomationEntities.swift",
            "Sources/StorageKit/MeetingStore+AutomationEntities.swift",
            "Sources/portavoz-app/AppServices+AutomationEntities.swift",
            "Sources/portavoz-app/AppServices+AutomationEntityUITestFixture.swift",
        ]:
            selection = select_paths([path])
            self.assertEqual(selection.tests, expected, path)
            self.assertEqual(selection.locales, ("en",), path)
            self.assertLess(len(selection.tests), len(ALL_TESTS), path)

        focus = select_paths([
            "Sources/portavoz-app/CommitmentRadarAppEntityFocusBanner.swift"
        ])
        self.assertEqual(focus.tests, FEATURE_TESTS["commitment-radar"])

    def test_recording_toolbar_selects_geometry_and_live_control_contracts(self):
        selection = select_paths(
            ["Sources/portavoz-app/RecordingToolbar.swift"]
        )
        self.assertEqual(
            selection.tests,
            tuple(test for test in ALL_TESTS if test in set(
                FEATURE_TESTS["automation-entry"]
                + FEATURE_TESTS["recording-interview"]
                + FEATURE_TESTS["recording-recovery"])),
        )
        self.assertEqual(selection.locales, ("en",))

    def test_interview_sources_select_the_single_grounded_real_app_journey(self):
        expected = FEATURE_TESTS["recording-interview"]
        for path in [
            "Sources/ApplicationKit/AssistInterviewQuestion.swift",
            "Sources/portavoz-app/RecordingInterviewAssistModel.swift",
            "Sources/portavoz-app/RecordingInterviewAssistView.swift",
        ]:
            selection = select_paths([path])
            self.assertEqual(selection.tests, expected, path)
            self.assertEqual(selection.locales, ("en",), path)

    def test_changed_ui_test_file_selects_only_its_class(self):
        selection = select_paths(["Tests/PortavozUITests/InsightsUITests.swift"])
        self.assertEqual(selection.tests, FEATURE_TESTS["insights"])
        self.assertTrue(all("InsightsUITests" in test for test in selection.tests))

    def test_web_fixture_selects_only_its_bilingual_real_app_journey(self):
        for path in (
            "Fixtures/ApuntadorWeb/public-local-v1.json",
            "Tests/PortavozUITests/ApuntadorWebFixtureSupport.swift",
        ):
            selection = select_paths([path])

            self.assertEqual(
                selection.tests,
                (
                    "PortavozUITests/LibraryUITests/"
                    "testAskConversationAnswersAndSeeksToExactCitation",
                ),
                path,
            )
            self.assertEqual(selection.locales, ("en", "es"), path)

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

    def test_ui_harness_forbids_blind_sleeps_and_native_existence_polling(self):
        sources = "\n".join(
            path.read_text(encoding="utf-8")
            for path in sorted((ROOT / "Tests" / "PortavozUITests").glob("*.swift"))
        )
        support = (ROOT / "Tests" / "PortavozUITests" / "UITestSupport.swift")
        support_source = support.read_text(encoding="utf-8")

        self.assertNotIn("Thread.sleep", sources)
        self.assertNotIn(".waitForExistence(", sources)
        self.assertNotIn(".waitForNonExistence(", sources)
        self.assertIn("func waitForUITestCondition(", support_source)
        self.assertIn("func waitForExistenceFast(", support_source)
        self.assertIn("func waitForDisappearance(", support_source)
        self.assertIn("RunLoop.current.run", support_source)
        settings_source = (
            ROOT / "Tests" / "PortavozUITests" / "SettingsUITests.swift"
        ).read_text(encoding="utf-8")
        self.assertNotIn(
            "settingsForm.scroll(byDeltaX: 0, deltaY: -18)",
            settings_source,
        )
        self.assertIn(
            "downloadFrame.maxY - visibleFormFrame.maxY",
            settings_source,
        )

    def test_catalog_policy_rejects_an_unscoped_test(self):
        scoped = ui_scope.test_id("InsightsUITests", "testScoped")
        temporary, root = self.minimal_catalog_root("testScoped", "testUnscoped")
        with temporary, mock.patch.multiple(
            ui_scope,
            FEATURE_TESTS={"insights": (scoped,)},
            ALL_TESTS=(scoped,),
            ALL_FEATURES=frozenset({"insights"}),
            FEATURE_SOURCE_SENTINELS={
                "insights": "Sources/portavoz-app/InsightsView.swift"
            },
            RETIRED_DUPLICATE_TESTS=frozenset(),
        ):
            with self.assertRaisesRegex(RuntimeError, "unscoped tests"):
                ui_scope.validate_catalog(root, runtime_budget_required=False)

    def test_catalog_policy_rejects_an_orphan_scope(self):
        scoped = ui_scope.test_id("InsightsUITests", "testScoped")
        temporary, root = self.minimal_catalog_root("testScoped", with_owner=False)
        with temporary, mock.patch.multiple(
            ui_scope,
            FEATURE_TESTS={"insights": (scoped,)},
            ALL_TESTS=(scoped,),
            ALL_FEATURES=frozenset({"insights"}),
            FEATURE_SOURCE_SENTINELS={
                "insights": "Sources/portavoz-app/InsightsView.swift"
            },
            RETIRED_DUPLICATE_TESTS=frozenset(),
        ):
            with self.assertRaisesRegex(RuntimeError, "orphan feature scopes"):
                ui_scope.validate_catalog(root, runtime_budget_required=False)

    def test_catalog_policy_rejects_a_known_duplicate_journey(self):
        retired = ui_scope.test_id("InsightsUITests", "testRetiredDuplicate")
        temporary, root = self.minimal_catalog_root("testRetiredDuplicate")
        with temporary, mock.patch.multiple(
            ui_scope,
            FEATURE_TESTS={"insights": (retired,)},
            ALL_TESTS=(retired,),
            ALL_FEATURES=frozenset({"insights"}),
            FEATURE_SOURCE_SENTINELS={
                "insights": "Sources/portavoz-app/InsightsView.swift"
            },
            RETIRED_DUPLICATE_TESTS=frozenset({retired}),
        ):
            with self.assertRaisesRegex(RuntimeError, "known duplicate tests returned"):
                ui_scope.validate_catalog(root, runtime_budget_required=False)

    def test_catalog_policy_rejects_duplicate_selectors_inside_scope(self):
        scoped = ui_scope.test_id("InsightsUITests", "testScoped")
        temporary, root = self.minimal_catalog_root("testScoped")
        with temporary, mock.patch.multiple(
            ui_scope,
            FEATURE_TESTS={"insights": (scoped, scoped)},
            ALL_TESTS=(scoped,),
            ALL_FEATURES=frozenset({"insights"}),
            FEATURE_SOURCE_SENTINELS={
                "insights": "Sources/portavoz-app/InsightsView.swift"
            },
            RETIRED_DUPLICATE_TESTS=frozenset(),
        ):
            with self.assertRaisesRegex(RuntimeError, "duplicate selectors"):
                ui_scope.validate_catalog(root, runtime_budget_required=False)


if __name__ == "__main__":
    unittest.main()
