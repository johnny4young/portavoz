import AppKit
import XCTest

/// Drives a seeded meeting to verify the redesigned detail view renders —
/// the automated stand-in for eyeballing it. Launches with `-seed-demo`
/// so the library has one deterministic meeting with a transcript, a
/// tabbed summary (with a coauthoring ▸ bullet under Decisiones), meeting
/// health, chapters, a content-free privacy receipt in the right rail, and a
/// player.
final class MeetingDetailUITests: PortavozUITestCase {
    @MainActor
    func testFiveThousandSegmentDetailRendersFromDisposableScaleFixture() {
        let app = XCUIApplication.portavoz(
            seedScale: true,
            scaleSegmentCount: 5_000)
        defer { app.terminate() }
        app.launchPortavoz()
        XCTAssertTrue(
            app.waitForSeedFixtureReady(timeout: 45),
            "the disposable 5,000-segment aggregate must finish before presentation checks")

        XCTAssertTrue(
            app.staticTexts["Scale baseline · 2 h · 5000 segments"]
                .waitForExistenceFast(timeout: 30),
            "the disposable 2-hour fixture must navigate to Meeting Detail")
        XCTAssertTrue(
            app.control(withIdentifier: "detail-transcript-title")
                .waitForExistenceFast(timeout: 10),
            "Meeting Detail must render first content for 5,000 segments")
        XCTAssertTrue(
            app.staticTexts["Scale baseline summary revision 1."]
                .waitForExistenceFast(timeout: 15),
            "the 5,000-segment detail must render its initial summary")
        XCTAssertTrue(
            app.control(withIdentifier: "detail-chapters").waitForExistenceFast(timeout: 10),
            "the scale detail must complete its chapter projection")
        attachScreenshot(of: app, named: "meeting-detail-scale-5000-segments")
    }

    @MainActor
    func testTwentyThousandSegmentDetailRendersFromDisposableScaleFixture() {
        let app = XCUIApplication.portavoz(
            seedScale: true,
            scaleSegmentCount: 20_000,
            scaleAutoSummaryUpdate: true)
        app.configureFeatureUITestHandshake(
            argument: "-scale-auto-summary-handshake",
            name: "scale-summary-20000",
            readyEnvironmentKey: "PORTAVOZ_UI_TEST_SCALE_SUMMARY_READY_PATH",
            continueEnvironmentKey: "PORTAVOZ_UI_TEST_SCALE_SUMMARY_CONTINUE_PATH")
        defer { app.terminate() }
        app.launchPortavoz()
        XCTAssertTrue(
            app.waitForSeedFixtureReady(timeout: 45),
            "the disposable 20,000-segment aggregate must finish before presentation checks")

        XCTAssertTrue(
            app.staticTexts["Scale baseline · 2 h · 20000 segments"]
                .waitForExistenceFast(timeout: 40),
            "the disposable 20,000-segment fixture must navigate to Meeting Detail")
        XCTAssertTrue(
            app.control(withIdentifier: "detail-transcript-title")
                .waitForExistenceFast(timeout: 15),
            "Meeting Detail must render first content for 20,000 segments")
        let generatedDocument = app.control(withIdentifier: "detail-generated-document")
        XCTAssertTrue(
            generatedDocument.waitForExistenceFast(timeout: 15),
            "the scale detail must expose one bounded generated-document surface")
        XCTAssertTrue(
            generatedDocument.staticTexts["Scale baseline summary revision 1."]
                .waitForExistenceFast(timeout: 15),
            "the first subscribed summary must render before the fixture updates it")
        XCTAssertTrue(
            app.continueFeatureUITestHandshake(
                readyEnvironmentKey: "PORTAVOZ_UI_TEST_SCALE_SUMMARY_READY_PATH",
                continueEnvironmentKey:
                    "PORTAVOZ_UI_TEST_SCALE_SUMMARY_CONTINUE_PATH"),
            "the test must release the summary update only after observing revision 1")
        XCTAssertTrue(
            app.control(withIdentifier: "detail-chapters").waitForExistenceFast(timeout: 15),
            "the 20,000-segment detail must complete its chapter projection")
        XCTAssertTrue(
            generatedDocument.staticTexts["Scale baseline summary revision 2."]
                .waitForExistenceFast(timeout: 15),
            "the 20,000-segment detail must stay subscribed to scoped summary updates")
    }

    @MainActor
    private func resetEvidenceNavigation(
        chapter: XCUIElement,
        playbackToggle: XCUIElement,
        citedRow: XCUIElement,
        currentTime: XCUIElement
    ) {
        XCTAssertTrue(
            chapter.waitForHittable(timeout: 5),
            "the stable opening chapter must be actionable before resetting evidence")
        chapter.click()
        XCTAssertTrue(
            playbackToggle.waitForHittable(timeout: 5),
            "playback must expose its stable toggle after the reset seek")
        playbackToggle.click()
        XCTAssertTrue(
            currentTime.waitForValueOtherThan("0:03", timeout: 5),
            "the reset must visibly leave the shared evidence timestamp")
        XCTAssertTrue(
            waitForUITestCondition(timeout: 5) {
                citedRow.exists && !citedRow.isSelected
            },
            "the reset must visibly deselect the shared evidence row")
    }

    /// Launches the app on the seeded meeting with isolated audio. Point
    /// PORTAVOZ_TEST_AUDIO_ROOT at a folder holding a REAL recording
    /// (Audio/<uuid>/…) to exercise the player on real audio instead.
    @MainActor
    private func launchOnSeededMeeting(
        latestRecipe: Bool = false,
        refineRunning: Bool = false,
        justRecorded: Bool = false,
        processingFailure: Bool = false,
        withoutSummary: Bool = false,
        staleDerived: Bool = false,
        commitmentInbox: Bool = false,
        simulateSequoiaCapabilities: Bool = false,
        unnamedSpeaker: Bool = false,
        aiSuggestions: Bool = false,
        abandonedSummary: Bool = false,
        simulateSkillEffectFailureOnce: Bool = false,
        simulateApuntadorRefreshSuccess: Bool = false,
        summaryEngine: String? = nil
    ) -> XCUIApplication {
        let app = XCUIApplication.portavoz(
            seedDemo: true,
            seedLatestRecipe: latestRecipe,
            seedRefineRunning: refineRunning,
            seedJustRecorded: justRecorded,
            seedProcessingFailure: processingFailure,
            seedWithoutSummary: withoutSummary,
            seedStaleDerived: staleDerived,
            seedCommitmentInbox: commitmentInbox,
            simulateSequoiaCapabilities: simulateSequoiaCapabilities,
            simulateSkillEffectFailureOnce: simulateSkillEffectFailureOnce,
            simulateApuntadorRefreshSuccess: simulateApuntadorRefreshSuccess)
        if justRecorded {
            app.launchArguments += ["-mirrorAfterMeeting", "true"]
        }
        if unnamedSpeaker {
            app.launchArguments.append("-seed-unnamed-speaker")
        }
        if aiSuggestions {
            app.launchArguments.append("-seed-ai-suggestions")
        }
        if abandonedSummary {
            app.launchArguments.append("-seed-abandoned-summary")
        }
        if let summaryEngine {
            app.launchArguments += ["-summaryEngine", summaryEngine]
        }
        app.launchEnvironment["PORTAVOZ_AUDIO_ROOT"] =
            ProcessInfo.processInfo.environment["PORTAVOZ_TEST_AUDIO_ROOT"]
            ?? (NSTemporaryDirectory() + "portavoz-uitest-\(UUID().uuidString)")
        app.launchPortavoz()
        XCTAssertTrue(
            app.waitForSeededLibraryToSettle(),
            "the complete seeded aggregate must settle before selecting it")
        // Select the real library row by structure, not the duplicated title
        // text (it also appears under To-dos and can point at a stale scroll
        // snapshot during rapid relaunches).
        let meeting = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'library-meeting-'"))
            .firstMatch
        // Existing isn't enough on the coldest launch: seeding bumps
        // the scoped observation, the list re-renders, and `click` re-resolves this
        // query — against a snapshot that can already be stale ("Failed to get
        // matching snapshot"). Waiting for hittable re-resolves until it settles.
        XCTAssertTrue(
            app.prepareForInteraction(),
            "Portavoz must own the foreground before selecting the seeded meeting")
        XCTAssertTrue(
            meeting.waitForStableFrame(timeout: 10),
            "the seeded meeting must settle after the app returns to the foreground")
        meeting.click()
        return app
    }

    @MainActor
    func testCorrectedTranscriptMarksDerivedArtifactsStale() {
        let app = launchOnSeededMeeting(staleDerived: true)
        defer { app.terminate() }

        XCTAssertTrue(
            app.control(withIdentifier: "detail-stale-summary")
                .waitForExistenceFast(timeout: 10),
            "a summary generated before the correction must be labelled stale")
        XCTAssertTrue(
            app.control(withIdentifier: "detail-stale-summary-regenerate")
                .waitForExistenceFast(timeout: 5),
            "the stale summary must expose explicit on-demand regeneration")
        XCTAssertFalse(
            app.buttons["detail-thin-summary-suggestion"].exists,
            "a stale summary must not compete with an unrelated thin-summary suggestion")
        XCTAssertTrue(
            app.control(
                withIdentifier:
                    "apuntador-card-B5F00000-0000-4000-8000-000000000002-stale")
                .waitForExistenceFast(timeout: 10),
            "an Apuntador answer generated before the correction must be labelled stale")
        XCTAssertTrue(
            app.buttons["detail-apuntador-refresh"].waitForExistenceFast(timeout: 5),
            "stale Apuntador answers must expose one explicit section refresh")
        XCTAssertFalse(
            app.control(
                withIdentifier:
                    "apuntador-card-B5F00000-0000-4000-8000-000000000002-answer-evidence-0")
                .exists,
            "stale evidence must not remain an actionable jump")
        attachScreenshot(of: app, named: "meeting-detail-stale-derived-artifacts")
    }

