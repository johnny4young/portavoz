"""Which UI tests exist and which feature, canary or dependency owns them.

Data only, so adding a case or changing a time here never widens a selection.
`scripts/ui_test_scope.py` owns the rules that use it.
"""

from __future__ import annotations


TARGET = "PortavozUITests"


def test_id(test_class: str, method: str) -> str:
    return f"{TARGET}/{test_class}/{method}"


FEATURE_TESTS: dict[str, tuple[str, ...]] = {
    "launch-recovery": (
        test_id("LibraryUITests", "testDatabaseLaunchFailureOffersSafeRecovery"),
        test_id("LibraryUITests", "testLaunchRecoversInterruptedStagingAudio"),
        test_id("LibraryUITests", "testLaunchResumesDurablePostCaptureProcessing"),
    ),
    "background-work": (
        test_id("BackgroundWorkUITests", "testBackgroundWorkCenterShowsAllOwnersAndRecoversExactFailures"),
        test_id("BackgroundWorkUITests", "testRecordingDefersDerivedWorkAndStopResumesIt"),
    ),
    "automation-entry": (
        test_id("AutomationUITests", "testRecordingAutomationRoutesStartAndStopThroughVisibleApp"),
    ),
    "home": (
        test_id("HomeUITests", "testTodayShowsEverythingAboveTheFoldAndActsWithoutTyping"),
    ),
    "library": (
        test_id("LibraryUITests", "testLibraryRendersRecordButtonAndActionChips"),
        test_id("LibraryUITests", "testActiveRecordingRemainsReachableAfterBrowsingTheLibrary"),
        test_id("LibraryUITests", "testSeededMeetingsGroupByRecency"),
    ),
    "audio-imports": (
        test_id("AudioImportUITests", "testSingleMeetingBundleReachesDetailWithoutChangingTheOriginal"),
        test_id("AudioImportUITests", "testRelaunchResumesPublishedAudioWithoutTheSelectedOriginals"),
    ),
    "meeting-brief": (
        test_id("LibraryUITests", "testUpcomingMeetingBriefShowsRelatedEvidenceAndOpenCommitment"),
    ),
    "menu-bar-brief": (
        test_id("MenuBarUITests", "testPreMeetingBriefMovesFromExactProposalToDurableReceipt"),
    ),
    "recording-recovery": (
        test_id("LibraryUITests", "testCleanStopReachesAReadyMeetingWithItsTranscriptAndPlayer"),
        test_id("LibraryUITests", "testCaptureFailureSurvivesStopAndRelaunchWithPlayablePrefix"),
        test_id("LibraryUITests", "testOwnedTokenPreviewRetiresWithoutEnteringCanonicalCaption"),
        test_id("LibraryUITests", "testRecordingStartFailureOffersTypedRecovery"),
        test_id("LibraryUITests", "testRecordingWarnsWhenRemoteAudioCallbacksStop"),
        test_id("LibraryUITests", "testRecordingAsksWhetherTheCallEndedAndKeepsRecording"),
        test_id("LibraryUITests", "testColdRecordingStartsLiveCaptionsWhenModelBecomesReady"),
        test_id("LibraryUITests", "testLiveTranscriptYieldsFollowWhileReadingHistory"),
    ),
    "live-assist": (
        test_id("LibraryUITests", "testRecordingOffersObjectivesNextQuestionAndTalkBalance"),
        test_id("RecordingAssistUITests", "testLatestManualAssistRequestOwnsTheFocusSlot"),
        test_id("RecordingAssistUITests", "testUnsubmittedNotesAndObjectivesSurviveTabsAndLibraryBrowsing"),
        test_id("RecordingInputUITests", "testAcceptedNotesAndObjectivesSurviveTerminationAndRecovery"),
    ),
    "recording-interview": (
        test_id("InterviewAssistUITests", "testInterviewAssistGroundsTheCurrentQuestionInExactEvidence"),
    ),
    "ask": (
        test_id("DictationHistoryUITests", "testAskAboutDictationsCitesAndOpensTheDictation"),
        test_id("LibraryUITests", "testCommandPaletteSearchAnswerAndCitationSurviveNoStaleState"),
        test_id("LibraryUITests", "testAskConversationAnswersAndSeeksToExactCitation"),
    ),
    "insights": (
        test_id("InsightsUITests", "testInsightsShowsCompleteLocalDashboard"),
    ),
    "commitment-radar": (
        test_id("CommitmentRadarUITests", "testReminderAlertOpensCommitmentRadar"),
        test_id("CommitmentRadarUITests", "testReviewThenConfirmedWorkKeepTheirFiltersAndOpenExactSources"),
    ),
    "main-shell": (
        test_id("LibraryUITests", "testLibraryRendersRecordButtonAndActionChips"),
        test_id("CommitmentRadarUITests", "testReviewThenConfirmedWorkKeepTheirFiltersAndOpenExactSources"),
        test_id("HomeUITests", "testTodayShowsEverythingAboveTheFoldAndActsWithoutTyping"),
        test_id("InsightsUITests", "testInsightsShowsCompleteLocalDashboard"),
        test_id("OnboardingUITests", "testAdvancesFromFirstListenToLocalVoiceEnrollment"),
    ),
    "onboarding": (
        test_id("DictationPracticeUITests", "testOnboardingDictationStepPracticesInItsOwnFieldWithoutTheClipboard"),
        test_id("DictationPracticeUITests", "testOnboardingDictationStepOffersShortcutAndAccessibilityOnceTurnedOn"),
        test_id("OnboardingUITests", "testAdvancesFromFirstListenToLocalVoiceEnrollment"),
        test_id("OnboardingUITests", "testModelFailureCanContinueBackAndRetryWithoutDownloading"),
    ),
    "meeting-performance": (
        test_id("MeetingDetailUITests", "testTwentyThousandSegmentDetailRendersFromDisposableScaleFixture"),
    ),
    "meeting-export": (
        test_id("MeetingDetailUITests", "testExportMenuOffersSubtitleFormats"),
    ),
    "meeting-recap": (
        test_id("MeetingDetailUITests", "testRecapSheetDraftsFromTheSummaryWithoutTheTranscript"),
    ),
    "meeting-naming": (
        test_id("MeetingDetailUITests", "testAConfidentVoiceMatchNamesTheSpeakerAndCanBeUndone"),
        test_id("MeetingDetailUITests", "testNamedSpeakerCanBeRememberedAsCanonicalPerson"),
    ),
    "meeting-processing": (
        test_id("MeetingDetailUITests", "testFailedDurableProcessingOffersOneRecoveryAction"),
        test_id("MeetingDetailUITests", "testNoAppleIntelligenceSummaryFailureOpensExactSetupAndExplainsApuntador"),
        test_id("MeetingDetailUITests", "testRunningRefineCanBeCanceledWithoutChangingTheTranscript"),
    ),
    "meeting-summary": (
        test_id("MeetingDetailUITests", "testMeetingReviewSurfacesRemainCompleteAndActionable"),
    ),
    "meeting-evidence": (
        test_id("MeetingDetailUITests", "testEvidenceSourcesJumpToTheirExactTranscriptAndAudio"),
    ),
    "meeting-commitments": (
        test_id("MeetingDetailUITests", "testCommitmentInboxRequiresEvidenceReviewBeforeConfirmation"),
    ),
    "meeting-skills": (
        test_id("MeetingDetailUITests", "testSkillProposalJourneyFromBannerToReceipt"),
    ),
    "meeting-health": (
        test_id("MeetingDetailUITests", "testMeetingReviewSurfacesRemainCompleteAndActionable"),
    ),
    "meeting-audio": (
        test_id("MeetingAudioTrimUITests", "testSilentTailRequiresConfirmationAndCutsOnlyAfterConfirmation"),
        test_id("MeetingDetailUITests", "testPlayerMarksAClipJumpsFromALineAndPlaysOneVoice"),
    ),
    "meeting-correction": (
        test_id("MeetingDetailUITests", "testExplicitApuntadorRefreshUsesCorrectedTranscript"),
        test_id("MeetingDetailUITests", "testTranscriptCorrectionKeepsOriginalEvidenceAndDurableUndo"),
        test_id("MeetingDetailUITests", "testTranscriptStructuralCorrectionsSplitMergeHideAndRestoreEvidence"),
    ),
    "meeting-translation": (
        test_id("MeetingTranscriptTranslationUITests", "testATranscriptIsTranslatedOnRequestAndTheOriginalStaysOneClickAway"),
    ),
    "settings-navigation": (
        test_id("SettingsUITests", "testLanguageToggleSwitchesVisibleTextWithoutRelaunch"),
        test_id("SettingsUITests", "testCategoryNavigationRevealsEachPane"),
    ),
    "settings-integrations": (
        test_id("CommandLineToolUITests", "testIntegrationsInstallsAndRemovesTheCommandLineToolLink"),
    ),
    "settings-skills": (
        test_id("SkillsSettingsUITests", "testProposedSkillReviewReturnsToItsMeetingWithoutRunning"),
        test_id("SkillsSettingsUITests", "testSkillsPaneControlsOffersAndShowsTheConfirmedReceipt"),
    ),
    "settings-standing-skills": (
        test_id("SkillsSettingsUITests", "testAutomaticBriefRuleRecoversAndKeepsInspectableHistory"),
    ),
    "settings-transfer": (
        test_id("SettingsTransferUITests", "testPortablePreferencesReviewCancelApplyAndLiveLanguage"),
    ),
    "settings-data": (
        test_id("SettingsUITests", "testSyncPaneKeepsOptInAndExistingLibrarySeparate"),
        test_id("SettingsUITests", "testDataPaneExportsARedactedSupportFileAndAReadableBackup"),
    ),
    "production-sync": (
        test_id("SettingsUITests", "testSyncPaneKeepsOptInAndExistingLibrarySeparate"),
    ),
    "settings-intelligence": (
        test_id("SettingsUITests", "testIntelligencePaneExplicitlyPreparesSemanticSearch"),
    ),
    "dictation": (
        test_id("DictationPolishUITests", "testPolishIsOfferedAsTheDefaultTextMode"),
        test_id("DictationCorrectionUITests", "testASpokenCorrectionChangesTheLastDictationInsteadOfPasting"),
        test_id("DictationCorrectionUITests", "testTheDictionaryGroupsEveryHeardFormUnderItsSpelling"),
        test_id("DictationPolishUITests", "testAPolishedDictationCanStillBePastedWithoutPolish"),
        test_id("DictationPolishUITests", "testPolishingCanBeSkippedToPasteTheCleanText"),
        test_id("DictationPolishUITests", "testARewriteThatChangesTheMeaningPastesCleanAndSaysWhy"),
        test_id("DictationPolishUITests", "testARecipeCanBeCreatedAndChosenAsTheDefault"),
        test_id("DictationPolishUITests", "testARecipeShapesTheDictationAndKeepsItsFacts"),
        test_id("DictationTranslationUITests", "testATranslatedDictationCanStillBePastedInTheOriginal"),
        test_id("DictationTranslationUITests", "testMissingLanguagesPasteTheOriginalAndSaySo"),
        test_id("DictationTranslationUITests", "testTranslatingCanBeSkippedToPasteTheOriginal"),
        test_id("DictationTranslationUITests", "testTranslationIsChosenInSettingsWithTheLanguageStatus"),
        test_id("DictationTextModeUITests", "testApplicationProfileUsesNativePickerAndKeepsTheOriginal"),
        test_id("DictationTextModeUITests", "testCorruptProfilesShowAnExplicitResetWithoutChangingTheDefault"),
        test_id("DictationTextModeUITests", "testSessionModeOverrideCancelsAndRestartsWithoutChangingDefaults"),
        test_id("DictationUITests", "testDeliveredDictationDistinguishesDispatchFromVerification"),
        test_id("DictationUITests", "testSilentDictationIsOfferedToCopyInsteadOfPasted"),
        test_id("DictationUITests", "testStreamingDictationKeepsClosedRowsThroughCancellationAndRestart"),
        test_id("DictationUITests", "testClipboardBorrowRestoresRichPrivateContentAndKeepsTextInRecovery"),
        test_id("DictationUITests", "testDictationSourceEOFBeforeStopIsVisibleAndCanRestart"),
        test_id("DictationUITests", "testDictationCaptureFailureIsVisibleAndCanBeDismissed"),
        test_id("DictationUITests", "testDictationPanelCancelsAndRestartsWithoutGlobalInput"),
        test_id("DictationUITests", "testMicrophoneDenialRemainsRecoverableWithoutOpeningAudio"),
        test_id("DictationUITests", "testMissingMicrophoneAudioShowsFallbackAndAllowsRestart"),
        test_id("DictationUITests", "testPreparingDictationCanCancelWithoutAListeningClaim"),
        test_id("DictationUITests", "testLoadingModelLooksDifferentFromDictating"),
        test_id("DictationUITests", "testCompactIndicatorShowsOnlyTheLevelAndTime"),
        test_id("DictationUITests", "testCompactIndicatorOpensTheFullPanelForAFailure"),
        test_id("DictationUITests", "testUnverifiedNoticeClosesWithItsCloseButton"),
        test_id("DictationUITests", "testCompactIndicatorCanBeDraggedWhileDictating"),
        test_id("DictationUITests", "testUndeliveredTextCanBeCopiedAndExplicitlyRetried"),
        test_id("DictationUITests", "testUndeliveredTextSurvivesAnotherTriggerUntilDiscarded"),
        test_id("DictationPracticeUITests", "testOnboardingDictationStepPracticesInItsOwnFieldWithoutTheClipboard"),
        test_id("DictationPracticeUITests", "testOnboardingDictationStepOffersShortcutAndAccessibilityOnceTurnedOn"),
        test_id("DictationPracticeUITests", "testSettingsPracticeFieldReceivesDictationWithoutTheClipboard"),
        test_id("DictationHistoryUITests", "testHistoryStartsOffAndTurnsOnFromTheDictationsPage"),
        test_id("DictationHistoryUITests", "testSavedDictationsCanBeDeletedOneByOneOrAll"),
        test_id("DictationHistoryUITests", "testADictationSavedToHistorySaysSoInsteadOfNothingWasSaved"),
        test_id("DictationHistoryUITests", "testSettingsAskForHistoryConsentWithEverySwitchOff"),
        test_id("DictationHistoryUITests", "testSearchAndFiltersNarrowTheHistory"),
        test_id("DictationHistoryUITests", "testADictationCanBeAddedToAMeetingsNotes"),
        test_id("DictationHistoryUITests", "testAskAboutDictationsCitesAndOpensTheDictation"),
        test_id("DictationHistoryUITests", "testStatisticsSummarizeTheWeekWithoutTheHistory"),
        test_id("DictationHistoryUITests", "testStatisticsStartOffAndTurnOnFromSettings"),
        test_id("AutomationUITests", "testOpenDictationsShortcutShowsItsSearch"),
        test_id("SelectionRewriteUITests", "testRewriteSelectionPreviewsBeforeReplacing"),
        test_id("SelectionRewriteUITests", "testARecipeRewriteIsNeverPastedOverAChangedSelection"),
        test_id("SelectionRewriteUITests", "testRewritingWithoutASelectionExplainsWhatToDo"),
        test_id("SelectionRewriteUITests", "testSayingHowRewritesTheSelectionWithTheSpokenInstruction"),
        test_id("SettingsUITests", "testAppleSpeechInspectionFailureOffersExplicitRetry"),
        test_id("SettingsUITests", "testAppleSpeechNeedsExplicitAssetsForEachLiveWorkflow"),
        test_id("SettingsUITests", "testParakeetUltraIsAnExplicitDictationOnlyDownload"),
        test_id("SettingsUITests", "testAnUltraDownloadInFlightCanBeCancelled"),
        test_id("SettingsUITests", "testDictationOffersTriggersLanguageAndDictionary"),
        test_id("SettingsUITests", "testHeldFnTriggerExplainsTheGlobeKeySetting"),
        test_id("SettingsUITests", "testDictationRecoversShortcutConflictAndRefreshesHelp"),
        test_id("SettingsUITests", "testDictationRepairsCorruptShortcutWithoutLeavingSettings"),
    ),
    "settings-audio": (
        test_id("SettingsUITests", "testAudioPaneOffersCaptureSourceControls"),
    ),
    "settings-voice": (
        test_id("SettingsUITests", "testUnreadableVoiceStorageStaysVisibleAndOffersExplicitRecovery"),
    ),
}

