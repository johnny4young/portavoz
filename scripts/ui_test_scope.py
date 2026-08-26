#!/usr/bin/env python3
"""Select the smallest safe Portavoz XCUITest set for a Git diff.

The selector is intentionally conservative: known presentation files map to
feature-level smoke tests, localization and shared composition changes run the
whole bilingual suite, and an unknown production Swift path falls back to the
whole English suite. Documentation, governance, CLI, and package-test-only
changes do not spend a macOS UI runner.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import shlex
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable, Sequence


TARGET = "PortavozUITests"
MAX_SUMMARY_BYTES = 16 * 1024


def test_id(test_class: str, method: str) -> str:
    return f"{TARGET}/{test_class}/{method}"


FEATURE_TESTS: dict[str, tuple[str, ...]] = {
    "launch-recovery": (
        test_id(
            "LibraryUITests",
            "testDatabaseLaunchFailureOffersSafeRecovery",
        ),
    ),
    "automation-entry": (
        test_id(
            "AutomationUITests",
            "testAppEntitiesOpenExactVisibleDestinations",
        ),
        test_id(
            "AutomationUITests",
            "testRecordingAutomationRoutesStartAndStopThroughVisibleApp",
        ),
    ),
    "library": (
        test_id("LibraryUITests", "testLibraryRendersRecordButtonAndActionChips"),
        test_id("LibraryUITests", "testSeededMeetingsGroupByRecency"),
        test_id("LibraryUITests", "testActiveRecordingRemainsReachableAfterBrowsingTheLibrary"),
    ),
    "meeting-brief": (
        test_id("LibraryUITests", "testUpcomingMeetingBriefShowsRelatedEvidenceAndOpenCommitment"),
    ),
    "menu-bar-brief": (
        test_id(
            "MenuBarUITests",
            "testPreMeetingBriefMovesFromExactProposalToDurableReceipt",
        ),
    ),
    "recording-recovery": (
        test_id("LibraryUITests", "testRecordingStartFailureOffersTypedRecovery"),
        test_id("LibraryUITests", "testRecordingWarnsWhenRemoteAudioCallbacksStop"),
        test_id("LibraryUITests", "testRecordingWarnsWhenIncomingAudioClips"),
        test_id("LibraryUITests", "testColdRecordingStartsLiveCaptionsWhenModelBecomesReady"),
        test_id("LibraryUITests", "testLiveTranscriptYieldsFollowWhileReadingHistory"),
        test_id("LibraryUITests", "testLiveTranslationUsesADistinctLabeledRail"),
        test_id("LibraryUITests", "testRecordingOffersObjectivesNextQuestionAndTalkBalance"),
        test_id("LibraryUITests", "testLaunchRecoversInterruptedStagingAudio"),
        test_id("LibraryUITests", "testLaunchResumesDurablePostCaptureProcessing"),
    ),
    "recording-interview": (
        test_id(
            "InterviewAssistUITests",
            "testInterviewAssistGroundsTheCurrentQuestionInExactEvidence",
        ),
    ),
    "ask": (
        test_id("LibraryUITests", "testAskConversationAnswersAndSeeksToExactCitation"),
        test_id(
            "LibraryUITests",
            "testAskConfirmedMemoryLoadsExactPersonCommitmentsAndEvidence",
        ),
        test_id(
            "LibraryUITests",
            "testAskConfirmedMemoryLoadsExactCommitmentBlockersAndEvidence",
        ),
        test_id(
            "LibraryUITests",
            "testAskConfirmedMemoryLoadsExactTopicDecisionsAndEvidence",
        ),
        test_id(
            "LibraryUITests",
            "testAskConfirmedMemoryLoadsExactTopicFirstDiscussionAndEvidence",
        ),
        test_id(
            "LibraryUITests",
            "testAskConfirmedMemoryLoadsExactTopicDecisionConflictsAndEvidence",
        ),
        test_id(
            "LibraryUITests",
            "testAskConfirmedMemoryLoadsExactTopicChangesSinceMeetingAndEvidence",
        ),
        test_id("LibraryUITests", "testCommandPaletteSearchAnswerAndCitationSurviveNoStaleState"),
    ),
    "insights": (
        test_id("InsightsUITests", "testInsightsShowsCompleteLocalDashboard"),
    ),
    "commitment-radar": (
        test_id(
            "CommitmentRadarUITests",
            "testReminderAlertOpensCommitmentRadar",
        ),
        test_id(
            "CommitmentRadarUITests",
            "testRadarFiltersConfirmedWorkAndOpensItsExactSourceMeeting",
        ),
        test_id(
            "CommitmentRadarUITests",
            "testReminderDraftRequiresExplicitAccessAndLeavesDurableReceipt",
        ),
        test_id(
            "CommitmentRadarUITests",
            "testReviewQueueKeepsSuggestionsSeparateAndOpensExactEvidence",
        ),
        test_id(
            "CommitmentRadarUITests",
            "testFieldQualityObservesARealReviewWithoutAutomatingDecisions",
        ),
    ),
    "main-shell": (
        test_id(
            "AutomationUITests",
            "testRecordingAutomationRoutesStartAndStopThroughVisibleApp",
        ),
        test_id("LibraryUITests", "testLibraryRendersRecordButtonAndActionChips"),
        test_id("LibraryUITests", "testAskConversationAnswersAndSeeksToExactCitation"),
        test_id("InsightsUITests", "testInsightsShowsCompleteLocalDashboard"),
        test_id("MeetingDetailUITests", "testRightRailShowsHealthAndChapters"),
        test_id("OnboardingUITests", "testAdvancesFromFirstListenToLocalVoiceEnrollment"),
        test_id(
            "CommitmentRadarUITests",
            "testRadarFiltersConfirmedWorkAndOpensItsExactSourceMeeting",
        ),
    ),
    "onboarding": (
        test_id("OnboardingUITests", "testAdvancesFromFirstListenToLocalVoiceEnrollment"),
    ),
    "meeting-performance": (
        test_id("MeetingDetailUITests", "testFiveThousandSegmentDetailRendersFromDisposableScaleFixture"),
        test_id(
            "MeetingDetailUITests",
            "testTwentyThousandSegmentDetailRendersFromDisposableScaleFixture",
        ),
    ),
    "meeting-export": (
        test_id("MeetingDetailUITests", "testExportMenuOffersSubtitleFormats"),
    ),
    "meeting-recap": (
        test_id(
            "MeetingDetailUITests",
            "testRecapSheetDraftsFromTheSummaryWithoutTheTranscript"),
    ),
    "meeting-naming": (
        test_id("MeetingDetailUITests", "testUnnamedSpeakerOffersExplicitNameSuggestions"),
        test_id(
            "MeetingDetailUITests",
            "testAISuggestionsCanBeIgnoredAndPlaybackOffersClearMix"),
        test_id("MeetingDetailUITests", "testNamedSpeakerCanBeRememberedAsCanonicalPerson"),
    ),
    "meeting-processing": (
        test_id("MeetingDetailUITests", "testFailedDurableProcessingOffersOneRecoveryAction"),
        test_id(
            "MeetingDetailUITests",
            "testAbandonedAutomaticSummarySaysSoBesideGeneration"),
        test_id("MeetingDetailUITests", "testSequoiaSummaryFailureOpensExactSetupAndExplainsApuntador"),
        test_id("MeetingDetailUITests", "testRunningRefineCanBeCanceledWithoutChangingTheTranscript"),
    ),
    "meeting-summary": (
        test_id("MeetingDetailUITests", "testTabbedSummaryRevealsTheCoauthoringBullet"),
        test_id("MeetingDetailUITests", "testMostRecentRecipeRemainsVisibleAfterReload"),
        test_id("MeetingDetailUITests", "testStructureMenuOffersSeededTemplates"),
        test_id("MeetingDetailUITests", "testMyNotesSectionShowsRawNotesAndOffersEnhancement"),
    ),
    "meeting-evidence": (
        test_id("MeetingDetailUITests", "testSummarySourceJumpsToItsTranscriptAndAudio"),
        test_id("MeetingDetailUITests", "testDecisionSourceJumpsToItsTranscriptAndAudio"),
        test_id("MeetingDetailUITests", "testDecisionCanBeConfirmedAboutATopic"),
        test_id("MeetingDetailUITests", "testActionItemSourceJumpsToItsTranscriptAndAudio"),
        test_id("MeetingDetailUITests", "testApuntadorAnswerSourceJumpsToItsTranscriptAndAudio"),
        test_id("MeetingDetailUITests", "testSummaryFeedbackIsExplicitReversibleAndLocal"),
    ),
    "meeting-commitments": (
        test_id(
            "MeetingDetailUITests",
            "testCommitmentInboxRequiresEvidenceReviewBeforeConfirmation",
        ),
    ),
    "meeting-skills": (
        test_id("MeetingDetailUITests", "testSkillProposalJourneyFromBannerToReceipt"),
        test_id(
            "MeetingDetailUITests",
            "testEmailRecapSkillPreviewsAndHandsOffWithoutSending",
        ),
        test_id(
            "MeetingDetailUITests",
            "testSecretGistSkillPreviewsPublishesAndReceiptsExactDocument",
        ),
        test_id(
            "MeetingDetailUITests",
            "testFailedSkillEffectRetriesItsOriginalProposal",
        ),
    ),
    "meeting-health": (
        test_id("MeetingDetailUITests", "testRightRailShowsHealthAndChapters"),
        test_id("MeetingDetailUITests", "testFreshQualifyingMeetingShowsThePostMeetingMirror"),
    ),
    "meeting-audio": (
        test_id(
            "MeetingDetailUITests",
            "testAISuggestionsCanBeIgnoredAndPlaybackOffersClearMix"),
        test_id("MeetingDetailUITests", "testSummarySourceJumpsToItsTranscriptAndAudio"),
        test_id("MeetingDetailUITests", "testPlayerExposesSkipAndOnlyMyVoice"),
        test_id("MeetingDetailUITests", "testClipMarkingRevealsExport"),
    ),
    "meeting-correction": (
        test_id(
            "MeetingDetailUITests",
            "testTranscriptCorrectionKeepsOriginalEvidenceAndDurableUndo",
        ),
        test_id(
            "MeetingDetailUITests",
            "testTranscriptStructuralCorrectionsSplitMergeHideAndRestoreEvidence",
        ),
        test_id(
            "MeetingDetailUITests",
            "testCorrectedTranscriptMarksDerivedArtifactsStale",
        ),
        test_id(
            "MeetingDetailUITests",
            "testExplicitApuntadorRefreshUsesCorrectedTranscript",
        ),
        test_id(
            "MeetingDetailUITests",
            "testSequoiaApuntadorRefreshPreservesStaleAnswers",
        ),
    ),
    "settings-navigation": (
        test_id("SettingsUITests", "testCategoryNavigationRevealsEachPane"),
        test_id("SettingsUITests", "testLanguageToggleSwitchesVisibleTextWithoutRelaunch"),
    ),
    "settings-skills": (
        test_id(
            "SkillsSettingsUITests",
            "testSuggestedActionsExplainReviewFirstSafety",
        ),
        test_id(
            "SkillsSettingsUITests",
            "testSkillsPaneFailsClosedWhenDurablePolicyCannotLoad",
        ),
        test_id(
            "SkillsSettingsUITests",
            "testFailedSkillControlMutationReloadsWithoutClosingSettings",
        ),
        test_id(
            "SkillsSettingsUITests",
            "testSkillsPaneControlsOffersAndShowsTheConfirmedReceipt",
        ),
        test_id(
            "SkillsSettingsUITests",
            "testSkillActivityScopeFailureDoesNotInventRowsOrDisableVerifiedPolicy",
        ),
        test_id(
            "SkillsSettingsUITests",
            "testSkillActivityTransitionsHideStaleRowsAndKeepVerifiedControlsUsable",
        ),
        test_id(
            "SkillsSettingsUITests",
            "testSameSkillProposalsHaveDistinctAccessibleActions",
        ),
        test_id(
            "SkillsSettingsUITests",
            "testSkillActivityExpandsOlderRunsOnlyAfterExplicitRequest",
        ),
        test_id(
            "SkillsSettingsUITests",
            "testSkillActivityHidesExpansionWhenExactlyOnePageExists",
        ),
        test_id(
            "SkillsSettingsUITests",
            "testSkillActivityRefreshPreservesTheExpandedCurrentScope",
        ),
        test_id(
            "SkillsSettingsUITests",
            "testSkillActivityFiltersByUpdatePeriodAndResetsExpansion",
        ),
        test_id(
            "SkillsSettingsUITests",
            "testSkillProposalFailureDoesNotInventOffersOrDisableVerifiedPolicy",
        ),
        test_id(
            "SkillsSettingsUITests",
            "testProposedSkillReviewReturnsToItsMeetingWithoutRunning",
        ),
        test_id(
            "SkillsSettingsUITests",
            "testFailedProposedSkillReviewKeepsTheOfferAndAllowsRetry",
        ),
        test_id(
            "SkillsSettingsUITests",
            "testProposedSkillDismissalRetiresTheDurableOfferEverywhere",
        ),
        test_id(
            "SkillsSettingsUITests",
            "testFailedProposedSkillDismissalKeepsTheOfferAndAllowsRetry",
        ),
        test_id(
            "SkillsSettingsUITests",
            "testWaitingSkillApprovalCanBeRevokedBeforeHandoff",
        ),
        test_id(
            "SkillsSettingsUITests",
            "testFailedWaitingSkillRevocationKeepsTheReceiptAndRetry",
        ),
        test_id(
            "SkillsSettingsUITests",
            "testRecoverableFailedSkillReturnsToItsMeetingWithoutRunning",
        ),
        test_id(
            "SkillsSettingsUITests",
            "testFailedRecoveryResolutionKeepsTheReceiptAndAllowsRetry",
        ),
        test_id(
            "SkillsSettingsUITests",
            "testWaitingReceiptIgnoresUnavailablePolicyAndReviewsSourceWithoutRunning",
        ),
        test_id(
            "SkillsSettingsUITests",
            "testFailedSourceContextResolutionKeepsReceiptAndAllowsRetry",
        ),
        test_id(
            "SkillsSettingsUITests",
            "testSkillReceiptRestoresKeyboardFocusAndPassesAccessibilityAudit",
        ),
    ),
    "settings-data": (
        test_id("SettingsUITests", "testLocalDataLedgerShowsExactCountsAndHonestNetworkPolicy"),
        test_id("SettingsUITests", "testSyncPaneKeepsOptInAndExistingLibrarySeparate"),
        test_id("SettingsUITests", "testDataPaneExportsARedactedLocalSupportFile"),
        test_id("SettingsUITests", "testDataPaneExportsAReadableWholeLibraryMarkdownBackup"),
    ),
    "production-sync": (
        test_id("SettingsUITests", "testSyncPaneKeepsOptInAndExistingLibrarySeparate"),
    ),
    "settings-intelligence": (
        test_id(
            "SettingsUITests",
            "testIntelligencePaneExplicitlyPreparesSemanticSearch",
        ),
        test_id("SettingsUITests", "testIntelligencePaneCreatesACustomStructure"),
    ),
    "settings-audio": (
        test_id("SettingsUITests", "testAudioPaneOffersCaptureSourceControls"),
        test_id("SettingsUITests", "testDictationOffersTriggersLanguageAndDictionary"),
    ),
    "settings-voice": (
        test_id(
            "SettingsUITests",
            "testUnreadableVoiceStorageStaysVisibleAndOffersExplicitRecovery",
        ),
        test_id("SettingsUITests", "testVoicePaneOffersTheMirrorOptIn"),
    ),
    "public-showcase": (
        test_id("PublicShowcaseUITests", "testMeetingDetailShowcase"),
        test_id("PublicShowcaseUITests", "testLiveTranslationShowcase"),
        test_id("PublicShowcaseUITests", "testInsightsShowcase"),
    ),
}

ALL_TESTS = tuple(dict.fromkeys(test for tests in FEATURE_TESTS.values() for test in tests))
ALL_FEATURES = frozenset(FEATURE_TESTS)
MEETING_FEATURES = frozenset(
    feature
    for feature in ALL_FEATURES
    if feature.startswith("meeting-") and feature != "meeting-brief"
)
SETTINGS_FEATURES = frozenset(feature for feature in ALL_FEATURES if feature.startswith("settings-"))
# Copy/localization and shared-harness changes can alter every accessibility
# query or localized assertion. They are integration changes, so the safe
# expansion is the complete bilingual catalog rather than a small canary set.
HARNESS_TESTS = ALL_TESTS

RETIRED_DUPLICATE_TESTS = frozenset({
    test_id("InsightsUITests", "testInsightsRendersHeatmap"),
    test_id("InsightsUITests", "testInsightsShowsWhoYouTalkWith"),
    test_id("OnboardingUITests", "testOpensOnTheFirstListenStep"),
    test_id("OnboardingUITests", "testContinueAdvancesPastTheFirstListen"),
    test_id("OnboardingUITests", "testVoiceStepOffersLocalEnrollmentWithoutStartingCapture"),
    test_id(
        "SkillsSettingsUITests",
        "testSkillActivityFiltersExactSkillAndResetsExpansion",
    ),
})

# One checked-in production owner per scope makes feature-to-test and
# changed-file-to-feature ownership executable. A new scope without a live
# owner is an orphan; a renamed owner that falls through to the broad default
# no longer silently validates the catalog.
FEATURE_SOURCE_SENTINELS: dict[str, str] = {
    "launch-recovery": "Sources/portavoz-app/AppLaunchRecoveryView.swift",
    "automation-entry": "Sources/portavoz-app/PortavozAppIntents.swift",
    "library": "Sources/portavoz-app/LibraryView.swift",
    "meeting-brief": "Sources/portavoz-app/MeetingBriefView.swift",
    "menu-bar-brief": "Sources/portavoz-app/MenuBarView.swift",
    "recording-recovery": "Sources/portavoz-app/RecordingView.swift",
    "recording-interview": "Sources/portavoz-app/RecordingInterviewAssistView.swift",
    "ask": "Sources/portavoz-app/AskView.swift",
    "insights": "Sources/portavoz-app/InsightsView.swift",
    "commitment-radar": "Sources/portavoz-app/CommitmentRadarView.swift",
    "main-shell": "Sources/portavoz-app/ContentView.swift",
    "onboarding": "Sources/portavoz-app/OnboardingView.swift",
    "meeting-performance": "Sources/portavoz-app/MeetingDetailPerformanceTrace.swift",
    "meeting-export": "Sources/portavoz-app/MeetingDetailHeaderSection.swift",
    "meeting-recap": "Sources/portavoz-app/MeetingDetailActionSection.swift",
    "meeting-naming": "Sources/portavoz-app/MeetingDetailHeaderSection.swift",
    "meeting-processing": "Sources/portavoz-app/MeetingDetailRefineReviewSheet.swift",
    "meeting-summary": "Sources/portavoz-app/MeetingDetailNotesSection.swift",
    "meeting-evidence": "Sources/portavoz-app/MeetingGeneratedDocumentSection.swift",
    "meeting-commitments": "Sources/portavoz-app/MeetingCommitmentInboxSection.swift",
    "meeting-skills": "Sources/portavoz-app/SkillOfferBanner.swift",
    "meeting-health": "Sources/portavoz-app/MeetingDetailTrustSection.swift",
    "meeting-audio": "Sources/portavoz-app/MeetingPlayerBar.swift",
    "meeting-correction": "Sources/portavoz-app/TranscriptStructuralCorrectionEditor.swift",
    "settings-navigation": "Sources/portavoz-app/SettingsView.swift",
    "settings-skills": "Sources/portavoz-app/SkillsSettingsSection.swift",
    "settings-data": "Sources/portavoz-app/AppServices+MeetingSync.swift",
    "production-sync": "Sources/portavoz-app/ProductionSyncQualificationRunner.swift",
    "settings-intelligence": "Sources/portavoz-app/SemanticSearchPreparationModel.swift",
    "settings-audio": "Sources/portavoz-app/AudioSection.swift",
    "settings-voice": "Sources/portavoz-app/SettingsVoiceSection.swift",
    "public-showcase": "Sources/portavoz-app/AppServices+Showcase.swift",
}

NO_UI_PREFIXES = (
    ".design-sync/",
    ".github/ISSUE_TEMPLATE/",
    "Tests/Tooling/",
    "Tests/PortavozTests/",
    "Sources/portavoz-cli/",
    "docs/",
    "site/",
    "packaging/",
)
NO_UI_FILES = {
    ".gitignore",
    ".swiftlint.yml",
    "AGENTS.md",
    "CLAUDE.md",
    "CHANGELOG.md",
    "CODE_OF_CONDUCT.md",
    "CONTRIBUTING.md",
    "LICENSE",
    "README.md",
    "SECURITY.md",
    "Package.resolved",
    "Package.swift",
}


@dataclass(frozen=True)
class Selection:
    tests: tuple[str, ...]
    locales: tuple[str, ...]
    reasons: tuple[str, ...]

    @property
    def required(self) -> bool:
        return bool(self.tests)


def feature_tests(features: Iterable[str]) -> set[str]:
    return {test for feature in features for test in FEATURE_TESTS[feature]}


def tests_for_ui_test_file(path: str) -> set[str]:
    match = re.fullmatch(r"Tests/PortavozUITests/(\w+UITests)\.swift", path)
    if match is None:
        return set()
    prefix = f"{TARGET}/{match.group(1)}/"
    return {test for test in ALL_TESTS if test.startswith(prefix)}


def app_features(filename: str) -> set[str]:
    lowered = filename.lower()
    if "automationentit" in lowered:
        return {"automation-entry", "commitment-radar"}
    if lowered in {"applaunchmodel.swift", "applaunchrecoveryview.swift"}:
        return {"launch-recovery", "main-shell"}
    if lowered in {
        "benchmode.swift",
        "benchmode+resourcerefinepreparation.swift",
        "benchresourcelaunchprobe.swift",
        "benchresourceprocesswatchdog.swift",
        "benchresourcescenarioprobe.swift",
    }:
        # These hidden isolated-benchmark owners have no presentation. Their
        # safe UI proof is normal/failing launch plus one canary per root
        # destination; benchmark behavior is covered by unit and disposable
        # Release-app evidence rather than every product journey.
        return {"launch-recovery", "main-shell"}
    if lowered.startswith("productionsyncqualification"):
        # The hidden exact-app owner has no presentation and runs only with a
        # disposable shell. Its safe real-app canary is the existing explicit
        # sync opt-in/existing-library Settings journey.
        return {"production-sync"}
    if lowered == "contentview.swift":
        # Root composition changes can affect every destination, but one
        # deterministic canary per route is sufficient; do not rerun all
        # feature permutations merely because a route was added or wired.
        return {"main-shell"}
    if lowered == "portavozappdelegate.swift":
        # The delegate owns external entry routes. Exercise the automation
        # handoff and the exact reminder-to-Radar path without expanding an
        # isolated routing change to every destination behind ContentView.
        return {"automation-entry", "commitment-radar"}
    if lowered == "appservices+meetingsync.swift":
        return {"settings-data"}
    if lowered in {"appservices.swift", "portavozapp.swift"}:
        # Process composition/startup changes need one deterministic canary per
        # route, not every feature permutation behind those destinations.
        return {"launch-recovery", "main-shell", "menu-bar-brief"}
    if "commitmentreminder" in lowered:
        return {"commitment-radar", "meeting-commitments"}
    if any(token in lowered for token in (
        "commitmentradar",
        "commitmentfieldquality",
        "reminderdraft",
    )):
        return {"commitment-radar"}
    if any(token in lowered for token in ("l10n", "applanguage")):
        return set(ALL_FEATURES)
    if "showcase" in lowered:
        return {"public-showcase"}
    # Before the generic "section"/"settings" buckets: dictation UI lives in
    # the Audio pane, and its system-wide surface (triggers, paste) has no
    # other XCUITest-reachable evidence.
    if any(
        token in lowered
        for token in ("dictation", "mousebutton", "mouseptt", "hotkey", "textinserter")
    ):
        return {"settings-audio"}
    if "semanticsearchpreparation" in lowered:
        return {"settings-intelligence"}
    if any(token in lowered for token in ("ask", "commandpalette")):
        return {"ask", "library"}
    if any(token in lowered for token in (
        "transcriptcorrection", "transcriptstructuralcorrection"
    )):
        return {"meeting-correction"}
    if any(token in lowered for token in ("insight",)):
        return {"insights"}
    if any(token in lowered for token in ("onboarding", "firstrun", "firstlisten")):
        return {"onboarding", "settings-voice", "settings-intelligence"}
    if "recordingtoolbar" in lowered:
        # This component owns the external-recording geometry contract as
        # well as the live catch-up, next-question, mute, and Stop controls.
        # It does not affect Library grouping or unrelated detail surfaces.
        return {"automation-entry", "recording-interview", "recording-recovery"}
    if "interviewassist" in lowered:
        return {"recording-interview"}
    if "proactiveassist" in lowered:
        return {"recording-recovery"}
    if any(token in lowered for token in (
        "recording", "startrecording", "stoprecording", "postcapture",
        "livetranslation", "livesummary"
    )):
        return {"library", "recording-interview", "recording-recovery"}
    if any(token in lowered for token in ("library", "trash", "voicemix")):
        return {"library"}
    if "menubar" in lowered:
        return {"menu-bar-brief"}
    if any(token in lowered for token in ("meetingbrief", "meetingreminder")):
        return {"meeting-brief", "library"}
    if "legacyscrollinteractiontracker" in lowered:
        # This AppKit escape exists only for reader-owned live transcript
        # history on macOS 14. Keep a new focused bridge from silently
        # expanding one interaction fix to the complete bilingual suite.
        return {"recording-recovery"}
    if any(token in lowered for token in (
        "meetingdetailperformancetrace", "scalebenchmark"
    )):
        return {"meeting-performance"}
    if "transcriptsegments" in lowered:
        return {
            "meeting-audio", "meeting-correction", "meeting-evidence", "meeting-performance"
        }
    if "meetingtranscriptsection" in lowered:
        return {
            "meeting-audio", "meeting-correction", "meeting-evidence", "meeting-health",
            "meeting-performance",
        }
    if "meetingdetailheadersection" in lowered:
        return {"meeting-export", "meeting-naming", "meeting-processing"}
    if "meetinggenerateddocumentsection" in lowered:
        return {"meeting-correction", "meeting-evidence", "meeting-summary"}
    if "meetingdetailsummaryplaceholder" in lowered:
        return {"meeting-processing", "meeting-summary"}
    if "meetingcommitmentinbox" in lowered:
        return {"meeting-commitments"}
    if any(token in lowered for token in (
        "skillofferbanner", "skillconfirmsheet", "meetingdetailcoordinator+skills"
    )):
        return {"meeting-skills"}
    if "skill" in lowered:
        return {
            "commitment-radar",
            "meeting-skills",
            "menu-bar-brief",
            "settings-skills",
        }
    if "reminderdraft" in lowered:
        return {"commitment-radar"}
    if "meetingdetailtrustsection" in lowered:
        return {"meeting-health", "meeting-processing", "meeting-skills"}
    if "meetingdetailactionsection" in lowered:
        return {"meeting-export", "meeting-processing", "meeting-recap"}
    if "meetingdetailcoordinator+identity" in lowered:
        return {"meeting-naming"}
    if "meetingdetailcoordinator+documents" in lowered:
        return {
            "meeting-correction",
            "meeting-evidence",
            "meeting-export",
            "meeting-processing",
            "meeting-recap",
            "meeting-summary",
        }
    if "meetingdetailcoordinator+commitments" in lowered:
        return {"meeting-commitments"}
    if lowered == "meetingdetailcoordinator.swift":
        return {
            "meeting-audio",
            "meeting-correction",
            "meeting-evidence",
            "meeting-processing",
        }
    if "meetingdetailflowhost" in lowered:
        return {
            "meeting-export",
            "meeting-health",
            "meeting-naming",
            "meeting-processing",
            "meeting-recap",
            "meeting-summary",
        }
    if "meetingdetailnotessection" in lowered:
        return {"meeting-summary"}
    if "meetingdetailrefinereviewsheet" in lowered:
        return {"meeting-processing"}
    if "meetingdetailplaybacknavigation" in lowered:
        return {"meeting-audio", "meeting-evidence", "meeting-performance"}
    if "meetingdetailrailsection" in lowered:
        return {
            "meeting-correction", "meeting-evidence", "meeting-health", "meeting-processing"
        }
    if "meetingdetailplayersection" in lowered:
        return {"meeting-audio"}
    if "meetingdetailflowstate" in lowered:
        return {
            "meeting-correction",
            "meeting-export",
            "meeting-naming",
            "meeting-processing",
            "meeting-recap",
            "meeting-summary",
        }
    if "focusedtranscript" in lowered:
        return {"meeting-audio", "recording-recovery"}
    if any(token in lowered for token in ("meetingplayer", "audioworkflow", "meetingaudio")):
        return {"meeting-audio"}
    if "exportdocument" in lowered:
        return {"meeting-export"}
    if "appintents" in lowered:
        # Shortcuts itself is another app, but the intent's complete product
        # handoff is the production portavoz://record route. Exercise that
        # one boundary instead of seven unrelated recovery scenarios.
        return {"automation-entry"}
    if "recap" in lowered:
        return {"meeting-recap"}
    if any(token in lowered for token in ("summary", "companion")):
        return {
            "meeting-correction",
            "meeting-summary",
            "meeting-evidence",
            "meeting-processing",
            "settings-intelligence",
        }
    if any(token in lowered for token in ("speaker", "meetingname", "voicememory")):
        return {"meeting-naming", "meeting-health", "settings-voice"}
    if any(token in lowered for token in ("meetingdetail", "meetinghealth", "mirrorcard", "refine")):
        return set(MEETING_FEATURES)
    if any(token in lowered for token in ("settings", "section", "localdata", "whispermodel", "mlxmodel")):
        return set(SETTINGS_FEATURES)
    return set(ALL_FEATURES)


def lower_layer_features(path: str) -> set[str]:
    lowered = path.lower()
    if "proactivemeetingassist" in lowered:
        # The deterministic policy is rendered only by the consolidated live-
        # assist journey; it has no model, Settings, detail, or Library route.
        return {"recording-recovery"}
    if any(token in lowered for token in (
        "asknotes",
        "localasknote",
        "contextitemsearch",
        "meetingstore+notesearch",
    )):
        # Typed raw-note Ask has one consolidated real-app journey. Keep its
        # storage/index and orchestration files from paying for unrelated UI.
        return {"ask"}
    if any(token in lowered for token in (
        "numberedcitationanswer",
        "ragtextanswering",
        "raganswerer",
    )):
        # The shared cited-prose/provider authority is consumed by manual Ask
        # and live Interview Assist, but not every intelligence-backed screen.
        return {"ask", "recording-interview"}
    if "interview" in lowered:
        return {"recording-interview"}
    if "loadcommitmentblockers" in lowered:
        return {"ask"}
    if "decisionrelationship" in lowered:
        return {"ask"}
    if "topicfirstdiscussion" in lowered:
        return {"ask"}
    if "confirmedtopiccatalog" in lowered:
        return {"ask"}
    if "semanticsearchassetpreparation" in lowered:
        return {"settings-intelligence"}
    if "automationentit" in lowered:
        return {"automation-entry", "commitment-radar"}
    if "launchrecovery" in lowered:
        return {"launch-recovery"}
    if "skill" in lowered:
        return {
            "commitment-radar",
            "meeting-skills",
            "menu-bar-brief",
            "settings-skills",
        }
    if "reminderdraft" in lowered:
        return {"commitment-radar"}
    if "commitmentradar" in lowered or "commitmentfieldquality" in lowered:
        return {"commitment-radar"}
    if any(token in lowered for token in (
        "managemeetingcommitmentinbox",
        "meetingcommitmentinbox",
    )):
        return {"meeting-commitments"}
    if lowered in {
        "sources/applicationkit/correctmeetingtranscript.swift",
        "sources/applicationkit/meetingtranscriptgenerationmaterial.swift",
        "sources/applicationkit/restructuremeetingtranscript.swift",
        "sources/portavozcore/transcriptcorrection.swift",
        "sources/portavozcore/transcriptcorrectionrevision.swift",
        "sources/storagekit/meetingstore+transcriptcorrections.swift",
        "sources/storagekit/meetingstore+transcriptprojection.swift",
        "sources/storagekit/schema+transcriptcorrection.swift",
        "sources/storagekit/transcriptcorrectionrecords.swift",
    }:
        return {"meeting-correction"}
    if lowered in {
        "sources/applicationkit/meetingdetailreadmodels.swift",
        "sources/storagekit/meetingstore+meetingdetailobservation.swift",
    }:
        return set(MEETING_FEATURES)
    if lowered == "sources/applicationkit/composetranscript.swift":
        return {"meeting-correction"}
    if "meetingtranscriptcontent" in lowered:
        return {
            "meeting-audio", "meeting-evidence", "meeting-health", "meeting-performance"
        }
    if "meetinggenerateddocumentpresentation" in lowered:
        return {"meeting-evidence", "meeting-summary"}
    if "queryexpander" in lowered:
        # Deterministic query variants feed only Library search, full Ask,
        # and the meeting-brief evidence lookup. Keep a lexicon-only change
        # from expanding to every unrelated app surface.
        return {"ask", "library", "meeting-brief"}
    if "micbleed" in lowered:
        # Bleed admission affects live captions and the reviewed Refine
        # replacement, not every unrelated screen in the application.
        return {"recording-recovery", "meeting-processing"}
    if "stoprecording" in lowered or "startrecording" in lowered:
        return {"library", "recording-recovery"}
    if any(token in lowered for token in ("dictation", "mouseptt")):
        return {"settings-audio"}
    if "subtitle" in lowered:
        return {"meeting-export"}
    if "recap" in lowered:
        return {"meeting-recap"}
    if "insight" in lowered:
        return {"insights"}
    if any(token in lowered for token in ("ask", "brief")):
        return {"ask", "meeting-brief", "menu-bar-brief"}
    if any(token in lowered for token in ("recording", "capture", "postcapture")):
        return {"library", "recording-recovery", "settings-audio"}
    if any(token in lowered for token in ("playback", "waveform", "audio")):
        return {"meeting-audio", "settings-audio"}
    if any(
        token in lowered
        for token in ("summary", "summaries", "companion", "intelligence")
    ):
        return {
            "ask",
            "insights",
            "library",
            "meeting-brief",
            "meeting-correction",
            "meeting-summary",
            "meeting-evidence",
            "meeting-processing",
            "public-showcase",
            "settings-intelligence",
        }
    if any(token in lowered for token in ("voice", "speaker", "person")):
        return {"meeting-naming", "meeting-health", "settings-voice", "onboarding"}
    if "sync" in lowered:
        return {"settings-data"}
    return set(ALL_FEATURES)


def select_paths(paths: Iterable[str]) -> Selection:
    selected: set[str] = set()
    locales: set[str] = {"en"}
    reasons: list[str] = []

    for raw_path in paths:
        path = raw_path.strip().removeprefix("./")
        if not path:
            continue

        if path == "Resources/Localization/Portavoz/Localizable.xcstrings":
            selected.update(HARNESS_TESTS)
            locales.add("es")
            reasons.append(f"{path}: complete bilingual localization fallback")
            continue

        if path in {
            "Makefile",
            "project.yml",
            "scripts/run-ui-tests.sh",
            "Sources/portavoz-app/UITestWindowPlacement.swift",
            "Tests/PortavozUITests/UITestSupport.swift",
        }:
            selected.update(HARNESS_TESTS)
            locales.add("es")
            reasons.append(f"{path}: complete bilingual shared-harness fallback")
            continue

        if path in {
            "Fixtures/ApuntadorWeb/public-local-v1.json",
            "Tests/PortavozUITests/ApuntadorWebFixtureSupport.swift",
        }:
            selected.add(
                test_id(
                    "LibraryUITests",
                    "testAskConversationAnswersAndSeeksToExactCitation",
                )
            )
            locales.add("es")
            reasons.append(
                f"{path}: bilingual deterministic Web Ask journey"
            )
            continue

        changed_ui_tests = tests_for_ui_test_file(path)
        if changed_ui_tests:
            selected.update(changed_ui_tests)
            reasons.append(f"{path}: changed UI-test contract")
            continue

        if path.startswith("Sources/portavoz-app/") and path.endswith(".swift"):
            file_name = Path(path).name
            if file_name in {
                "AppServices+UITestFixtures.swift",
                "AppServices+AskTopicMemoryUITestFixture.swift",
                "UITestDefaults.swift",
            }:
                selected.update(HARNESS_TESTS)
                locales.add("es")
                reasons.append(
                    f"{path}: complete bilingual seed-fixture fallback"
                )
                continue
            features = app_features(file_name)
            selected.update(feature_tests(features))
            if file_name == "PortavozAppIntents.swift":
                locales.add("es")
            reasons.append(f"{path}: {', '.join(sorted(features))}")
            continue

        if path.startswith("Sources/") and path.endswith(".swift"):
            features = lower_layer_features(path)
            if not features:
                continue
            selected.update(feature_tests(features))
            reasons.append(f"{path}: {', '.join(sorted(features))}")
            continue

        if path.startswith(NO_UI_PREFIXES) or path in NO_UI_FILES or path.startswith(".github/") or path.startswith("scripts/"):
            continue

        # Unknown build/configuration changes may alter the executable even if
        # they do not look like a view. Prefer one full English pass to a false
        # claim that UI evidence was unnecessary.
        selected.update(ALL_TESTS)
        reasons.append(f"{path}: unknown executable impact (full fallback)")

    ordered_tests = tuple(test for test in ALL_TESTS if test in selected)
    ordered_locales = tuple(locale for locale in ("en", "es") if locale in locales) if ordered_tests else ()
    return Selection(ordered_tests, ordered_locales, tuple(dict.fromkeys(reasons)))


def changed_paths(base: str, head: str) -> list[str]:
    command = ["git", "diff", "--name-only", "--diff-filter=ACDMRTUXB", base, head, "--"]
    result = subprocess.run(command, check=True, capture_output=True, text=True)
    return result.stdout.splitlines()


def working_tree_paths(base: str, *, cwd: Path | None = None) -> list[str]:
    """Return index, working-tree, and untracked paths that differ from base."""
    working_tree = subprocess.run(
        ["git", "diff", "--name-only", "--diff-filter=ACDMRTUXB", base, "--"],
        check=True,
        capture_output=True,
        text=True,
        cwd=cwd,
    ).stdout.splitlines()
    staged = subprocess.run(
        ["git", "diff", "--cached", "--name-only", "--diff-filter=ACDMRTUXB", base, "--"],
        check=True,
        capture_output=True,
        text=True,
        cwd=cwd,
    ).stdout.splitlines()
    untracked = subprocess.run(
        ["git", "ls-files", "--others", "--exclude-standard"],
        check=True,
        capture_output=True,
        text=True,
        cwd=cwd,
    ).stdout.splitlines()
    return list(dict.fromkeys((*working_tree, *staged, *untracked)))


def discovered_test_catalog(root: Path) -> set[str]:
    discovered: set[str] = set()
    for source in sorted((root / "Tests/PortavozUITests").glob("*UITests.swift")):
        content = source.read_text(encoding="utf-8")
        class_match = re.search(r"final class\s+(\w+UITests)\s*:", content)
        if class_match is None:
            continue
        for method in re.findall(r"func\s+(test\w+)\s*\(", content):
            discovered.add(test_id(class_match.group(1), method))
    return discovered


def validate_catalog(root: Path, *, runtime_budget_required: bool = True) -> None:
    expected = set(ALL_TESTS)
    discovered = discovered_test_catalog(root)
    missing = sorted(discovered - expected)
    stale = sorted(expected - discovered)
    duplicates = sorted(
        feature
        for feature, tests in FEATURE_TESTS.items()
        if len(tests) != len(set(tests))
    )
    empty_scopes = sorted(
        feature for feature, tests in FEATURE_TESTS.items() if not tests
    )
    retired = sorted(discovered & RETIRED_DUPLICATE_TESTS)
    sentinel_mismatch = sorted(ALL_FEATURES ^ FEATURE_SOURCE_SENTINELS.keys())
    orphan_scopes: list[str] = []
    for feature, path in FEATURE_SOURCE_SENTINELS.items():
        source = root / path
        if not source.is_file():
            orphan_scopes.append(f"{feature} (missing {path})")
            continue
        mapped = app_features(source.name)
        if feature not in mapped or mapped == set(ALL_FEATURES):
            orphan_scopes.append(f"{feature} ({path})")

    runtime_budget_errors: list[str] = []
    if runtime_budget_required:
        budget_path = root / "docs/evidence/ui-test-runtime-budget.json"
        if not budget_path.is_file():
            runtime_budget_errors.append(f"missing {budget_path.relative_to(root)}")
        else:
            budget = json.loads(budget_path.read_text(encoding="utf-8"))
            runtime_ids = set(budget.get("testBudgetsSeconds", {}))
            expected_runtime_ids = {
                "/".join(selector.split("/")[1:]) + "()"
                for selector in ALL_TESTS
            }
            missing_budgets = sorted(expected_runtime_ids - runtime_ids)
            stale_budgets = sorted(runtime_ids - expected_runtime_ids)
            budget_count = budget.get("catalog", {}).get("expectedCaseCount")
            if missing_budgets:
                runtime_budget_errors.append(
                    "tests without runtime budget: " + ", ".join(missing_budgets)
                )
            if stale_budgets:
                runtime_budget_errors.append(
                    "stale runtime budgets: " + ", ".join(stale_budgets)
                )
            if budget_count != len(ALL_TESTS):
                runtime_budget_errors.append(
                    f"runtime budget count {budget_count!r} != {len(ALL_TESTS)}"
                )

    if (
        missing
        or stale
        or duplicates
        or empty_scopes
        or retired
        or sentinel_mismatch
        or orphan_scopes
        or runtime_budget_errors
    ):
        details = []
        if missing:
            details.append("unscoped tests: " + ", ".join(missing))
        if stale:
            details.append("stale selectors: " + ", ".join(stale))
        if duplicates:
            details.append("duplicate selectors inside scopes: " + ", ".join(duplicates))
        if empty_scopes:
            details.append("empty feature scopes: " + ", ".join(empty_scopes))
        if retired:
            details.append("known duplicate tests returned: " + ", ".join(retired))
        if sentinel_mismatch:
            details.append("feature/source sentinel mismatch: " + ", ".join(sentinel_mismatch))
        if orphan_scopes:
            details.append("orphan feature scopes: " + ", ".join(orphan_scopes))
        details.extend(runtime_budget_errors)
        raise RuntimeError("UI-test scope catalog is stale; " + "; ".join(details))


def bounded_summary(reasons: Sequence[str]) -> str:
    if not reasons:
        return "no UI-impacting paths"
    full_summary = "; ".join(reasons)
    if len(full_summary.encode("utf-8")) <= MAX_SUMMARY_BYTES:
        return full_summary

    digest = hashlib.sha256(full_summary.encode("utf-8")).hexdigest()
    kept: list[str] = []
    for reason in reasons:
        candidate = kept + [reason]
        omitted = len(reasons) - len(candidate)
        suffix = (
            f"; ... {omitted} additional reason"
            f"{'s' if omitted != 1 else ''} omitted"
            f"; full-summary-sha256={digest}"
        )
        rendered = "; ".join(candidate) + suffix
        if len(rendered.encode("utf-8")) > MAX_SUMMARY_BYTES:
            break
        kept = candidate

    if not kept:
        return (
            f"{len(reasons)} reasons omitted; "
            f"full-summary-sha256={digest}"
        )
    omitted = len(reasons) - len(kept)
    return (
        "; ".join(kept)
        + f"; ... {omitted} additional reason"
        + ("s" if omitted != 1 else "")
        + f" omitted; full-summary-sha256={digest}"
    )


def render(selection: Selection, output_format: str) -> str:
    tests = " ".join(selection.tests)
    locales = " ".join(selection.locales)
    summary = bounded_summary(selection.reasons)
    if output_format == "github":
        return "\n".join(
            (
                f"required={'true' if selection.required else 'false'}",
                f"tests={tests}",
                f"locales={locales}",
                f"summary={summary}",
            )
        )
    if output_format == "shell":
        return "\n".join(
            (
                f"export UI_TEST_REQUIRED={'true' if selection.required else 'false'}",
                f"export UI_TESTS={shlex.quote(tests)}",
                f"export UI_TEST_LOCALES={shlex.quote(locales)}",
                f"export UI_TEST_SCOPE_SUMMARY={shlex.quote(summary)}",
            )
        )
    if not selection.required:
        return "No UI tests required."
    return (
        f"UI tests: {len(selection.tests)}/{len(ALL_TESTS)}\n"
        f"Locales: {locales}\n"
        f"Selectors:\n  " + "\n  ".join(selection.tests) + f"\nReasons: {summary}"
    )


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    result.add_argument("paths", nargs="*", help="Changed paths; otherwise --base and --head are diffed")
    result.add_argument("--base", help="Base Git revision")
    result.add_argument("--head", default="HEAD", help="Head Git revision (default: HEAD)")
    result.add_argument(
        "--working-tree",
        action="store_true",
        help="Compare --base with the current index, working tree, and untracked files",
    )
    result.add_argument("--all", action="store_true", help="Select every UI test in both locales")
    result.add_argument("--format", choices=("human", "github", "shell"), default="human")
    result.add_argument("--validate-catalog", action="store_true", help="Fail if a UI test lacks a selector")
    return result


def main(argv: Sequence[str] | None = None) -> int:
    arguments = parser().parse_args(argv)
    root = Path(__file__).resolve().parent.parent
    if arguments.validate_catalog:
        validate_catalog(root)
        if not arguments.paths and not arguments.base and not arguments.all:
            print(f"UI-test scope catalog is complete ({len(ALL_TESTS)} tests).")
            return 0

    if arguments.all:
        selection = Selection(ALL_TESTS, ("en", "es"), ("explicit full-suite request",))
    else:
        paths = arguments.paths
        if arguments.working_tree:
            if not arguments.base:
                print("--working-tree requires --base.", file=sys.stderr)
                return 2
            paths = working_tree_paths(arguments.base)
        elif arguments.base:
            paths = changed_paths(arguments.base, arguments.head)
        elif not paths:
            print("Provide changed paths, --base, or --all.", file=sys.stderr)
            return 2
        selection = select_paths(paths)
    print(render(selection, arguments.format))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