    @MainActor
    func testExplicitApuntadorRefreshUsesCorrectedTranscript() {
        let app = launchOnSeededMeeting(
            staleDerived: true,
            simulateApuntadorRefreshSuccess: true)
        defer { app.terminate() }

        let refresh = app.buttons["detail-apuntador-refresh"]
        XCTAssertTrue(
            refresh.waitForExistenceFast(timeout: 10),
            "the stale Apuntador snapshot must offer explicit regeneration")
        XCTAssertTrue(
            refresh.waitForStableFrame(timeout: 5),
            "the refresh control must settle before activation")
        refresh.click()

        XCTAssertTrue(
            app.staticTexts["El rollout corregido queda para el lunes."]
                .waitForExistenceFast(timeout: 10),
            "the refreshed answer must come from the corrected transcript projection")
        XCTAssertTrue(
            app.control(
                withIdentifier:
                    "apuntador-card-B5F00000-0000-4000-8000-000000000002-stale")
                .waitForDisappearance(timeout: 10),
            "the stale card must be replaced only after current publication succeeds")
        XCTAssertTrue(
            app.buttons["detail-apuntador-refresh"].waitForDisappearance(timeout: 10),
            "the refresh control must disappear once every card matches current corrections")
        attachScreenshot(of: app, named: "meeting-detail-apuntador-refreshed")
    }

    @MainActor
    func testSequoiaApuntadorRefreshPreservesStaleAnswers() {
        let app = launchOnSeededMeeting(
            staleDerived: true,
            simulateSequoiaCapabilities: true)
        defer { app.terminate() }

        let refresh = app.buttons["detail-apuntador-refresh"]
        XCTAssertTrue(
            refresh.waitForStableFrame(timeout: 10),
            "Sequoia must expose the explicit action without pretending it can run")
        refresh.click()

        let expectedError = UITestLocale.environmentLocale == "es"
            ? "Volver a comprobar las respuestas del Apuntador requiere macOS 26 y Apple Intelligence."
            : "Re-checking Apuntador answers requires macOS 26 and Apple Intelligence."
        XCTAssertTrue(
            app.staticTexts[expectedError].waitForExistenceFast(timeout: 10),
            "the unsupported OS must explain the exact model requirement")
        XCTAssertTrue(
            app.control(
                withIdentifier:
                    "apuntador-card-B5F00000-0000-4000-8000-000000000002-stale")
                .exists,
            "an unavailable provider must preserve the previous stale snapshot")
        XCTAssertTrue(
            app.buttons["detail-apuntador-refresh"].exists,
            "the explicit retry must remain available after an unavailable pass")
    }

    @MainActor
    func testTranscriptCorrectionKeepsOriginalEvidenceAndDurableUndo() {
        let app = launchOnSeededMeeting()
        defer { app.terminate() }

        let correct = app.buttons[
            "transcript-correct-B5B00000-0000-4000-8000-000000000002"]
        XCTAssertTrue(
            correct.waitForExistenceFast(timeout: 10),
            "a stable accepted source row must expose its correction action")
        let transcriptScroll = app.control(withIdentifier: "detail-transcript-scroll")
        XCTAssertTrue(
            correct.revealVertically(in: transcriptScroll, maxScrolls: 4),
            "the correction action must be fully visible before activation")
        let correctFrame = correct.frame
        XCTAssertGreaterThanOrEqual(
            correctFrame.width,
            28,
            "the correction action must expose a usable pointer target")
        XCTAssertGreaterThanOrEqual(
            correctFrame.height,
            28,
            "the correction action must expose a usable pointer target")
        correct.click()

        let editor = app.control(withIdentifier: "transcript-correction-editor")
        XCTAssertTrue(
            editor.waitForExistenceFast(timeout: 5),
            "text and speaker editing must use one focused accessible surface")
        let originalEvidence = app.control(
            withIdentifier: "transcript-correction-original-evidence")
        XCTAssertTrue(originalEvidence.waitForExistenceFast(timeout: 5))
        originalEvidence.click()
        let acceptedEvidence = app.staticTexts[
            "El rollout del modelo queda para el viernes."]
        XCTAssertTrue(
            acceptedEvidence.waitForExistenceFast(timeout: 5),
            "the accepted transcript must remain available as immutable evidence")

        let textEditor = app.textViews["transcript-correction-text"]
        XCTAssertTrue(textEditor.waitForExistenceFast(timeout: 5))
        textEditor.click()
        textEditor.typeKey("a", modifierFlags: .command)
        textEditor.typeText("El rollout del modelo queda para el lunes.")
        let speakerPicker = app.popUpButtons["transcript-correction-speaker"]
        XCTAssertTrue(speakerPicker.waitForExistenceFast(timeout: 5))
        speakerPicker.click()
        let localSpeaker = app.menuItems["Me"]
        XCTAssertTrue(
            localSpeaker.waitForExistenceFast(timeout: 5),
            "one focused edit must support speaker correction beside text")
        localSpeaker.click()
        attachScreenshot(of: app, named: "transcript-correction-original-evidence")
        app.buttons["transcript-correction-save"].click()

        let transcript = app.control(withIdentifier: "detail-transcript-section")
        let correctedReading = transcript.descendants(matching: .staticText)
            .matching(NSPredicate(
                format: "label == %@ OR value == %@",
                "El rollout del modelo queda para el lunes.",
                "El rollout del modelo queda para el lunes."))
            .firstMatch
        XCTAssertTrue(
            correctedReading.waitForExistenceFast(timeout: 10),
            "the composed Meeting Detail reading must update after persistence")
        XCTAssertTrue(correct.waitForExistenceFast(timeout: 5))
        XCTAssertTrue(
            correct.revealVertically(in: transcriptScroll, maxScrolls: 4),
            "the corrected source action must remain visible before undo")
        correct.click()
        let undo = app.buttons["transcript-correction-undo"]
        XCTAssertTrue(
            undo.waitForExistenceFast(timeout: 5),
            "an active correction must expose durable restore-based undo")
        undo.click()

        let restoredReading = transcript.descendants(matching: .staticText)
            .matching(NSPredicate(
                format: "label == %@ OR value == %@",
                "El rollout del modelo queda para el viernes.",
                "El rollout del modelo queda para el viernes."))
            .firstMatch
        XCTAssertTrue(
            restoredReading.waitForExistenceFast(timeout: 10),
            "undo must restore the accepted reading without deleting history")
    }