# Unit tests or a later journey own these contracts: they run every night, and on a
# pull request only when the diff edits the method itself.
NIGHTLY_ONLY_TESTS = (
    test_id("AudioImportUITests", "testCancelOneImportContinuesTheNextAndExplicitRetryReusesTheQueue"),
    test_id("AudioImportUITests", "testMultipleAudioFilesReachPagedQueueAndOpenTheirMeeting"),
    test_id("AutomationUITests", "testAppEntitiesOpenExactVisibleDestinations"),
    test_id("CommandLineToolUITests", "testABuildWithoutTheToolSaysSo"),
    test_id("CommitmentRadarUITests", "testFieldQualityObservesARealReviewWithoutAutomatingDecisions"),
    test_id("CommitmentRadarUITests", "testReminderDraftRequiresExplicitAccessAndLeavesDurableReceipt"),
    test_id("LibraryUITests", "testAskConfirmedMemoryLoadsAllTopicJobsAndExactCitations"),
    test_id("LibraryUITests", "testAskConfirmedMemoryLoadsPersonCommitmentsBlockersAndBothCitations"),
    test_id("LibraryUITests", "testLiveTranslationUsesADistinctLabeledRail"),
    test_id("LibraryUITests", "testPrivacyChipOpensTheActivityLogInYourData"),
    test_id("LibraryUITests", "testRecordingWarnsWhenIncomingAudioClips"),
    test_id("LibraryUITests", "testUnansweredCallEndedQuestionStopsTheRecording"),
    test_id("MeetingDetailUITests", "testAISuggestionsCanBeIgnoredAndPlaybackOffersClearMix"),
    test_id("MeetingDetailUITests", "testCompactTranscriptCorrectionCanReachItsOwnAction"),
    test_id("MeetingDetailUITests", "testCorrectedTranscriptMarksDerivedArtifactsStale"),
    test_id("MeetingDetailUITests", "testDecisionCanBeConfirmedAboutATopic"),
    test_id("MeetingDetailUITests", "testEmailRecapSkillPreviewsAndHandsOffWithoutSending"),
    test_id("MeetingDetailUITests", "testFailedSkillEffectRetriesItsOriginalProposal"),
    test_id("MeetingDetailUITests", "testFiveThousandSegmentDetailRendersFromDisposableScaleFixture"),
    test_id("MeetingDetailUITests", "testFreshQualifyingMeetingShowsThePostMeetingMirror"),
    test_id("MeetingDetailUITests", "testMostRecentRecipeRemainsVisibleAfterReload"),
    test_id("MeetingDetailUITests", "testNoAppleIntelligenceApuntadorRefreshPreservesStaleAnswers"),
    test_id("MeetingDetailUITests", "testRegenerateMenuOffersEveryDetailLevel"),
    test_id("MeetingDetailUITests", "testSecretGistSkillPreviewsPublishesAndReceiptsExactDocument"),
    test_id("MeetingDetailUITests", "testSummaryFeedbackIsExplicitReversibleAndLocal"),
    test_id("MeetingDetailUITests", "testUnnamedSpeakerOffersExplicitNameSuggestions"),
    test_id("MeetingTranscriptTranslationUITests", "testAnExportCanUseTheCurrentTranslation"),
    test_id("MeetingTranscriptTranslationUITests", "testMissingLanguagesPointToTheirDownload"),
    test_id("RecordingAssistUITests", "testCompanionActionsKeepIdentityAndSeenStateAfterReentry"),
    test_id("RecordingAssistUITests", "testLiveAssistKeepsOnePanelOpenAndABoundedCardList"),
    test_id("RecordingInputUITests", "testFailedRemovalKeepsTheAcceptedNoteUntilDiscardOrRetry"),
    test_id("RecordingInputUITests", "testFailedWriteRetainsInputAndStopWaitsForAnExplicitRetry"),
    test_id("RecordingInputUITests", "testStopDrainsAnAdmittedWriteBeforeFinalizingTheRecording"),
    test_id("SettingsTransferUITests", "testUnsupportedPreferencesRemainRecoverableWithoutMutation"),
    test_id("SettingsUITests", "testIntelligencePaneCreatesACustomStructure"),
    test_id("SettingsUITests", "testLocalDataLedgerShowsExactCountsAndHonestNetworkPolicy"),
    test_id("SettingsUITests", "testVoicePaneOffersTheMirrorOptIn"),
    test_id("SkillsSettingsUITests", "testAutomaticBriefCancellationFailureRequiresVerifiedReload"),
    test_id("SkillsSettingsUITests", "testProposedSkillDismissalRetiresTheDurableOfferEverywhere"),
    test_id("SkillsSettingsUITests", "testRecoverableFailedSkillReturnsToItsMeetingWithoutRunning"),
    test_id("SkillsSettingsUITests", "testSameSkillProposalsHaveDistinctAccessibleActions"),
    test_id("SkillsSettingsUITests", "testSkillActivityHidesExpansionWhenExactlyOnePageExists"),
    test_id("SkillsSettingsUITests", "testSkillActivityScopeFailureDoesNotInventRowsOrDisableVerifiedPolicy"),
    test_id("SkillsSettingsUITests", "testSkillProposalFailureDoesNotInventOffersOrDisableVerifiedPolicy"),
    test_id("SkillsSettingsUITests", "testSkillReceiptRestoresKeyboardFocusAndPassesAccessibilityAudit"),
    test_id("SkillsSettingsUITests", "testSkillsPaneFailsClosedWhenDurablePolicyCannotLoad"),
    test_id("SkillsSettingsUITests", "testSuggestedActionsExplainReviewFirstSafety"),
    test_id("SkillsSettingsUITests", "testWaitingReceiptIgnoresUnavailablePolicyAndReviewsSourceWithoutRunning"),
    test_id("SkillsSettingsUITests", "testWaitingSkillApprovalCanBeRevokedBeforeHandoff"),
    test_id("UITestStorageUITests", "testSharedScratchProtectsOwnershipAndRoundTripsAppFixtures"),
)

