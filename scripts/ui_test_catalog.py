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
        test_id("UITestStorageUITests", "testSharedScratchProtectsOwnershipAndRoundTripsAppFixtures"),
        test_id(
            "LibraryUITests",
            "testDatabaseLaunchFailureOffersSafeRecovery",
        ),
    ),
    "background-work": (
        test_id(
            "BackgroundWorkUITests",
            "testBackgroundWorkCenterShowsAllOwnersAndRecoversExactFailures",
        ),
        test_id(
            "BackgroundWorkUITests",
            "testRecordingDefersDerivedWorkAndStopResumesIt",
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
        test_id("AutomationUITests", "testOpenDictationsShortcutShowsItsSearch"),
    ),
    "home": (
        test_id("HomeUITests", "testTodayShowsAgendaOpenWorkAndRecentMeetingsAboveTheFold"),
        test_id("HomeUITests", "testTodayAsksAndRecordsWithoutTyping"),
    ),
    "library": (
        test_id("LibraryUITests", "testLibraryRendersRecordButtonAndActionChips"),
        test_id("LibraryUITests", "testPrivacyChipOpensTheActivityLogInYourData"),
        test_id("LibraryUITests", "testSeededMeetingsGroupByRecency"),
        test_id("LibraryUITests", "testActiveRecordingRemainsReachableAfterBrowsingTheLibrary"),
    ),
    "audio-imports": (
        test_id("AudioImportUITests", "testSingleMeetingBundleReachesDetailWithoutChangingTheOriginal"),
        test_id("AudioImportUITests", "testMultipleAudioFilesReachPagedQueueAndOpenTheirMeeting"),
        test_id("AudioImportUITests", "testCancelOneImportContinuesTheNextAndExplicitRetryReusesTheQueue"),
        test_id("AudioImportUITests", "testRelaunchResumesPublishedAudioWithoutTheSelectedOriginals"),
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
        test_id("LibraryUITests", "testCaptureFailureSurvivesStopAndRelaunchWithPlayablePrefix"),
        test_id("LibraryUITests", "testRecordingStartFailureOffersTypedRecovery"),
        test_id("LibraryUITests", "testRecordingWarnsWhenRemoteAudioCallbacksStop"),
        test_id("LibraryUITests", "testRecordingWarnsWhenIncomingAudioClips"),
        test_id("LibraryUITests", "testRecordingAsksWhetherTheCallEndedAndKeepsRecording"),
        test_id("LibraryUITests", "testUnansweredCallEndedQuestionStopsTheRecording"),
        test_id("LibraryUITests", "testColdRecordingStartsLiveCaptionsWhenModelBecomesReady"),
        test_id("LibraryUITests", "testLiveTranscriptYieldsFollowWhileReadingHistory"),
        test_id("LibraryUITests", "testOwnedTokenPreviewRetiresWithoutEnteringCanonicalCaption"),
        test_id("LibraryUITests", "testLiveTranslationUsesADistinctLabeledRail"),
        test_id("LibraryUITests", "testRecordingOffersObjectivesNextQuestionAndTalkBalance"),
        test_id("LibraryUITests", "testLaunchRecoversInterruptedStagingAudio"),
        test_id("LibraryUITests", "testLaunchResumesDurablePostCaptureProcessing"),
    ),
    "live-assist": (
        test_id(
            "LibraryUITests",
            "testRecordingOffersObjectivesNextQuestionAndTalkBalance",
        ),
        test_id("RecordingInputUITests", "testStopDrainsAnAdmittedWriteBeforeFinalizingTheRecording"),
        test_id("RecordingInputUITests", "testAcceptedNotesAndObjectivesSurviveTerminationAndRecovery"),
        test_id("RecordingInputUITests", "testFailedWriteRetainsInputAndStopWaitsForAnExplicitRetry"),
        test_id("RecordingInputUITests", "testFailedRemovalKeepsTheAcceptedNoteUntilDiscardOrRetry"),
        test_id(
            "RecordingAssistUITests",
            "testLiveAssistKeepsOnePanelOpenAndABoundedCardList",
        ),
        test_id(
            "RecordingAssistUITests",
            "testCompanionActionsKeepIdentityAndSeenStateAfterReentry",
        ),
        test_id(
            "RecordingAssistUITests",
            "testLatestManualAssistRequestOwnsTheFocusSlot",
        ),
        test_id(
            "RecordingAssistUITests",
            "testBatchedObjectivesRevealLastArrivalAndReplacementCountsAsUnread",
        ),
        test_id(
            "RecordingAssistUITests",
            "testUnsubmittedNotesAndObjectivesSurviveTabsAndLibraryBrowsing",
        ),
        test_id(
            "MeetingDetailUITests",
            "testNoAppleIntelligenceSummaryFailureOpensExactSetupAndExplainsApuntador",
        ),
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
            "testAskConfirmedMemoryLoadsPersonCommitmentsBlockersAndBothCitations",
        ),
        test_id("LibraryUITests", "testAskConfirmedMemoryLoadsAllTopicJobsAndExactCitations"),
        test_id("LibraryUITests", "testCommandPaletteSearchAnswerAndCitationSurviveNoStaleState"),
        test_id("DictationHistoryUITests", "testAskAboutDictationsCitesAndOpensTheDictation"),
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
        test_id(
            "MeetingDetailUITests",
            "testMeetingReviewSurfacesRemainCompleteAndActionable",
        ),
        test_id("OnboardingUITests", "testAdvancesFromFirstListenToLocalVoiceEnrollment"),
        test_id(
            "CommitmentRadarUITests",
            "testRadarFiltersConfirmedWorkAndOpensItsExactSourceMeeting",
        ),
    ),
    "onboarding": (
        test_id("OnboardingUITests", "testAdvancesFromFirstListenToLocalVoiceEnrollment"),
        test_id("OnboardingUITests", "testModelFailureCanContinueBackAndRetryWithoutDownloading"),
        test_id("DictationPracticeUITests", "testOnboardingDictationStepPracticesInItsOwnFieldWithoutTheClipboard"),
        test_id("DictationPracticeUITests", "testOnboardingDictationStepOffersShortcutAndAccessibilityOnceTurnedOn"),
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
        test_id("MeetingDetailUITests", "testAConfidentVoiceMatchNamesTheSpeakerAndCanBeUndone"),
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
        test_id("MeetingDetailUITests", "testNoAppleIntelligenceSummaryFailureOpensExactSetupAndExplainsApuntador"),
        test_id("MeetingDetailUITests", "testRunningRefineCanBeCanceledWithoutChangingTheTranscript"),
    ),
    "meeting-summary": (
        test_id(
            "MeetingDetailUITests",
            "testMeetingReviewSurfacesRemainCompleteAndActionable",
        ),
        test_id("MeetingDetailUITests", "testMostRecentRecipeRemainsVisibleAfterReload"),
        test_id("MeetingDetailUITests", "testStructureMenuOffersSeededTemplates"),
        test_id("MeetingDetailUITests", "testRegenerateMenuOffersEveryDetailLevel"),
    ),
    "meeting-evidence": (
        test_id(
            "MeetingDetailUITests",
            "testEvidenceSourcesJumpToTheirExactTranscriptAndAudio",
        ),
        test_id("MeetingDetailUITests", "testDecisionCanBeConfirmedAboutATopic"),
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
        test_id(
            "MeetingDetailUITests",
            "testMeetingReviewSurfacesRemainCompleteAndActionable",
        ),
        test_id("MeetingDetailUITests", "testFreshQualifyingMeetingShowsThePostMeetingMirror"),
    ),
    "meeting-audio": (
        test_id(
            "MeetingDetailUITests",
            "testAISuggestionsCanBeIgnoredAndPlaybackOffersClearMix"),
        test_id(
            "MeetingDetailUITests",
            "testEvidenceSourcesJumpToTheirExactTranscriptAndAudio",
        ),
        test_id("MeetingDetailUITests", "testPlayerExposesSkipAndOnlyMyVoice"),
        test_id("MeetingDetailUITests", "testClipMarkingRevealsExport"),
        test_id("MeetingDetailUITests", "testClickingALineOfTextJumpsThere"),
        test_id("MeetingAudioTrimUITests", "testSilentTailRequiresConfirmationAndCutsOnlyAfterConfirmation"),
    ),
    "meeting-correction": (
        test_id(
            "MeetingDetailUITests",
            "testCompactTranscriptCorrectionCanReachItsOwnAction",
        ),
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
            "testNoAppleIntelligenceApuntadorRefreshPreservesStaleAnswers",
        ),
    ),
    "meeting-translation": (
        test_id(
            "MeetingTranscriptTranslationUITests",
            "testATranscriptIsTranslatedOnRequestAndTheOriginalStaysOneClickAway",
        ),
        test_id("MeetingTranscriptTranslationUITests", "testMissingLanguagesPointToTheirDownload"),
        test_id("MeetingTranscriptTranslationUITests", "testAnExportCanUseTheCurrentTranslation"),
    ),
    "settings-navigation": (
        test_id("SettingsUITests", "testCategoryNavigationRevealsEachPane"),
        test_id("SettingsUITests", "testLanguageToggleSwitchesVisibleTextWithoutRelaunch"),
    ),
    "settings-integrations": (
        test_id("CommandLineToolUITests", "testIntegrationsInstallsAndRemovesTheCommandLineToolLink"),
        test_id("CommandLineToolUITests", "testABuildWithoutTheToolSaysSo"),
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
            "testSkillActivityHidesExpansionWhenExactlyOnePageExists",
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
    "settings-standing-skills": (
        test_id(
            "SkillsSettingsUITests",
            "testAutomaticBriefCancellationFailureRequiresVerifiedReload",
        ),
        test_id(
            "SkillsSettingsUITests",
            "testAutomaticBriefRuleRecoversAndKeepsInspectableHistory",
        ),
    ),
    "settings-transfer": (
        test_id("SettingsTransferUITests", "testPortablePreferencesReviewCancelApplyAndLiveLanguage"),
        test_id("SettingsTransferUITests", "testUnsupportedPreferencesRemainRecoverableWithoutMutation"),
    ),
    "settings-data": (
        test_id("SettingsUITests", "testLocalDataLedgerShowsExactCountsAndHonestNetworkPolicy"),
        test_id("SettingsUITests", "testSyncPaneKeepsOptInAndExistingLibrarySeparate"),
        test_id("SettingsUITests", "testDataPaneExportsARedactedLocalSupportFile"),
        test_id("SettingsUITests", "testDataPaneExportsAReadableWholeLibraryMarkdownBackup"),
        test_id("SettingsUITests", "testDataPaneCreditsTheOnDeviceModels"),
    ),
    "production-sync": (
        test_id("SettingsUITests", "testSyncPaneKeepsOptInAndExistingLibrarySeparate"),
    ),
    "settings-intelligence": (
        test_id(
            "SettingsUITests",
            "testIntelligencePaneExplicitlyPreparesSemanticSearch",
        ),
        test_id("SettingsUITests", "testAppleSpeechNeedsExplicitAssetsForEachLiveWorkflow"),
        test_id("SettingsUITests", "testAppleSpeechInspectionFailureOffersExplicitRetry"),
        test_id("SettingsUITests", "testIntelligencePaneCreatesACustomStructure"),
    ),
    "dictation": (
        test_id("DictationPolishUITests", "testPolishIsOfferedAsTheDefaultTextMode"),
        test_id("SelectionRewriteUITests", "testRewriteSelectionPreviewsBeforeReplacing"),
        test_id("SelectionRewriteUITests", "testARecipeRewriteIsNeverPastedOverAChangedSelection"),
        test_id("SelectionRewriteUITests", "testRewritingWithoutASelectionExplainsWhatToDo"),
        test_id("SelectionRewriteUITests", "testSayingHowRewritesTheSelectionWithTheSpokenInstruction"),
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
        test_id("SettingsUITests", "testAppleSpeechNeedsExplicitAssetsForEachLiveWorkflow"),
        test_id("SettingsUITests", "testAppleSpeechInspectionFailureOffersExplicitRetry"),
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
        test_id("SettingsUITests", "testDictationOffersTriggersLanguageAndDictionary"),
        test_id("SettingsUITests", "testDictationRecoversShortcutConflictAndRefreshesHelp"),
        test_id("SettingsUITests", "testDictationRepairsCorruptShortcutWithoutLeavingSettings"),
        test_id("SettingsUITests", "testHeldFnTriggerExplainsTheGlobeKeySetting"),
        test_id("SettingsUITests", "testParakeetUltraIsAnExplicitDictationOnlyDownload"),
        test_id("SettingsUITests", "testAnUltraDownloadInFlightCanBeCancelled"),
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
    ),
    "settings-audio": (
        test_id("SettingsUITests", "testAppleSpeechNeedsExplicitAssetsForEachLiveWorkflow"),
        test_id("SettingsUITests", "testAppleSpeechInspectionFailureOffersExplicitRetry"),
        test_id("SettingsUITests", "testAudioPaneOffersCaptureSourceControls"),
        test_id("SettingsUITests", "testDictationOffersTriggersLanguageAndDictionary"),
        test_id("SettingsUITests", "testDictationRecoversShortcutConflictAndRefreshesHelp"),
        test_id("SettingsUITests", "testDictationRepairsCorruptShortcutWithoutLeavingSettings"),
        test_id("SettingsUITests", "testHeldFnTriggerExplainsTheGlobeKeySetting"),
        test_id("SettingsUITests", "testParakeetUltraIsAnExplicitDictationOnlyDownload"),
        test_id("SettingsUITests", "testAnUltraDownloadInFlightCanBeCancelled"),
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
        test_id("PublicShowcaseUITests", "testTodayShowcase"),
    ),
}