    @MainActor
    func testTranscriptStructuralCorrectionsSplitMergeHideAndRestoreEvidence() {
        let app = launchOnSeededMeeting()
        defer { app.terminate() }

        let sourceID = "B5B00000-0000-4000-8000-000000000002"
        let neighborID = "B5F00000-0000-4000-8000-000000000001"
        let correct = app.buttons["transcript-correct-\(sourceID)"]
        XCTAssertTrue(correct.waitForExistenceFast(timeout: 10))
        let transcriptScroll = app.control(withIdentifier: "detail-transcript-scroll")
        XCTAssertTrue(
            correct.revealVertically(in: transcriptScroll, maxScrolls: 4),
            "the structural correction action must be fully visible before activation")
        correct.click()

        let split = app.buttons["transcript-structure-split"]
        XCTAssertTrue(
            split.waitForExistenceFast(timeout: 5),
            "one accepted line with spoken duration must offer an explicit split")
        split.click()
        XCTAssertTrue(app.control(
            withIdentifier: "transcript-structure-split-first").exists)
        XCTAssertTrue(app.control(
            withIdentifier: "transcript-structure-split-second").exists)
        XCTAssertTrue(app.control(
            withIdentifier: "transcript-structure-split-time").exists)
        attachScreenshot(of: app, named: "transcript-structural-split-evidence")
        app.buttons["transcript-structure-confirm"].click()

        XCTAssertTrue(
            app.staticTexts["El rollout del modelo"].waitForExistenceFast(timeout: 5))
        XCTAssertTrue(app.staticTexts["queda para el viernes."].exists)
        let splitCorrection = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@",
            "transcript-correct-\(sourceID)-")).firstMatch
        XCTAssertTrue(
            splitCorrection.waitForExistenceFast(timeout: 5),
            "each visible split part must retain a unique correction route")
        XCTAssertTrue(
            splitCorrection.revealVertically(in: transcriptScroll, maxScrolls: 4),
            "the split source action must be fully visible before restore")
        splitCorrection.click()
        let splitUndo = app.buttons["transcript-structure-undo"]
        XCTAssertTrue(splitUndo.waitForExistenceFast(timeout: 5))
        splitUndo.click()
        let correctionEditor = app.control(
            withIdentifier: "transcript-correction-editor")
        XCTAssertTrue(
            correctionEditor.waitForDisappearance(timeout: 5),
            "split undo must finish and dismiss before resolving the restored row")

        XCTAssertTrue(
            app.staticTexts["El rollout del modelo queda para el viernes."]
                .waitForExistenceFast(timeout: 5),
            "restoring a split must recover the exact accepted line")
        XCTAssertTrue(correct.waitForExistenceFast(timeout: 5))
        XCTAssertTrue(
            correct.revealVertically(in: transcriptScroll, maxScrolls: 4),
            "the restored source action must be fully visible before merge")
        correct.click()

        let merge = app.buttons["transcript-structure-merge-\(neighborID)"]
        XCTAssertTrue(
            merge.waitForExistenceFast(timeout: 5),
            "merge must name the explicit adjacent accepted line")
        merge.click()
        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.staticTexts["El rollout del modelo queda para el viernes."].exists)
        XCTAssertTrue(sheet.staticTexts["¿Cuándo es el rollout?"].exists)
        attachScreenshot(of: app, named: "transcript-structural-correction-evidence")
        app.buttons["transcript-structure-confirm"].click()

        XCTAssertTrue(
            app.staticTexts[
                "El rollout del modelo queda para el viernes. ¿Cuándo es el rollout?"
            ].waitForExistenceFast(timeout: 5),
            "an explicit merge must preserve both accepted texts")

        XCTAssertTrue(correct.waitForExistenceFast(timeout: 5))
        XCTAssertTrue(
            correct.revealVertically(in: transcriptScroll, maxScrolls: 4),
            "the merged source action must be fully visible before restore")
        correct.click()
        let undo = app.buttons["transcript-structure-undo"]
        XCTAssertTrue(
            undo.waitForExistenceFast(timeout: 5),
            "merged evidence must expose durable restore-based undo")
        undo.click()
        XCTAssertTrue(
            correctionEditor.waitForDisappearance(timeout: 5),
            "merge undo must finish and dismiss before resolving the restored row")

        let restoredReading = app.control(
            withIdentifier: "detail-transcript-section").staticTexts[
            "El rollout del modelo queda para el viernes."]
        XCTAssertTrue(
            restoredReading.waitForExistenceFast(timeout: 5),
            "restore-based merge undo must reactivate the accepted reading")
        XCTAssertTrue(correct.waitForExistenceFast(timeout: 5))
        XCTAssertTrue(
            correct.revealVertically(in: transcriptScroll, maxScrolls: 4),
            "the restored source action must be fully visible before hiding")
        correct.click()
        let hide = app.buttons["transcript-structure-suppress"]
        XCTAssertTrue(hide.waitForExistenceFast(timeout: 5))
        hide.click()
        app.buttons["transcript-structure-confirm"].click()

        XCTAssertTrue(
            restoredReading.waitForDisappearance(timeout: 10),
            "hiding must remove the accepted reading from the visible transcript")

        let hiddenLines = app.buttons["transcript-hidden-lines"]
        XCTAssertTrue(
            hiddenLines.waitForExistenceFast(timeout: 5),
            "suppressed speech must remain discoverable as hidden evidence")
        hiddenLines.click()
        let hiddenSheet = app.control(withIdentifier: "transcript-hidden-lines-sheet")
        XCTAssertTrue(hiddenSheet.waitForExistenceFast(timeout: 5))
        XCTAssertTrue(hiddenSheet.staticTexts[
            "El rollout del modelo queda para el viernes."
        ].exists)
        let restore = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH 'transcript-hidden-restore-'"
        )).firstMatch
        XCTAssertTrue(restore.waitForExistenceFast(timeout: 5))
        restore.click()

        XCTAssertTrue(
            restoredReading.waitForExistenceFast(timeout: 5),
            "restore must recover the accepted row without erasing history")
    }

    @MainActor
    func testUnnamedSpeakerOffersExplicitNameSuggestions() {
        let app = launchOnSeededMeeting(unnamedSpeaker: true)
        defer { app.terminate() }

        XCTAssertTrue(
            app.control(withIdentifier: "detail-header-section")
                .waitForExistenceFast(timeout: 10),
            "meeting identity and participants must stay inside the header section")
        XCTAssertTrue(
            app.control(withIdentifier: "detail-suggest-names")
                .waitForExistenceFast(timeout: 10),
            "an unnamed remote speaker must retain the explicit suggestion action")
        XCTAssertFalse(
            app.control(withIdentifier: "cast-speaker-Me").label.isEmpty,
            "the local speaker remains distinct from remote naming candidates")
        XCTAssertTrue(
            app.control(withIdentifier: "detail-header-section")
                .waitForStableFrame(timeout: 5),
            "the detail header must finish its navigation transition")
        attachScreenshot(of: app, named: "meeting-name-suggestions")
    }

    @MainActor
    func testAISuggestionsCanBeIgnoredAndPlaybackOffersClearMix() {
        let app = launchOnSeededMeeting(
            unnamedSpeaker: true,
            aiSuggestions: true)
        defer { app.terminate() }

        let titleDismiss = app.buttons["detail-title-suggestion-dismiss"]
        XCTAssertTrue(titleDismiss.waitForExistenceFast(timeout: 10))
        titleDismiss.click()
        XCTAssertFalse(app.buttons["detail-title-suggestion"].exists)

        let recipeDismiss = app.buttons["detail-recipe-suggestion-dismiss"]
        XCTAssertTrue(recipeDismiss.waitForExistenceFast(timeout: 10))
        recipeDismiss.click()
        XCTAssertFalse(app.buttons["detail-recipe-suggestion"].exists)

        let suggestNames = app.control(withIdentifier: "detail-suggest-names")
        XCTAssertTrue(suggestNames.waitForExistenceFast(timeout: 5))
        suggestNames.click()
        let nameDismiss = app.buttons["detail-name-suggestion-dismiss-S1"]
        XCTAssertTrue(nameDismiss.waitForExistenceFast(timeout: 10))
        nameDismiss.click()
        XCTAssertFalse(app.buttons["detail-name-suggestion-S1"].exists)

        XCTAssertTrue(
            app.control(withIdentifier: "player-clear-playback")
                .waitForExistenceFast(timeout: 10),
            "two-channel playback must expose the reversible clear mix")
        attachScreenshot(of: app, named: "dismissible-ai-suggestions-and-clear-playback")
    }

    @MainActor
    func testFailedDurableProcessingOffersOneRecoveryAction() {
        let app = launchOnSeededMeeting(processingFailure: true)
        defer { app.terminate() }

        XCTAssertTrue(
            app.control(withIdentifier: "detail-trust-section")
                .waitForExistenceFast(timeout: 10),
            "durable recovery and privacy state must stay inside the trust section")
        XCTAssertTrue(
            app.control(withIdentifier: "detail-processing-status")
                .waitForExistenceFast(timeout: 10),
            "a durable failure must be visible beside the meeting")
        let retry = app.buttons["detail-retry-processing"]
        XCTAssertTrue(
            retry.waitForExistenceFast(timeout: 5),
            "a terminal durable failure must expose one explicit retry action")
        attachScreenshot(of: app, named: "meeting-detail-processing-recovery")
        retry.click()
    }

    @MainActor
    func testAbandonedAutomaticSummarySaysSoBesideGeneration() {
        let app = launchOnSeededMeeting(withoutSummary: true, abandonedSummary: true)
        defer { app.terminate() }

        let notice = app.staticTexts["detail-summary-abandoned"]
        XCTAssertTrue(
            notice.waitForExistenceFast(timeout: 10),
            "a cancelled automatic summary must be visible, not silently absent")
        XCTAssertTrue(
            app.buttons["detail-generate-summary"].waitForExistenceFast(timeout: 10),
            "the explicit generation route must stay available beside the notice")
        XCTAssertTrue(
            app.prepareForInteraction(),
            "Portavoz must own the foreground before capturing the recovery state")
        attachScreenshot(of: app, named: "meeting-detail-abandoned-summary")
    }

    @MainActor
    func testSequoiaSummaryFailureOpensExactSetupAndExplainsApuntador() throws {
        let app = launchOnSeededMeeting(
            withoutSummary: true,
            simulateSequoiaCapabilities: true,
            summaryEngine: "appleOnDevice")
        defer { app.terminate() }

        let generate = app.buttons["detail-generate-summary"]
        XCTAssertTrue(
            generate.waitForExistenceFast(timeout: 10),
            "a meeting without a summary must offer generation")
        generate.click()

        let openSettings = app.buttons["detail-summary-open-settings"]
        XCTAssertTrue(
            openSettings.waitForExistenceFast(timeout: 10),
            "an unavailable Apple engine must offer an actionable Settings route")
        openSettings.click()

        XCTAssertTrue(
            app.control(withIdentifier: "settings-summary-engine-picker")
                .waitForExistenceFast(timeout: 10),
            "the recovery action must land directly in Intelligence Settings")
        XCTAssertTrue(
            app.control(withIdentifier: "settings-summary-apple-unavailable").exists,
            "the selected Apple engine must explain that it cannot run on Sequoia")
        if Locale.current.identifier.hasPrefix("es") {
            let localizedRecommendations = [
                "Apple Intelligence: resúmenes en el dispositivo, gratis y rápidos.",
                "Ollama local: resúmenes 100 % en tu Mac, sin Apple Intelligence.",
                "Modelo local integrado: resúmenes sin instalar nada.",
                "No hay ningún motor local de resúmenes."
            ]
            XCTAssertTrue(
                localizedRecommendations.contains { app.staticTexts[$0].exists },
                "the recommendation must cross the app localization boundary")
        }
        attachScreenshot(of: app, named: "sequoia-summary-actionable-settings")

        let voiceCategory = app.buttons["settings-category-voice"]
        XCTAssertTrue(
            voiceCategory.waitForStableFrame(timeout: 5),
            "the Voice category must expose its actual button hit target")
        voiceCategory.click()
        let status = app.control(withIdentifier: "settings-apuntador-status")
        XCTAssertTrue(
            status.waitForExistenceFast(timeout: 5),
            "the voice pane must explain Apuntador's cross-version capability")
        let toggle = app.control(withIdentifier: "settings-apuntador-enabled")
        XCTAssertTrue(
            toggle.exists,
            "Sequoia must expose the bundled detector instead of a dead platform gate")
        let expectedDetectionStatus = UITestLocale.environmentLocale == "es"
                ? "La detección de preguntas del Apuntador está lista en este Mac."
                : "Apuntador question detection is ready on this Mac."
        let detectionStatus = try accessibleText(of: status)
        XCTAssertTrue(
            detectionStatus.contains(expectedDetectionStatus),
            "the status must distinguish working detection from optional answer generation; "
                + "saw '\(detectionStatus)'")
        attachScreenshot(of: app, named: "sequoia-apuntador-requirements")
    }

    @MainActor
    func testMeetingReviewSurfacesRemainCompleteAndActionable() {
        let app = launchOnSeededMeeting()
        defer { app.terminate() }

        // One launch owns the static review surfaces for this exact seeded
        // meeting. The notes, right rail, and generated document remain
        // independently asserted before the only durable mutation below.
        let notesSection = app.control(withIdentifier: "detail-notes-section")
        XCTAssertTrue(
            notesSection.waitForExistenceFast(timeout: 10),
            "notes must retain one explicit presentation boundary")
        XCTAssertTrue(
            notesSection.descendants(matching: .any)["detail-notes-title"]
                .waitForExistenceFast(timeout: 10),
            "a meeting with notes must surface the My notes section")
        XCTAssertTrue(
            notesSection.staticTexts["revisar budget Q3"].exists,
            "the raw seeded note is shown verbatim before any enhancement")
        XCTAssertTrue(
            notesSection.descendants(matching: .any)["detail-enhance-notes"]
                .waitForExistenceFast(timeout: 5),
            "a meeting with transcript and notes must offer the enhance menu")
        attachScreenshot(of: app, named: "meeting-detail-my-notes")

        let secondaryRail = app.control(withIdentifier: "detail-secondary-rail")
        XCTAssertTrue(
            secondaryRail.waitForExistenceFast(timeout: 10),
            "secondary review panels must retain one independently scrolling boundary")
        XCTAssertTrue(
            secondaryRail.descendants(matching: .any)["detail-meeting-health"]
                .waitForExistenceFast(timeout: 10),
            "the right rail must show meeting health")
        XCTAssertTrue(
            secondaryRail.descendants(matching: .any)["detail-privacy-receipt"]
                .waitForExistenceFast(timeout: 10),
            "the right rail must show the local privacy receipt")
        XCTAssertTrue(
            secondaryRail.descendants(matching: .any)["privacy-remote-event-0"].exists,
            "the fixture's content-free remote summary attempt must be auditable")
        let syncDisclosure = secondaryRail.descendants(matching: .any)[
            "detail-privacy-receipt-sync"]
        XCTAssertTrue(
            syncDisclosure.exists,
            "the receipt must disclose the acknowledged private iCloud copy")
        let expectedSyncDescription = Locale.current.identifier.hasPrefix("es")
            ? "El texto de esta reunión se guardó en campos cifrados de tu base de datos privada de iCloud."
            : "This meeting's text was stored in encrypted fields in your private iCloud database."
        XCTAssertTrue(
            syncDisclosure.waitForValue(expectedSyncDescription, timeout: 5))
        XCTAssertTrue(
            app.control(withIdentifier: "detail-refine").exists,
            "the action row must offer the refine control")
        XCTAssertTrue(
            app.control(withIdentifier: "detail-transcript-section").exists,
            "the transcript must expose its correction-ready reading boundary")
        XCTAssertTrue(
            secondaryRail.descendants(matching: .any)["detail-chapters"].exists,
            "the right rail must show the ✦ chapters (the seed has a second chapter)")
        let laterChapter = secondaryRail.descendants(matching: .any)["chapter-200"]
        XCTAssertTrue(
            laterChapter.exists,
            "a chapter must mark the later turn the seed placed at 200 s")
        XCTAssertTrue(
            laterChapter.isEnabled,
            "a chapter backed by saved audio must be actionable")
        XCTAssertTrue(
            app.prepareForInteraction(),
            "Portavoz must be foreground before activating chapter navigation")
        XCTAssertTrue(
            laterChapter.waitForStableFrame(),
            "the chapter control must finish layout before activation")
        laterChapter.click()
        let currentTime = app.control(withIdentifier: "player-current-time")
        XCTAssertTrue(currentTime.waitForValueOtherThan("0:00", timeout: 5))
        XCTAssertTrue(
            secondaryRail.descendants(matching: .any)["detail-apuntador"]
                .waitForExistenceFast(timeout: 5),
            "the right rail must show the persisted Apuntador answers")
        XCTAssertTrue(
            secondaryRail.descendants(matching: .any)["apuntador-card-6"]
                .waitForExistenceFast(timeout: 5),
            "the answered Apuntador card must render for review")
        attachScreenshot(
            of: app,
            names: [
                "meeting-detail-privacy-receipt",
                "meeting-detail-transcript-navigation",
            ])

        let generatedDocument = app.control(withIdentifier: "detail-generated-document")
        XCTAssertTrue(
            generatedDocument.waitForExistenceFast(timeout: 10),
            "generated claims and commitments must stay inside one document section")
        // The transcript rendered (this line is unique to the transcript).
        XCTAssertTrue(
            app.staticTexts["Revisemos el presupuesto de transcripción."]
                .waitForExistenceFast(timeout: 10),
            "the detail view must render the seeded transcript")

        // The default "Summary" tab shows the intro/overview.
        XCTAssertTrue(
            generatedDocument.staticTexts[
                "El equipo revisó el presupuesto y fijó el rollout."]
                .waitForExistenceFast(timeout: 10),
            "the summary's Summary tab must show the overview")
        XCTAssertFalse(
            generatedDocument.descendants(matching: .any)["summary-tab-2"].exists,
            "the canonical commitment appendix must not duplicate the typed To-dos tab")

        // The ▸ coauthoring marker lives under the Decisiones section, now
        // behind its own tab — switching to it reveals the bullet.
        let decisionsTab = generatedDocument.descendants(matching: .any)["summary-tab-1"]
        XCTAssertTrue(app.prepareForInteraction())
        XCTAssertTrue(decisionsTab.waitForStableFrame(timeout: 5))
        decisionsTab.click()
        XCTAssertTrue(
            app.staticTexts["▸"].waitForExistenceFast(timeout: 5),
            "the Decisiones tab must reveal the ▸ coauthored bullet (D28)")

        // A real mutation crosses MeetingDetailModel's client and the scoped
        // summary observation returns the completed count to the same view.
        let todosTab = generatedDocument.descendants(matching: .any)["summary-tab-todos"]
        XCTAssertTrue(todosTab.waitForStableFrame(timeout: 5))
        todosTab.click()
        let actionItem = generatedDocument.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'action-item-'"))
            .firstMatch
        guard actionItem.waitForStableFrame(timeout: 10) else {
            XCTFail("the seeded action item must expose a stable actionable boundary")
            return
        }
        actionItem.click()
        let updatedTodosTab = generatedDocument.descendants(matching: .any)[
            "summary-tab-todos"]
        XCTAssertTrue(updatedTodosTab.waitForLabelContaining("1/1", timeout: 10))
        attachScreenshot(of: app, named: "meeting-detail-generated-document")
    }

    @MainActor
    func testEvidenceSourcesJumpToTheirExactTranscriptAndAudio() {
        let app = launchOnSeededMeeting()
        defer { app.terminate() }

        let source = app.control(withIdentifier: "summary-evidence-0")
        guard source.waitForExistenceFast(timeout: 10) else {
            XCTFail("the overview must expose its persisted transcript source")
            return
        }
        XCTAssertEqual(
            source.value as? String,
            "El rollout del modelo queda para el viernes.")
        XCTAssertTrue(
            app.prepareForInteraction(),
            "Portavoz must be foreground before activating a summary source")
        XCTAssertTrue(
            source.waitForStableFrame(),
            "the localized source control must finish layout before activation")
        source.click()

        let citedRow = app.control(
            withIdentifier: "transcript-segment-B5B00000-0000-4000-8000-000000000002")
        XCTAssertTrue(
            citedRow.waitForExistenceFast(timeout: 5),
            "source navigation must focus the exact persisted transcript segment")
        XCTAssertTrue(citedRow.waitForSelection(timeout: 5))

        let currentTime = app.control(withIdentifier: "player-current-time")
        XCTAssertTrue(currentTime.waitForValue("0:03", timeout: 5))
        attachScreenshot(of: app, named: "meeting-detail-summary-evidence")

        let resetChapter = app.control(withIdentifier: "chapter-0")
        let playbackToggle = app.control(withIdentifier: "player-play-pause")
        resetEvidenceNavigation(
            chapter: resetChapter,
            playbackToggle: playbackToggle,
            citedRow: citedRow,
            currentTime: currentTime)

        let decisions = app.control(withIdentifier: "summary-tab-1")
        XCTAssertTrue(decisions.waitForExistenceFast(timeout: 10))
        decisions.click()
        let decisionSource = app.control(
            withIdentifier: "summary-decision-0-0-evidence-0")
        guard decisionSource.waitForExistenceFast(timeout: 5) else {
            XCTFail("the first decision must expose its exact transcript source")
            return
        }
        XCTAssertEqual(
            decisionSource.value as? String,
            "El rollout del modelo queda para el viernes.")
        decisionSource.click()
        XCTAssertTrue(citedRow.waitForSelection(timeout: 5))
        XCTAssertTrue(currentTime.waitForValue("0:03", timeout: 5))
        attachScreenshot(of: app, named: "meeting-detail-decision-evidence")

        resetEvidenceNavigation(
            chapter: resetChapter,
            playbackToggle: playbackToggle,
            citedRow: citedRow,
            currentTime: currentTime)

        let todos = app.control(withIdentifier: "summary-tab-todos")
        XCTAssertTrue(todos.waitForExistenceFast(timeout: 10))
        todos.click()
        let actionItemSource = app.control(
            withIdentifier:
                "summary-action-item-B5E00000-0000-4000-8000-000000000001-evidence-0")
        guard actionItemSource.waitForExistenceFast(timeout: 5) else {
            XCTFail("the action item must expose its exact transcript source")
            return
        }
        XCTAssertEqual(
            actionItemSource.value as? String,
            "El rollout del modelo queda para el viernes.")
        actionItemSource.click()
        XCTAssertTrue(citedRow.waitForSelection(timeout: 5))
        XCTAssertTrue(currentTime.waitForValue("0:03", timeout: 5))
        attachScreenshot(of: app, named: "meeting-detail-action-item-evidence")

        resetEvidenceNavigation(
            chapter: resetChapter,
            playbackToggle: playbackToggle,
            citedRow: citedRow,
            currentTime: currentTime)

        XCTAssertTrue(
            app.control(withIdentifier: "detail-apuntador-section")
                .waitForExistenceFast(timeout: 10),
            "persisted Companion evidence must retain one accessible section boundary")
        let apuntadorSource = app.control(
            withIdentifier:
                "apuntador-card-B5F00000-0000-4000-8000-000000000002-answer-evidence-0")
        guard apuntadorSource.waitForExistenceFast(timeout: 10) else {
            XCTFail("the Apuntador answer must expose its exact transcript source")
            return
        }
        XCTAssertEqual(
            apuntadorSource.value as? String,
            "El rollout del modelo queda para el viernes.")
        apuntadorSource.click()
        XCTAssertTrue(citedRow.waitForSelection(timeout: 5))
        XCTAssertTrue(currentTime.waitForValue("0:03", timeout: 5))
        attachScreenshot(of: app, named: "meeting-detail-apuntador-evidence")
    }

    /// The explicit gesture that promotes a generated decision to durable
    /// truth with an optional topic. Runs against the disposable seed, so the
    /// confirmation lands in the temp store and the badge proves the durable
    /// state round-tripped, not just that a sheet closed.
    @MainActor
    func testDecisionCanBeConfirmedAboutATopic() {
        let app = launchOnSeededMeeting()
        defer { app.terminate() }

        let decisions = app.control(withIdentifier: "summary-tab-1")
        XCTAssertTrue(decisions.waitForExistenceFast(timeout: 10))
        decisions.click()

        let confirm = app.control(withIdentifier: "summary-decision-0-0-confirm")
        XCTAssertTrue(
            confirm.waitForExistenceFast(timeout: 5),
            "an unconfirmed decision over current evidence offers the gesture")
        confirm.click()

        let sheet = app.control(withIdentifier: "decision-confirm-sheet")
        XCTAssertTrue(sheet.waitForExistenceFast(timeout: 5))
        let statement = app.control(withIdentifier: "decision-confirm-statement")
        XCTAssertTrue(statement.exists, "the sheet quotes the exact statement")

        let field = app.textFields["decision-confirm-topic-field"]
        XCTAssertTrue(field.waitForExistenceFast(timeout: 5))
        field.click()
        field.typeText("atlasrollout")
        app.control(withIdentifier: "decision-confirm-submit").click()

        let badge = app.control(withIdentifier: "summary-decision-0-0-confirmed")
        XCTAssertTrue(
            badge.waitForExistenceFast(timeout: 10),
            "the durable confirmation renders as the badge")
        XCTAssertTrue(
            badge.label.contains("atlasrollout"),
            "the badge names the topic; saw '\(badge.label)'")
        XCTAssertFalse(
            app.control(withIdentifier: "summary-decision-0-0-confirm").exists,
            "the gesture does not offer itself twice")
        attachScreenshot(of: app, named: "meeting-detail-decision-confirmed")

        // The badge doubles as the retraction entry: withdrawing the link
        // returns the observation to its unconfirmed-topic reading (the
        // decision itself stays confirmed, so the badge loses the topic).
        badge.click()
        let retract = app.menuItems.matching(NSPredicate(
            format: "identifier BEGINSWITH %@",
            "summary-decision-0-0-retract-")).firstMatch
        XCTAssertTrue(
            retract.waitForExistenceFast(timeout: 5),
            "each linked topic offers its withdrawal from the badge menu")
        retract.click()

        let unlinked = app.control(withIdentifier: "summary-decision-0-0-confirmed")
        XCTAssertTrue(
            unlinked.waitForLabelNotContaining("atlasrollout", timeout: 10))
        attachScreenshot(of: app, named: "meeting-detail-decision-topic-retracted")
    }

    /// Q12/D316 — one launch, the whole skill journey: the banner proposes,
    /// the sheet previews the exact artifact, confirming leaves a durable
    /// receipt and retires the offer, and dismissing is terminal. Condensed
    /// deliberately: every stage shares the launch instead of paying one app
    /// start per assertion.
    @MainActor
    func testSkillProposalJourneyFromBannerToReceipt() {
        let app = launchOnSeededMeeting()
        defer { app.terminate() }

        let menu = app.control(withIdentifier: "skill-offer-menu")
        XCTAssertTrue(
            menu.waitForExistenceFast(timeout: 10),
            "a processed meeting with a summary must surface skill offers")
        XCTAssertTrue(app.prepareForInteraction())
        XCTAssertTrue(
            menu.waitForStableFrame(timeout: 5),
            "the localized skill menu must settle before opening")

        // 1 · Preview: the sheet shows the exact draft before any claim.
        menu.click()
        let recapItem = app.menuItems["skill-offer-recap-draft"]
        guard recapItem.waitForExistenceFast(timeout: 5) else {
            XCTFail("the open skill menu must expose the recap proposal")
            return
        }
        recapItem.click()
        let sheet = app.control(withIdentifier: "skill-confirm-sheet")
        XCTAssertTrue(sheet.waitForExistenceFast(timeout: 5))
        let cancel = app.buttons["skill-confirm-cancel"]
        XCTAssertTrue(cancel.waitForExistenceFast(timeout: 5))
        XCTAssertTrue(cancel.isEnabled)
        let body = app.control(withIdentifier: "skill-confirm-preview-body")
        XCTAssertTrue(body.waitForExistenceFast(timeout: 5))
        let subjectElement = app.control(
            withIdentifier: "skill-confirm-preview-subject")
        let subject = (subjectElement.value as? String) ?? subjectElement.label
        let previewBody = (body.value as? String) ?? body.label

        // 2 · Confirm: the effect lands on the clipboard and the durable
        // receipt renders in the trust rail.
        let submit = app.buttons["skill-confirm-submit"]
        XCTAssertTrue(
            submit.waitForStableFrame(timeout: 5),
            "the confirmation sheet must expose a stable submit button")
        submit.click()
        let receipt = app.control(withIdentifier: "skill-receipt-recap-draft")
        guard receipt.waitForExistenceFast(timeout: 10) else {
            XCTFail("a confirmed run must leave its auditable receipt")
            return
        }
        XCTAssertTrue(
            receipt.label.contains("—"),
            "the receipt announces skill and outcome; saw '\(receipt.label)'")
        let copied = NSPasteboard.general.string(forType: .string) ?? ""
        XCTAssertEqual(
            copied,
            "\(subject)\n\n\(previewBody)",
            "the clipboard must contain the exact artifact the user approved")

        // 3 · A succeeded recap retires only that offer; external and export
        // adapters remain independent user intents.
        let refreshedMenu = app.control(withIdentifier: "skill-offer-menu")
        XCTAssertTrue(
            refreshedMenu.waitForStableFrame(timeout: 5),
            "the offer menu must settle after the confirmed offer reload")
        let emailDismiss = app.menuItems[
            "skill-offer-dismiss-email-recap-draft"]
        let gistDismiss = app.menuItems[
            "skill-offer-dismiss-secret-gist-publish"]
        let exportDismiss = app.menuItems["skill-offer-dismiss-package-export"]

        // AppKit can discard the first synthetic menu-open event while the
        // confirmed offer's view identity is being replaced. Re-resolve the
        // control and retry that presentation once; the proposal assertions
        // below still fail closed if the refreshed product menu is incomplete.
        for attempt in 0 ..< 2 where !emailDismiss.exists {
            refreshedMenu.click()
            if emailDismiss.waitForExistenceFast(timeout: 3) { break }
            if attempt == 0 {
                app.typeKey(.escape, modifierFlags: [])
                XCTAssertTrue(refreshedMenu.waitForStableFrame(timeout: 5))
            }
        }
        XCTAssertTrue(
            emailDismiss.exists,
            "email handoff remains an independent unperformed intent")
        XCTAssertTrue(
            exportDismiss.exists,
            "each export destination is a new intent, so export keeps offering")
        XCTAssertTrue(
            gistDismiss.exists,
            "remote Gist publication remains an independent unperformed intent")
        XCTAssertFalse(
            app.menuItems["skill-offer-recap-draft"].exists,
            "the draft exists — the offer must not ask again")
        emailDismiss.click()

        // 4 · Dismissing every remaining offer is terminal: the menu itself
        // leaves only after every independent intent is settled or dismissed.
        XCTAssertTrue(menu.waitForStableFrame(timeout: 5))
        menu.click()
        XCTAssertTrue(gistDismiss.waitForExistenceFast(timeout: 5))
        gistDismiss.click()
        XCTAssertTrue(menu.waitForStableFrame(timeout: 5))
        menu.click()
        XCTAssertTrue(exportDismiss.waitForExistenceFast(timeout: 5))
        exportDismiss.click()
        XCTAssertTrue(menu.waitForDisappearance(timeout: 5))
        attachScreenshot(of: app, named: "meeting-detail-skill-receipt")
    }

    /// D327 — the external boundary stays review-first: exact summary-derived
    /// text, no inferred recipients, an explicit sync warning, and a separate
    /// Send action in the user's email app. The disposable UI adapter traverses
    /// the production proposal/effect path without launching the host client.
    @MainActor
    func testEmailRecapSkillPreviewsAndHandsOffWithoutSending() throws {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString("email-skill-sentinel", forType: .string)
        let app = launchOnSeededMeeting()
        defer { app.terminate() }

        let menu = app.control(withIdentifier: "skill-offer-menu")
        XCTAssertTrue(menu.waitForStableFrame(timeout: 10))
        menu.click()
        let email = app.menuItems["skill-offer-email-recap-draft"]
        guard email.waitForExistenceFast(timeout: 5) else {
            XCTFail("the meeting must expose its review-first email draft")
            return
        }
        email.click()

        let sheet = app.control(withIdentifier: "skill-confirm-sheet")
        XCTAssertTrue(sheet.waitForExistenceFast(timeout: 5))
        let subjectElement = app.control(
            withIdentifier: "skill-confirm-preview-subject")
        let bodyElement = app.control(
            withIdentifier: "skill-confirm-preview-body")
        XCTAssertTrue(subjectElement.waitForExistenceFast(timeout: 5))
        XCTAssertTrue(bodyElement.waitForExistenceFast(timeout: 5))
        let subject = (subjectElement.value as? String) ?? subjectElement.label
        let body = (bodyElement.value as? String) ?? bodyElement.label
        XCTAssertFalse(subject.trimmingCharacters(in: .whitespaces).isEmpty)
        XCTAssertTrue(
            body.contains("El equipo revisó el presupuesto"),
            "the email body must come from the exact seeded summary")

        let recipientPolicy = app.control(
            withIdentifier: "skill-confirm-email-recipient-policy")
        let boundary = app.control(
            withIdentifier: "skill-confirm-email-boundary")
        XCTAssertTrue(recipientPolicy.waitForExistenceFast(timeout: 5))
        XCTAssertTrue(boundary.waitForExistenceFast(timeout: 5))
        let expectedRecipientCopy = UITestLocale.environmentLocale == "es"
            ? "Sin destinatarios — los eliges en tu app de correo."
            : "No recipients — you choose them in your email app."
        let recipientText = try accessibleText(of: recipientPolicy)
        XCTAssertTrue(
            recipientText.contains(expectedRecipientCopy),
            "expected recipient policy in accessible text, got: \(recipientText)")
        let expectedBoundaryCopy = UITestLocale.environmentLocale == "es"
            ? "Portavoz nunca lo envía."
            : "Portavoz never sends it."
        let boundaryText = try accessibleText(of: boundary)
        XCTAssertTrue(
            boundaryText.contains(expectedBoundaryCopy),
            "expected email boundary in accessible text, got: \(boundaryText)")

        let submit = app.buttons["skill-confirm-submit"]
        XCTAssertTrue(submit.waitForStableFrame(timeout: 5))
        let expectedSubmit = UITestLocale.environmentLocale == "es"
            ? "Abrir borrador de email"
            : "Open email draft"
        XCTAssertEqual(submit.label, expectedSubmit)
        submit.click()

        let receipt = app.control(
            withIdentifier: "skill-receipt-email-recap-draft")
        XCTAssertTrue(
            receipt.waitForExistenceFast(timeout: 10),
            "successful composer handoff must leave a content-free receipt")
        let expectedReceipt = UITestLocale.environmentLocale == "es"
            ? "entrega solicitada"
            : "handoff requested"
        XCTAssertTrue(
            receipt.label.localizedCaseInsensitiveContains(expectedReceipt),
            "the receipt must say handoff, never sent or delivered")
        XCTAssertEqual(
            NSPasteboard.general.string(forType: .string),
            "email-skill-sentinel",
            "email permission cannot be downgraded into clipboard permission")
        XCTAssertEqual(
            app.state,
            .runningForeground,
            "UI automation must never launch the host email application")

        menu.click()
        XCTAssertFalse(
            app.menuItems["skill-offer-email-recap-draft"].exists,
            "a successful handoff retires only the email intent")
        XCTAssertTrue(app.menuItems["skill-offer-recap-draft"].exists)
        XCTAssertTrue(app.menuItems["skill-offer-secret-gist-publish"].exists)
        XCTAssertTrue(app.menuItems["skill-offer-package-export"].exists)
        attachScreenshot(of: app, named: "meeting-detail-email-recap-handoff")
    }

    /// D328/D434 — one launch covers both GitHub mutations. Exact Gist
    /// Markdown and one cited action-item issue are visible before their
    /// independent confirmations; disposable gateways write real content-free
    /// egress receipts without touching Keychain or the network.
    @MainActor
    func testSecretGistSkillPreviewsPublishesAndReceiptsExactDocument() throws {
        let app = launchOnSeededMeeting()
        defer { app.terminate() }

        let menu = app.control(withIdentifier: "skill-offer-menu")
        XCTAssertTrue(menu.waitForStableFrame(timeout: 10))
        menu.click()
        let gist = app.menuItems["skill-offer-secret-gist-publish"]
        guard gist.waitForExistenceFast(timeout: 5) else {
            XCTFail("the meeting must expose one review-first Gist proposal")
            return
        }
        gist.click()

        let sheet = app.control(withIdentifier: "skill-confirm-sheet")
        XCTAssertTrue(sheet.waitForExistenceFast(timeout: 5))
        let destination = app.control(
            withIdentifier: "skill-confirm-gist-destination")
        let body = app.control(withIdentifier: "skill-confirm-preview-body")
        let boundary = app.control(
            withIdentifier: "skill-confirm-gist-boundary")
        XCTAssertTrue(destination.waitForExistenceFast(timeout: 5))
        XCTAssertTrue(body.waitForExistenceFast(timeout: 5))
        XCTAssertTrue(boundary.waitForExistenceFast(timeout: 5))
        let destinationText = try accessibleText(of: destination)
        XCTAssertTrue(destinationText.contains("test-meeting.md"))
        XCTAssertTrue(destinationText.contains("api.github.com"))
        let bodyText = try accessibleText(of: body)
        XCTAssertTrue(bodyText.contains("# Test meeting"))
        XCTAssertTrue(
            bodyText.contains("El rollout del modelo queda para el viernes."),
            "the exact canonical document must include the seeded transcript")
        let expectedBoundary = UITestLocale.environmentLocale == "es"
            ? "Cualquier persona con el enlace puede leerlo."
            : "Anyone with the link can read it."
        XCTAssertTrue(
            try accessibleText(of: boundary).contains(expectedBoundary),
            "the remote audience boundary must be explicit")

        let submit = app.buttons["skill-confirm-submit"]
        XCTAssertTrue(submit.waitForStableFrame(timeout: 5))
        let expectedSubmit = UITestLocale.environmentLocale == "es"
            ? "Publicar Gist secreto"
            : "Publish secret Gist"
        XCTAssertEqual(submit.label, expectedSubmit)
        submit.click()

        let resultURL = app.control(withIdentifier: "gist-result-url")
        XCTAssertTrue(
            resultURL.waitForExistenceFast(timeout: 10),
            "successful publication must return its transient provider URL")
        XCTAssertTrue(try accessibleText(of: resultURL).contains(
            "https://gist.github.com/portavoz/skill-preview"))
        XCTAssertTrue(app.buttons["gist-result-copy-link"].exists)
        XCTAssertTrue(app.buttons["gist-result-open-link"].exists)
        let dismissResult = app.buttons["gist-result-dismiss"]
        XCTAssertTrue(dismissResult.exists)
        dismissResult.click()

        let receipt = app.control(
            withIdentifier: "skill-receipt-secret-gist-publish")
        XCTAssertTrue(
            receipt.waitForExistenceFast(timeout: 10),
            "the remote mutation must leave one durable Skill receipt")
        let expectedReceipt = UITestLocale.environmentLocale == "es"
            ? "publicado"
            : "published"
        XCTAssertTrue(
            receipt.label.localizedCaseInsensitiveContains(expectedReceipt))
        let remoteReceipts = app.staticTexts.matching(NSPredicate(
            format: "identifier BEGINSWITH 'privacy-remote-event-'"))
        XCTAssertTrue(
            remoteReceipts.element(boundBy: 1).waitForExistenceFast(timeout: 10),
            "the same run must record the content-free GitHub egress attempt")
        let remoteReceiptTexts = try (0..<remoteReceipts.count).map {
            try accessibleText(of: remoteReceipts.element(boundBy: $0))
        }
        XCTAssertTrue(
            remoteReceiptTexts.contains { $0.contains("api.github.com") },
            "the egress ledger must include api.github.com; got: \(remoteReceiptTexts)")
        let remoteCountAfterGist = remoteReceipts.count

        let todos = app.control(withIdentifier: "summary-tab-todos")
        XCTAssertTrue(todos.waitForHittable(timeout: 5))
        todos.click()
        let issueAction = app.buttons[
            "action-item-B5E00000-0000-4000-8000-000000000001-github"]
        XCTAssertTrue(
            issueAction.waitForHittable(timeout: 5),
            "one current pending action item must expose its issue action")
        issueAction.click()

        let issueSheet = app.control(withIdentifier: "github-issue-sheet")
        XCTAssertTrue(issueSheet.waitForExistenceFast(timeout: 5))
        let repository = app.textFields["github-issue-repository"]
        XCTAssertTrue(repository.waitForHittable(timeout: 5))
        repository.click()
        repository.typeText("portavoz/demo")
        let reviewIssue = app.buttons["github-issue-review"]
        XCTAssertTrue(reviewIssue.waitForHittable(timeout: 5))
        reviewIssue.click()

        let issueDestination = app.control(
            withIdentifier: "github-issue-preview-repository")
        let issueTitle = app.control(
            withIdentifier: "github-issue-preview-title")
        let issueBody = app.control(
            withIdentifier: "github-issue-preview-body")
        let issueCitation = app.control(
            withIdentifier: "github-issue-citation-0")
        let issueBoundary = app.control(
            withIdentifier: "github-issue-boundary")
        XCTAssertTrue(issueBoundary.waitForExistenceFast(timeout: 5))
        let issueDestinationText = try accessibleText(of: issueDestination)
        let issueBodyText = try accessibleText(of: issueBody)
        let issueCitationText = try accessibleText(of: issueCitation)
        XCTAssertTrue(issueDestinationText.contains("portavoz/demo"))
        XCTAssertTrue(issueDestinationText.contains("api.github.com"))
        XCTAssertTrue(try accessibleText(of: issueTitle).contains("Prepare the rollout"))
        XCTAssertTrue(issueBodyText.contains("Test meeting"))
        XCTAssertTrue(issueBodyText.contains("Ana"))
        XCTAssertTrue(issueBodyText.contains(
            "El rollout del modelo queda para el viernes."))
        XCTAssertTrue(issueCitationText.contains("00:03"))
        XCTAssertTrue(issueCitationText.contains(
            "El rollout del modelo queda para el viernes."))
        let expectedIssueBoundary = UITestLocale.environmentLocale == "es"
            ? "crea un issue"
            : "creates one issue"
        XCTAssertTrue(
            try accessibleText(of: issueBoundary)
                .localizedCaseInsensitiveContains(expectedIssueBoundary))

        let createIssue = app.buttons["github-issue-confirm"]
        XCTAssertTrue(createIssue.waitForHittable(timeout: 5))
        let expectedCreateIssue = UITestLocale.environmentLocale == "es"
            ? "Crear un issue"
            : "Create one issue"
        XCTAssertEqual(createIssue.label, expectedCreateIssue)
        createIssue.click()

        let issueResultURL = app.control(withIdentifier: "github-issue-result-url")
        XCTAssertTrue(issueResultURL.waitForExistenceFast(timeout: 10))
        XCTAssertTrue(try accessibleText(of: issueResultURL).contains(
            "https://github.com/portavoz/demo/issues/42"))
        app.buttons["github-issue-result-dismiss"].click()

        let issueReceipt = app.control(
            withIdentifier: "skill-receipt-github-issue-create")
        XCTAssertTrue(issueReceipt.waitForExistenceFast(timeout: 10))
        let expectedDetailIssueReceipt = UITestLocale.environmentLocale == "es"
            ? "Issue de GitHub — creado"
            : "GitHub issue — created"
        XCTAssertTrue(try accessibleText(of: issueReceipt)
            .localizedCaseInsensitiveContains(expectedDetailIssueReceipt))
        let issueRemoteReceipts = app.staticTexts.matching(NSPredicate(
            format: "identifier BEGINSWITH 'privacy-remote-event-'"))
        XCTAssertTrue(waitForUITestCondition(timeout: 10) {
            issueRemoteReceipts.count == remoteCountAfterGist + 1
        }, "one issue confirmation must add exactly one egress receipt")
        attachScreenshot(of: app, named: "meeting-detail-github-issue-receipts")

        XCTAssertTrue(app.openSettingsWindow())
        XCTAssertTrue(app.openSettingsCategory(
            "settings-category-skills",
            revealing: "settings-skills-pause-all"))
        let settingsReceipt = app.control(
            withIdentifier: "settings-skill-receipt-secret-gist-publish")
        XCTAssertTrue(settingsReceipt.waitForExistenceFast(timeout: 10))
        let expectedSettingsStatus = UITestLocale.environmentLocale == "es"
            ? "Gist secreto publicado"
            : "Secret Gist published"
        XCTAssertTrue(
            try accessibleText(of: settingsReceipt).contains(expectedSettingsStatus))
        let settingsIssueReceipt = app.control(
            withIdentifier: "settings-skill-receipt-github-issue-create")
        XCTAssertTrue(settingsIssueReceipt.waitForExistenceFast(timeout: 10))
        let expectedSettingsIssueReceipt = UITestLocale.environmentLocale == "es"
            ? "Issue de GitHub creado"
            : "GitHub issue created"
        XCTAssertTrue(try accessibleText(of: settingsIssueReceipt)
            .localizedCaseInsensitiveContains(expectedSettingsIssueReceipt))
    }

    @MainActor
    private func accessibleText(of element: XCUIElement) throws -> String {
        // Read both attributes from one observation rather than two AX queries.
        // Snapshot failures propagate to XCTest; never fall back to stale text.
        let snapshot = try element.snapshot()
        return [snapshot.label, snapshot.value as? String]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// D321 — a failed effect keeps the sheet and retries the original durable
    /// proposal. A fresh proposal UUID would collide with the claimed
    /// idempotency key, so this real-app journey fails against the old wiring.
    @MainActor
    func testFailedSkillEffectRetriesItsOriginalProposal() {
        let app = launchOnSeededMeeting(simulateSkillEffectFailureOnce: true)
        defer { app.terminate() }

        let menu = app.control(withIdentifier: "skill-offer-menu")
        XCTAssertTrue(menu.waitForStableFrame(timeout: 10))
        menu.click()
        let recap = app.menuItems["skill-offer-recap-draft"]
        XCTAssertTrue(recap.waitForExistenceFast(timeout: 5))
        recap.click()

        let sheet = app.control(withIdentifier: "skill-confirm-sheet")
        let submit = app.buttons["skill-confirm-submit"]
        guard sheet.waitForExistenceFast(timeout: 10) else {
            XCTFail("the recap preview sheet must survive asynchronous store reads")
            return
        }
        XCTAssertTrue(app.prepareForInteraction())
        guard submit.waitForStableFrame(timeout: 10) else {
            XCTFail("the recap preview must expose its stable confirmation control")
            return
        }
        let previewBody = app.control(withIdentifier: "skill-confirm-preview-body")
        let previewSubject = app.control(
            withIdentifier: "skill-confirm-preview-subject")
        let body = (previewBody.value as? String) ?? previewBody.label
        let subject = (previewSubject.value as? String) ?? previewSubject.label

        submit.click()
        let failure = app.control(withIdentifier: "skill-confirm-error")
        XCTAssertTrue(
            failure.waitForExistenceFast(timeout: 10),
            "the recoverable failure must be visible inside the open sheet")
        XCTAssertTrue(submit.waitForEnabled(timeout: 10))
        XCTAssertTrue(
            sheet.exists,
            "a failed effect must keep its exact preview available for retry")

        XCTAssertTrue(app.prepareForInteraction())
        XCTAssertTrue(submit.waitForStableFrame(timeout: 5))
        submit.click()
        let receipt = app.control(withIdentifier: "skill-receipt-recap-draft")
        XCTAssertTrue(
            receipt.waitForExistenceFast(timeout: 10),
            "the retry must settle the original claim as succeeded")
        XCTAssertFalse(sheet.exists)
        XCTAssertEqual(
            NSPasteboard.general.string(forType: .string),
            "\(subject)\n\n\(body)",
            "retry must deliver the same preview that was confirmed")
        attachScreenshot(of: app, named: "meeting-detail-skill-retry-receipt")
    }

    @MainActor
    func testCommitmentInboxRequiresEvidenceReviewBeforeConfirmation() {
        let app = launchOnSeededMeeting(commitmentInbox: true)
        defer { app.terminate() }

        let candidateID = "B5E00000-0000-4000-8000-000000000001"
        let inbox = app.control(withIdentifier: "detail-commitment-inbox")
        XCTAssertTrue(
            inbox.waitForExistenceFast(timeout: 10),
            "an unconfirmed generated action item must enter the review inbox")
        XCTAssertTrue(
            app.control(withIdentifier: "commitment-\(candidateID)-owner-suggestion")
                .exists,
            "only an exact canonical participant link may prefill the owner")

        let evidence = app.control(
            withIdentifier: "commitment-\(candidateID)-evidence-0")
        XCTAssertTrue(
            evidence.waitForExistenceFast(timeout: 5),
            "confirmation must expose its exact transcript evidence")
        XCTAssertEqual(
            evidence.value as? String,
            "El rollout del modelo queda para el viernes.")
        XCTAssertTrue(
            app.control(withIdentifier: "commitment-\(candidateID)-dismiss").exists)
        XCTAssertTrue(
            app.control(withIdentifier: "commitment-\(candidateID)-defer").exists)
        attachScreenshot(of: app, named: "meeting-detail-commitment-inbox")

        let artifacts = app.control(withIdentifier: "detail-artifacts-section")
        XCTAssertTrue(artifacts.waitForExistenceFast(timeout: 5))
        let review = app.control(withIdentifier: "commitment-\(candidateID)-review")
        XCTAssertTrue(
            review.waitForExistenceFast(timeout: 5),
            "the exact commitment review action must exist before activation")
        review.click()
        XCTAssertTrue(
            app.control(withIdentifier: "commitment-editor").waitForExistenceFast(timeout: 5),
            "the user must get one explicit wording, owner, and deadline review boundary")
        let editor = app.control(withIdentifier: "commitment-editor")
        let ownerPickers = editor.descendants(matching: .popUpButton)
        XCTAssertEqual(
            ownerPickers.count,
            1,
            "the editor must expose exactly one native owner picker")
        let ownerPicker = ownerPickers.firstMatch
        XCTAssertTrue(
            ownerPicker.waitForExistenceFast(timeout: 5),
            "the editor's native owner picker must be reachable")
        ownerPicker.click()
        let me = app.menuItems["commitment-owner-me"]
        XCTAssertTrue(
            me.waitForExistenceFast(timeout: 5),
            "the local user must be distinct from an external person and an unassigned owner")
        me.click()
        attachScreenshot(of: app, named: "meeting-detail-commitment-self-assignment")
        app.control(withIdentifier: "commitment-editor-confirm").click()

        XCTAssertTrue(inbox.waitForDisappearance(timeout: 10))
    }

    @MainActor
    func testSummaryFeedbackIsExplicitReversibleAndLocal() {
        let app = launchOnSeededMeeting()
        defer { app.terminate() }

        let unsupported = app.control(withIdentifier: "summary-feedback-unsupported")
        XCTAssertTrue(
            unsupported.waitForExistenceFast(timeout: 10),
            "an evidenced overview must expose explicit review controls")
        XCTAssertTrue(
            unsupported.waitForStableFrame(),
            "the localized feedback control must finish layout before activation")
        unsupported.click()
        XCTAssertTrue(unsupported.waitForSelection(timeout: 5))
        XCTAssertTrue(
            app.control(withIdentifier: "summary-feedback-status").exists,
            "the unsupported assessment must stay visibly attached to the claim")

        app.control(withIdentifier: "summary-feedback-correction").click()
        let sheet = app.sheets.firstMatch
        XCTAssertTrue(
            sheet.waitForExistenceFast(timeout: 5),
            "correction must use an explicit editor instead of rewriting generated text")
        let editor = sheet.textViews["summary-feedback-correction-text"]
        XCTAssertTrue(editor.waitForExistenceFast(timeout: 5))
        XCTAssertTrue(editor.waitForStableFrame(timeout: 5))
        editor.click()
        editor.typeText("El rollout queda para el lunes tras QA")
        app.control(withIdentifier: "summary-feedback-save").click()

        XCTAssertTrue(
            app.staticTexts["El rollout queda para el lunes tras QA"]
                .waitForExistenceFast(timeout: 5),
            "the saved correction must be visible without replacing the generated overview")
        XCTAssertTrue(
            app.staticTexts["El equipo revisó el presupuesto y fijó el rollout."].exists,
            "feedback must not mutate the immutable generated summary")
        attachScreenshot(of: app, named: "meeting-detail-summary-feedback")

        let feedbackStatus = app.control(withIdentifier: "summary-feedback-status")
        app.control(withIdentifier: "summary-feedback-clear").click()
        XCTAssertTrue(feedbackStatus.waitForDisappearance(timeout: 5))
    }

    @MainActor
    func testNamedSpeakerCanBeRememberedAsCanonicalPerson() {
        let app = launchOnSeededMeeting()
        defer { app.terminate() }

        let speaker = app.control(withIdentifier: "cast-speaker-S1")
        XCTAssertTrue(
            speaker.waitForExistenceFast(timeout: 10),
            "the observed participant must expose a stable rename boundary")
        speaker.click()

        // SwiftUI's macOS alert bridge strips a TextField's custom AX
        // identifier. Scope the query to the alert sheet so we never type
        // into the library search field behind it.
        let field = app.sheets.textFields.firstMatch
        XCTAssertTrue(field.waitForExistenceFast(timeout: 5))
        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeText("Ana")
        XCTAssertTrue(field.waitForValue("Ana", timeout: 5))
        // Commit text editing before activating Save. macOS can present its
        // native name-completion popover over the alert's buttons; a normal
        // Tab focus transition ends editing without choosing a suggestion or
        // changing the host's AutoFill preferences.
        field.typeKey(.tab, modifierFlags: [])
        let save = app.control(withIdentifier: "speaker-rename-save")
        XCTAssertTrue(save.waitForHittable(timeout: 5))
        save.click()
        XCTAssertTrue(field.waitForDisappearance(timeout: 5))

        let remember = app.buttons["person-remember-offer"]
        XCTAssertTrue(
            remember.waitForExistenceFast(timeout: 5),
            "a confirmed meeting-local name must offer explicit person memory")
        remember.click()

        let expectedValue = Locale.current.identifier.hasPrefix("es")
            ? "Vinculado a una persona recordada"
            : "Linked to a remembered person"
        XCTAssertTrue(speaker.waitForValue(expectedValue, timeout: 5))
        XCTAssertFalse(
            app.buttons["person-remember-offer"].exists,
            "the explicit offer must clear after the atomic link succeeds")
        attachScreenshot(of: app, named: "meeting-detail-confirmed-person-memory")
    }

    @MainActor
    func testMostRecentRecipeRemainsVisibleAfterReload() {
        let app = launchOnSeededMeeting(latestRecipe: true)
        defer { app.terminate() }

        let badge = app.control(withIdentifier: "summary-badge")
        XCTAssertTrue(
            badge.waitForExistenceFast(timeout: 10),
            "the active summary must expose its recipe-aware badge")
        XCTAssertEqual(
            badge.value as? String,
            "v1 · es · Standup",
            "the latest Standup snapshot must remain selected after Meeting Detail reloads")
        XCTAssertTrue(
            app.staticTexts["El resumen de standup sigue visible después de recargar."]
                .waitForExistenceFast(timeout: 5),
            "reload must not replace the latest structured summary with the older General one")
    }

    @MainActor
    func testFreshQualifyingMeetingShowsThePostMeetingMirror() {
        let app = launchOnSeededMeeting(justRecorded: true)
        defer { app.terminate() }

        XCTAssertTrue(
            app.control(withIdentifier: "mirror-card").waitForExistenceFast(timeout: 10),
            "an opted-in fresh qualifying meeting must show its factual mirror")
        attachScreenshot(of: app, named: "meeting-detail-post-meeting-mirror")
    }

    @MainActor
    func testRunningRefineCanBeCanceledWithoutChangingTheTranscript() {
        let app = launchOnSeededMeeting(refineRunning: true)
        defer { app.terminate() }

        XCTAssertTrue(
            app.control(withIdentifier: "detail-actions").waitForExistenceFast(timeout: 10),
            "meeting actions must retain one accessible section boundary")
        let refine = app.control(withIdentifier: "detail-refine")
        XCTAssertTrue(refine.waitForExistenceFast(timeout: 10))
        XCTAssertTrue(
            refine.waitForValue("cancel", timeout: 10),
            "the injected running refine must settle before cancellation")
        refine.click()

        XCTAssertTrue(refine.waitForValue("refine", timeout: 5))
        XCTAssertTrue(
            app.staticTexts["Revisemos el presupuesto de transcripción."].exists,
            "canceling a quality pass must leave the current transcript visible")
    }

    @MainActor
    func testPlayerExposesSkipAndOnlyMyVoice() {
        let app = launchOnSeededMeeting()
        defer { app.terminate() }

        let play = app.buttons["player-play-pause"]
        XCTAssertTrue(
            play.waitForExistenceFast(timeout: 10),
            "the player transport must render for a meeting that has audio")
        XCTAssertTrue(
            app.control(withIdentifier: "detail-player-section").exists,
            "the complete playback dock must retain one accessible section boundary")
        XCTAssertTrue(
            app.control(withIdentifier: "player-only-my-voice").exists,
            "the player must offer the 'only my voice' filter")
        XCTAssertTrue(
            app.control(withIdentifier: "detail-compress-audio").exists,
            "raw seeded meeting audio must keep its compression action")
        let currentTime = app.control(withIdentifier: "player-current-time")
        let initialTime = String(describing: currentTime.value)
        play.click()
        XCTAssertTrue(
            currentTime.waitForValueChange(from: initialTime, timeout: 5),
            "playback must advance instead of merely accepting the click")
        attachScreenshot(of: app, named: "meeting-detail-waveform")
    }

    /// The export menu is the only path to subtitle files, so both the SRT
    /// and VTT items must exist for a seeded diarized meeting.
    @MainActor
    func testExportMenuOffersSubtitleFormats() {
        let app = launchOnSeededMeeting(staleDerived: true)
        defer { app.terminate() }

        XCTAssertTrue(
            app.control(withIdentifier: "detail-actions").waitForExistenceFast(timeout: 10),
            "exports must remain inside the explicit meeting-actions boundary")
        let menu = app.control(withIdentifier: "detail-export-menu")
        XCTAssertTrue(
            menu.waitForExistenceFast(timeout: 10),
            "the action row must offer the export menu")
        menu.click()
        XCTAssertTrue(
            app.menuItems["detail-export-srt"].waitForExistenceFast(timeout: 5),
            "the diarized transcript must export as SRT")
        XCTAssertTrue(
            app.menuItems["detail-export-vtt"].waitForExistenceFast(timeout: 5),
            "the diarized transcript must export as VTT")
        let provenance = app.menuItems["detail-export-correction-provenance-off"]
        XCTAssertTrue(
            provenance.waitForExistenceFast(timeout: 5),
            "the export menu must disclose the opt-in correction provenance control")
        XCTAssertTrue(provenance.isEnabled)
        provenance.click()

        menu.click()
        let included = app.menuItems["detail-export-correction-provenance-on"]
        XCTAssertTrue(included.waitForExistenceFast(timeout: 5))
        attachScreenshot(of: app, named: "meeting-detail-correction-aware-export")
        // Close the menu without exporting — the save panel is native UI.
        app.typeKey(.escape, modifierFlags: [])
    }

    /// FEATURE-003: the recap opens as an editable draft the user reviews
    /// before choosing a destination — and it never carries the transcript.
    @MainActor
    func testRecapSheetDraftsFromTheSummaryWithoutTheTranscript() {
        let app = launchOnSeededMeeting()
        defer { app.terminate() }

        let menu = app.control(withIdentifier: "detail-export-menu")
        XCTAssertTrue(menu.waitForExistenceFast(timeout: 10))
        menu.click()
        let recapItem = app.menuItems["detail-share-recap"]
        XCTAssertTrue(
            recapItem.waitForExistenceFast(timeout: 5),
            "a summarized meeting must offer the recap")
        recapItem.click()

        XCTAssertTrue(
            app.control(withIdentifier: "recap-title").waitForExistenceFast(timeout: 10),
            "the recap opens for review instead of sending anything")
        let editor = app.control(withIdentifier: "recap-body")
        XCTAssertTrue(editor.waitForExistenceFast(timeout: 5))
        let draft = (editor.value as? String) ?? ""
        XCTAssertTrue(
            draft.contains("Pendientes"),
            "the seeded Spanish summary produces a Spanish recap, saw: \(draft)")
        XCTAssertTrue(
            draft.contains("Ana"),
            "open commitments carry their owner")
        XCTAssertFalse(
            draft.contains("Revisemos el presupuesto de transcripción."),
            "the recap is summary-derived: no transcript line may appear in it")
        XCTAssertTrue(app.control(withIdentifier: "recap-copy").exists)
        XCTAssertTrue(app.control(withIdentifier: "recap-privacy-note").exists)
        attachScreenshot(of: app, named: "meeting-detail-share-recap")
        app.control(withIdentifier: "recap-done").click()
    }

    /// The Structure submenu must offer every seeded template — including
    /// discovery, postmortem, and retro — with the sections each one
    /// produces visible before generating.
    @MainActor
    func testStructureMenuOffersSeededTemplates() {
        let app = launchOnSeededMeeting()
        defer { app.terminate() }

        let menu = app.control(withIdentifier: "detail-regenerate-menu")
        XCTAssertTrue(
            menu.waitForExistenceFast(timeout: 10),
            "a summarized meeting must offer the regenerate menu")
        XCTAssertTrue(app.prepareForInteraction())
        XCTAssertTrue(
            menu.waitForStableFrame(timeout: 5),
            "the localized regenerate menu must settle before opening")
        menu.click()
        let structure = app.menuItems["detail-structure-menu"]
        guard structure.waitForExistenceFast(timeout: 5) else {
            XCTFail("the regenerate menu must offer the Structure submenu")
            return
        }
        structure.click()
        // Every built-in id, not just the new ones: the submenu renders
        // `Recipe.all + custom()`, so a template silently dropping out of
        // the catalog is exactly the regression this guards.
        for id in [
            "general", "standup", "one-on-one", "planning", "interview",
            "discovery", "postmortem", "retro"
        ] {
            XCTAssertTrue(
                app.menuItems["detail-structure-\(id)"].waitForExistenceFast(timeout: 5),
                "the Structure submenu must seed the \(id) template")
        }
        // Close without regenerating.
        app.typeKey(.escape, modifierFlags: [])
        app.typeKey(.escape, modifierFlags: [])
    }

    /// Marking in/out reveals the clip export button (M11). Advances the
    /// playhead by playing, so it doesn't depend on clicking a transcript
    /// line (dimmed/clipped in the focus carousel).
    @MainActor
    func testClipMarkingRevealsExport() {
        let app = launchOnSeededMeeting()
        defer { app.terminate() }

        XCTAssertTrue(app.buttons["player-play-pause"].waitForExistenceFast(timeout: 15))
        app.buttons["player-play-pause"].click()  // play → the playhead moves
        app.buttons["clip-mark-start"].click()
        let currentTime = app.control(withIdentifier: "player-current-time")
        let clipStartTime = String(describing: currentTime.value)
        XCTAssertTrue(
            currentTime.waitForValueChange(from: clipStartTime, timeout: 5),
            "the playhead must advance before marking a non-empty clip")
        app.buttons["clip-mark-end"].click()  // end after start → valid range

        XCTAssertTrue(
            app.buttons["clip-export"].waitForExistenceFast(timeout: 5),
            "marking a valid in/out range must reveal the export button")
    }
}