# Screenshot generators for the public site, run by `make public-screenshots`; they prove nothing new.
ON_DEMAND_TESTS = (
    test_id("PublicShowcaseUITests", "testInsightsShowcase"),
    test_id("PublicShowcaseUITests", "testLiveTranslationShowcase"),
    test_id("PublicShowcaseUITests", "testMeetingDetailShowcase"),
    test_id("PublicShowcaseUITests", "testTodayShowcase"),
)

# Tests in a pull request's reach: edited nightly-only methods join these.
PR_TESTS = tuple(dict.fromkeys(test for tests in FEATURE_TESTS.values() for test in tests))
ALL_TESTS = tuple(dict.fromkeys((*PR_TESTS, *NIGHTLY_ONLY_TESTS)))
# Needs a user-granted Accessibility decision; run only via test-ui-native-dictation.
PERMISSION_GATED_TESTS = frozenset({
    test_id("DictationUITests", "testNativeInserterUsesDisposableReceiverAndClipboard"),
    test_id("DictationUITests", "testNativeControllerModeChoicePreservesReceiverAndClipboard"),
})
ALL_FEATURES = frozenset(FEATURE_TESTS)
MEETING_FEATURES = frozenset(
    feature
    for feature in ALL_FEATURES
    if feature.startswith("meeting-") and feature != "meeting-brief"
)
# Every pull request that touches the product runs these: launch, recovery, clean and failed capture
# through relaunch, live captions, search and Ask, meeting review, Settings and the menu bar.
SMOKE_TESTS = (
    test_id("LibraryUITests", "testLibraryRendersRecordButtonAndActionChips"),
    test_id("LibraryUITests", "testDatabaseLaunchFailureOffersSafeRecovery"),
    test_id("LibraryUITests", "testCaptureFailureSurvivesStopAndRelaunchWithPlayablePrefix"),
    test_id("LibraryUITests", "testCleanStopReachesAReadyMeetingWithItsTranscriptAndPlayer"),
    test_id("LibraryUITests", "testOwnedTokenPreviewRetiresWithoutEnteringCanonicalCaption"),
    test_id("LibraryUITests", "testCommandPaletteSearchAnswerAndCitationSurviveNoStaleState"),
    test_id("MeetingDetailUITests", "testMeetingReviewSurfacesRemainCompleteAndActionable"),
    test_id("SettingsUITests", "testLanguageToggleSwitchesVisibleTextWithoutRelaunch"),
    test_id("SettingsUITests", "testSyncPaneKeepsOptInAndExistingLibrarySeparate"),
    test_id("MenuBarUITests", "testPreMeetingBriefMovesFromExactProposalToDurableReceipt"),
)