ALL_TESTS = tuple(dict.fromkeys(test for tests in FEATURE_TESTS.values() for test in tests))
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
SETTINGS_FEATURES = frozenset(feature for feature in ALL_FEATURES if feature.startswith("settings-"))
# Canaries across the main surfaces: launch, Library, Today, recording, live
# assist, derived work, Meeting Detail, Ask, dictation, Settings, onboarding,
# Radar, Insights, the menu-bar brief and App Intents.
SMOKE_TESTS = (
    test_id("LibraryUITests", "testDatabaseLaunchFailureOffersSafeRecovery"),
    test_id("LibraryUITests", "testLibraryRendersRecordButtonAndActionChips"),
    test_id("HomeUITests", "testTodayShowsAgendaOpenWorkAndRecentMeetingsAboveTheFold"),
    test_id("LibraryUITests", "testRecordingStartFailureOffersTypedRecovery"),
    test_id("BackgroundWorkUITests", "testRecordingDefersDerivedWorkAndStopResumesIt"),
    test_id("MeetingDetailUITests", "testPlayerExposesSkipAndOnlyMyVoice"),
    test_id("MeetingDetailUITests", "testMostRecentRecipeRemainsVisibleAfterReload"),
    test_id("LibraryUITests", "testCommandPaletteSearchAnswerAndCitationSurviveNoStaleState"),
    test_id("DictationUITests", "testDeliveredDictationDistinguishesDispatchFromVerification"),
    test_id("SettingsUITests", "testLanguageToggleSwitchesVisibleTextWithoutRelaunch"),
    test_id("SettingsUITests", "testIntelligencePaneCreatesACustomStructure"),
    test_id("OnboardingUITests", "testAdvancesFromFirstListenToLocalVoiceEnrollment"),
    test_id("CommitmentRadarUITests", "testReminderAlertOpensCommitmentRadar"),
    test_id("InsightsUITests", "testInsightsShowsCompleteLocalDashboard"),
    test_id("AutomationUITests", "testOpenDictationsShortcutShowsItsSearch"),
    test_id("RecordingAssistUITests", "testLatestManualAssistRequestOwnsTheFocusSlot"),
    test_id("MenuBarUITests", "testPreMeetingBriefMovesFromExactProposalToDurableReceipt"),
)