# Journeys that depend on the harness's app handoffs: isolated scratch, owned exit,
# the import picker fixture, the feature handshake, the web fixture and a seeded
# scale fixture. Each failed when the launch mode broke them while SMOKE stayed green.
HARNESS_SELF_TESTS = (
    test_id("UITestStorageUITests", "testSharedScratchProtectsOwnershipAndRoundTripsAppFixtures"),
    test_id("AudioImportUITests", "testSingleMeetingBundleReachesDetailWithoutChangingTheOriginal"),
    test_id("LibraryUITests", "testAskConversationAnswersAndSeeksToExactCitation"),
    test_id("MeetingDetailUITests", "testTwentyThousandSegmentDetailRendersFromDisposableScaleFixture"),
)

# Journeys that reach a resolved dependency. Hosted UI journeys script their
# engines, so these prove the surface still links and renders, not the engine.
# A pin missing here is a scope the selector reports as unknown.
_SUMMARY_MODEL_FEATURES = frozenset({"meeting-summary", "settings-intelligence"})
DEPENDENCY_FEATURES: dict[str, frozenset[str]] = {
    "fluidaudio": frozenset({"recording-recovery", "settings-audio", "settings-voice"}),
    "grdb.swift": frozenset({"launch-recovery", "library", "settings-data"}),
    "mlx-swift": _SUMMARY_MODEL_FEATURES,
    "secreteo": frozenset({"dictation"}),
    "mlx-swift-lm": _SUMMARY_MODEL_FEATURES,
    "sparkle": frozenset({"main-shell", "settings-navigation"}),
    "swift-huggingface": _SUMMARY_MODEL_FEATURES,
    "swift-jinja": _SUMMARY_MODEL_FEATURES,
    "swift-transformers": _SUMMARY_MODEL_FEATURES,
    "whisperkit": frozenset({"meeting-processing", "settings-audio"}),
}

# Journeys outside the meeting features that also open Meeting Detail.
MEETING_DETAIL_EXTRA_JOURNEYS = (
    test_id("AudioImportUITests", "testSingleMeetingBundleReachesDetailWithoutChangingTheOriginal"),
    test_id("AutomationUITests", "testOpenDictationsShortcutShowsItsSearch"),
    test_id("CommitmentRadarUITests", "testReviewThenConfirmedWorkKeepTheirFiltersAndOpenExactSources"),
    test_id("DictationHistoryUITests", "testADictationCanBeAddedToAMeetingsNotes"),
    test_id("LibraryUITests", "testActiveRecordingRemainsReachableAfterBrowsingTheLibrary"),
    test_id("LibraryUITests", "testAskConfirmedMemoryLoadsPersonCommitmentsBlockersAndBothCitations"),
    test_id("LibraryUITests", "testLaunchRecoversInterruptedStagingAudio"),
)

# Budget rank among equally edited tests: 0 data safety and capture, 1 core journey, 2 secondary.
FEATURE_TIERS: dict[str, int] = {
    "ask": 1,
    "audio-imports": 2,
    "automation-entry": 1,
    "background-work": 1,
    "commitment-radar": 1,
    "home": 1,
    "insights": 2,
    "launch-recovery": 0,
    "library": 0,
    "live-assist": 0,
    "main-shell": 1,
    "meeting-audio": 1,
    "meeting-brief": 2,
    "meeting-commitments": 1,
    "meeting-correction": 0,
    "meeting-evidence": 1,
    "meeting-export": 2,
    "meeting-health": 2,
    "meeting-naming": 2,
    "meeting-performance": 2,
    "meeting-processing": 1,
    "meeting-recap": 2,
    "meeting-skills": 2,
    "meeting-summary": 2,
    "meeting-translation": 2,
    "menu-bar-brief": 2,
    "onboarding": 1,
    "production-sync": 2,
    "recording-interview": 2,
    "recording-recovery": 0,
    "settings-audio": 2,
    "settings-data": 0,
    "settings-integrations": 2,
    "settings-intelligence": 2,
    "settings-navigation": 1,
    "settings-skills": 2,
    "settings-standing-skills": 2,
    "settings-transfer": 2,
    "settings-voice": 2,
}