# Journeys that depend on the harness's app handoffs: isolated scratch, owned exit,
# the import picker fixture, the feature handshake, the web fixture and a seeded
# scale fixture. Each failed when the launch mode broke them while SMOKE stayed green.
HARNESS_SELF_TESTS = (
    test_id("UITestStorageUITests", "testSharedScratchProtectsOwnershipAndRoundTripsAppFixtures"),
    test_id("AudioImportUITests", "testSingleMeetingBundleReachesDetailWithoutChangingTheOriginal"),
    test_id("SkillsSettingsUITests", "testSkillActivityTransitionsHideStaleRowsAndKeepVerifiedControlsUsable"),
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
    test_id("CommitmentRadarUITests", "testRadarFiltersConfirmedWorkAndOpensItsExactSourceMeeting"),
    test_id("CommitmentRadarUITests", "testReviewQueueKeepsSuggestionsSeparateAndOpensExactEvidence"),
    test_id("DictationHistoryUITests", "testADictationCanBeAddedToAMeetingsNotes"),
    test_id("LibraryUITests", "testActiveRecordingRemainsReachableAfterBrowsingTheLibrary"),
    test_id("LibraryUITests", "testAskConfirmedMemoryLoadsPersonCommitmentsBlockersAndBothCitations"),
    test_id("PublicShowcaseUITests", "testMeetingDetailShowcase"),
)

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
    "public-showcase": "Sources/portavoz-app/AppServices+Showcase.swift",
}