# What a 9:30 job typically leaves for tests after a view change. The canaries must fit it, and
# --budget dry-runs it; xcodebuild adds about 46 s plus 0.22 s a test.
UI_TEST_BUDGET_SECONDS = 300.0
# A pull request's UI job; after the build, its candidates get what remains of this.
UI_JOB_BUDGET_SECONDS = 570.0
UI_JOB_TEARDOWN_SECONDS = 15.0
UI_TEST_OVERHEAD_SECONDS = 46.0
UI_TEST_OVERHEAD_PER_TEST_SECONDS = 0.22

RETIRED_DUPLICATE_TESTS = frozenset({
    test_id("LibraryUITests", "testAskConfirmedMemoryLoadsExactTopicDecisionsAndEvidence"),
    test_id("LibraryUITests", "testAskConfirmedMemoryLoadsExactTopicFirstDiscussionAndEvidence"),
    test_id("LibraryUITests", "testAskConfirmedMemoryLoadsExactTopicDecisionConflictsAndEvidence"),
    test_id("LibraryUITests", "testAskConfirmedMemoryLoadsExactTopicChangesSinceMeetingAndEvidence"),
    test_id("LibraryUITests", "testAskConfirmedMemoryLoadsExactPersonCommitmentsAndEvidence"),
    test_id("LibraryUITests", "testAskConfirmedMemoryLoadsExactCommitmentBlockersAndEvidence"),
    test_id("SkillsSettingsUITests", "testSkillActivityRefreshPreservesTheExpandedCurrentScope"),
    test_id("SkillsSettingsUITests", "testSkillActivityExpandsOlderRunsOnlyAfterExplicitRequest"),
    test_id("InsightsUITests", "testInsightsRendersHeatmap"),
    test_id("InsightsUITests", "testInsightsShowsWhoYouTalkWith"),
    test_id("OnboardingUITests", "testOpensOnTheFirstListenStep"),
    test_id("OnboardingUITests", "testContinueAdvancesPastTheFirstListen"),
    test_id("OnboardingUITests", "testVoiceStepOffersLocalEnrollmentWithoutStartingCapture"),
    test_id(
        "SkillsSettingsUITests",
        "testSkillActivityFiltersExactSkillAndResetsExpansion",
    ),
    test_id("HomeUITests", "testTodayShowsAgendaOpenWorkAndRecentMeetingsAboveTheFold"),
    test_id("HomeUITests", "testTodayAsksAndRecordsWithoutTyping"),
    test_id("SettingsUITests", "testDataPaneExportsARedactedLocalSupportFile"),
    test_id("SettingsUITests", "testDataPaneExportsAReadableWholeLibraryMarkdownBackup"),
    test_id("MeetingDetailUITests", "testClipMarkingRevealsExport"),
    test_id("MeetingDetailUITests", "testClickingALineOfTextJumpsThere"),
    test_id("MeetingDetailUITests", "testPlayerExposesSkipAndOnlyMyVoice"),
    test_id("CommitmentRadarUITests", "testReviewQueueKeepsSuggestionsSeparateAndOpensExactEvidence"),
    test_id("CommitmentRadarUITests", "testRadarFiltersConfirmedWorkAndOpensItsExactSourceMeeting"),
    test_id("MeetingDetailUITests", "testAbandonedAutomaticSummarySaysSoBesideGeneration"),
    test_id("MeetingDetailUITests", "testStructureMenuOffersSeededTemplates"),
    test_id("RecordingAssistUITests", "testBatchedObjectivesRevealLastArrivalAndReplacementCountsAsUnread"),
    test_id("SettingsUITests", "testDataPaneCreditsTheOnDeviceModels"),
    test_id("SkillsSettingsUITests", "testFailedProposedSkillDismissalKeepsTheOfferAndAllowsRetry"),
    test_id("SkillsSettingsUITests", "testFailedProposedSkillReviewKeepsTheOfferAndAllowsRetry"),
    test_id("SkillsSettingsUITests", "testFailedRecoveryResolutionKeepsTheReceiptAndAllowsRetry"),
    test_id("SkillsSettingsUITests", "testFailedSkillControlMutationReloadsWithoutClosingSettings"),
    test_id("SkillsSettingsUITests", "testFailedSourceContextResolutionKeepsReceiptAndAllowsRetry"),
    test_id("SkillsSettingsUITests", "testFailedWaitingSkillRevocationKeepsTheReceiptAndRetry"),
    test_id("SkillsSettingsUITests", "testSkillActivityFiltersByUpdatePeriodAndResetsExpansion"),
    test_id("SkillsSettingsUITests", "testSkillActivityTransitionsHideStaleRowsAndKeepVerifiedControlsUsable"),
})

# One checked-in production owner per scope makes feature-to-test and
# changed-file-to-feature ownership executable. A new scope without a live
# owner is an orphan; a renamed owner that falls through to the broad default
# no longer silently validates the catalog.
FEATURE_SOURCE_SENTINELS: dict[str, str] = {
    "live-assist": "Sources/portavoz-app/LiveAssistValidationRunner.swift",
    "launch-recovery": "Sources/portavoz-app/AppLaunchRecoveryView.swift",
    "background-work": "Sources/portavoz-app/BackgroundWorkCenterView.swift",
    "automation-entry": "Sources/portavoz-app/PortavozAppIntents.swift",
    "home": "Sources/portavoz-app/HomeView.swift",
    "library": "Sources/portavoz-app/LibraryView.swift",
    "audio-imports": "Sources/portavoz-app/AudioImportQueueView.swift",
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
    "meeting-translation": "Sources/portavoz-app/MeetingTranscriptTranslationControls.swift",
    "settings-navigation": "Sources/portavoz-app/SettingsView.swift",
    "settings-skills": "Sources/portavoz-app/SkillsSettingsSection.swift",
    "settings-integrations": "Sources/portavoz-app/CommandLineToolSection.swift",
    "settings-standing-skills": "Sources/portavoz-app/StandingSkillRulesSection.swift",
    "settings-data": "Sources/portavoz-app/AppServices+MeetingSync.swift",
    "settings-transfer": "Sources/portavoz-app/SettingsTransferSection.swift",
    "production-sync": "Sources/portavoz-app/ProductionSyncQualificationRunner.swift",
    "settings-intelligence": "Sources/portavoz-app/SemanticSearchPreparationModel.swift",
    "dictation": "Sources/portavoz-app/DictationController.swift",
    "settings-audio": "Sources/portavoz-app/AudioSection.swift",
    "settings-voice": "Sources/portavoz-app/SettingsVoiceSection.swift",
}
