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
            scaleSegmentCount: 5_000,
            scaleAutoSummaryUpdate: true)
        defer { app.terminate() }
        app.launchPortavoz()

        XCTAssertTrue(
            app.staticTexts["Scale baseline · 2 h · 5000 segments"]
                .waitForExistence(timeout: 30),
            "the disposable 2-hour fixture must navigate to Meeting Detail")
        XCTAssertTrue(
            app.control(withIdentifier: "detail-transcript-title")
                .waitForExistence(timeout: 10),
            "Meeting Detail must render first content for 5,000 segments")
        XCTAssertTrue(
            app.control(withIdentifier: "detail-chapters").waitForExistence(timeout: 10),
            "the scale detail must complete its chapter projection")
        XCTAssertTrue(
            app.staticTexts["Scale baseline summary revision 2."]
                .waitForExistence(timeout: 15),
            "the scoped summary observation must update without replacing the detail route")
        attachScreenshot(of: app, named: "meeting-detail-scale-5000-segments")
    }

    @MainActor
    func testTwentyThousandSegmentDetailRendersFromDisposableScaleFixture() {
        let app = XCUIApplication.portavoz(
            seedScale: true,
            scaleSegmentCount: 20_000,
            scaleAutoSummaryUpdate: true)
        defer { app.terminate() }
        app.launchPortavoz()

        XCTAssertTrue(
            app.staticTexts["Scale baseline · 2 h · 20000 segments"]
                .waitForExistence(timeout: 40),
            "the disposable 20,000-segment fixture must navigate to Meeting Detail")
        XCTAssertTrue(
            app.control(withIdentifier: "detail-transcript-title")
                .waitForExistence(timeout: 15),
            "Meeting Detail must render first content for 20,000 segments")
        XCTAssertTrue(
            app.control(withIdentifier: "detail-chapters").waitForExistence(timeout: 15),
            "the 20,000-segment detail must complete its chapter projection")
        XCTAssertTrue(
            app.staticTexts["Scale baseline summary revision 2."]
                .waitForExistence(timeout: 15),
            "the 20,000-segment detail must stay subscribed to scoped summary updates")
        attachScreenshot(of: app, named: "meeting-detail-scale-20000-segments")
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
        XCTAssertTrue(meeting.exists, "the seeded meeting must appear in the library")
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
                .waitForExistence(timeout: 10),
            "a summary generated before the correction must be labelled stale")
        XCTAssertTrue(
            app.control(withIdentifier: "detail-stale-summary-regenerate")
                .waitForExistence(timeout: 5),
            "the stale summary must expose explicit on-demand regeneration")
        XCTAssertFalse(
            app.buttons["detail-thin-summary-suggestion"].exists,
            "a stale summary must not compete with an unrelated thin-summary suggestion")
        XCTAssertTrue(
            app.control(
                withIdentifier:
                    "apuntador-card-B5F00000-0000-4000-8000-000000000002-stale")
                .waitForExistence(timeout: 10),
            "an Apuntador answer generated before the correction must be labelled stale")
        XCTAssertTrue(
            app.buttons["detail-apuntador-refresh"].waitForExistence(timeout: 5),
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
            refresh.waitForExistence(timeout: 10),
            "the stale Apuntador snapshot must offer explicit regeneration")
        XCTAssertTrue(
            refresh.waitForStableFrame(timeout: 5),
            "the refresh control must settle before activation")
        refresh.click()

        XCTAssertTrue(
            app.staticTexts["El rollout corregido queda para el lunes."]
                .waitForExistence(timeout: 10),
            "the refreshed answer must come from the corrected transcript projection")
        XCTAssertFalse(
            app.control(
                withIdentifier:
                    "apuntador-card-B5F00000-0000-4000-8000-000000000002-stale")
                .exists,
            "the stale card must be replaced only after current publication succeeds")
        XCTAssertFalse(
            app.buttons["detail-apuntador-refresh"].exists,
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
            app.staticTexts[expectedError].waitForExistence(timeout: 10),
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
            correct.waitForExistence(timeout: 10),
            "a stable accepted source row must expose its correction action")
        XCTAssertTrue(
            correct.waitForStableFrame(timeout: 5),
            "the correction action must settle before activation")
        XCTAssertGreaterThanOrEqual(
            correct.frame.width,
            28,
            "the correction action must expose a usable pointer target")
        XCTAssertGreaterThanOrEqual(
            correct.frame.height,
            28,
            "the correction action must expose a usable pointer target")
        correct.click()

        let editor = app.control(withIdentifier: "transcript-correction-editor")
        XCTAssertTrue(
            editor.waitForExistence(timeout: 5),
            "text and speaker editing must use one focused accessible surface")
        let originalEvidence = app.control(
            withIdentifier: "transcript-correction-original-evidence")
        XCTAssertTrue(originalEvidence.waitForExistence(timeout: 5))
        originalEvidence.click()
        let acceptedEvidence = app.staticTexts[
            "El rollout del modelo queda para el viernes."]
        XCTAssertTrue(
            acceptedEvidence.waitForExistence(timeout: 5),
            "the accepted transcript must remain available as immutable evidence")

        let textEditor = app.textViews["transcript-correction-text"]
        XCTAssertTrue(textEditor.waitForExistence(timeout: 5))
        textEditor.click()
        textEditor.typeKey("a", modifierFlags: .command)
        textEditor.typeText("El rollout del modelo queda para el lunes.")
        let speakerPicker = app.popUpButtons["transcript-correction-speaker"]
        XCTAssertTrue(speakerPicker.waitForExistence(timeout: 5))
        speakerPicker.click()
        let localSpeaker = app.menuItems["Me"]
        XCTAssertTrue(
            localSpeaker.waitForExistence(timeout: 5),
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
            correctedReading.waitForExistence(timeout: 10),
            "the composed Meeting Detail reading must update after persistence")
        XCTAssertTrue(correct.waitForExistence(timeout: 5))
        correct.click()
        let undo = app.buttons["transcript-correction-undo"]
        XCTAssertTrue(
            undo.waitForExistence(timeout: 5),
            "an active correction must expose durable restore-based undo")
        undo.click()

        let restoredReading = transcript.descendants(matching: .staticText)
            .matching(NSPredicate(
                format: "label == %@ OR value == %@",
                "El rollout del modelo queda para el viernes.",
                "El rollout del modelo queda para el viernes."))
            .firstMatch
        XCTAssertTrue(
            restoredReading.waitForExistence(timeout: 10),
            "undo must restore the accepted reading without deleting history")
    }

    @MainActor
    func testTranscriptStructuralCorrectionsSplitMergeHideAndRestoreEvidence() {
        let app = launchOnSeededMeeting()
        defer { app.terminate() }

        let sourceID = "B5B00000-0000-4000-8000-000000000002"
        let neighborID = "B5F00000-0000-4000-8000-000000000001"
        let correct = app.buttons["transcript-correct-\(sourceID)"]
        XCTAssertTrue(correct.waitForExistence(timeout: 10))
        XCTAssertTrue(correct.waitForStableFrame(timeout: 5))
        correct.click()

        let split = app.buttons["transcript-structure-split"]
        XCTAssertTrue(
            split.waitForExistence(timeout: 5),
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
            app.staticTexts["El rollout del modelo"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["queda para el viernes."].exists)
        let splitCorrection = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@",
            "transcript-correct-\(sourceID)-")).firstMatch
        XCTAssertTrue(
            splitCorrection.waitForExistence(timeout: 5),
            "each visible split part must retain a unique correction route")
        splitCorrection.click()
        let splitUndo = app.buttons["transcript-structure-undo"]
        XCTAssertTrue(splitUndo.waitForExistence(timeout: 5))
        splitUndo.click()

        XCTAssertTrue(
            app.staticTexts["El rollout del modelo queda para el viernes."]
                .waitForExistence(timeout: 5),
            "restoring a split must recover the exact accepted line")
        XCTAssertTrue(correct.waitForExistence(timeout: 5))
        correct.click()

        let merge = app.buttons["transcript-structure-merge-\(neighborID)"]
        XCTAssertTrue(
            merge.waitForExistence(timeout: 5),
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
            ].waitForExistence(timeout: 5),
            "an explicit merge must preserve both accepted texts")

        // Structural search uses the merge's stable composed-row identity,
        // so a query may span the two accepted source boundaries and still
        // navigate to the exact first timestamp.
        let search = app.textFields["library-search-field"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.click()
        search.typeText("viernes cuándo")
        let structuralHit = app.descendants(matching: .any)
            .matching(NSPredicate(
                format: "identifier BEGINSWITH 'library-search-hit-'"))
            .firstMatch
        XCTAssertTrue(
            structuralHit.waitForExistence(timeout: 10),
            "a merge must be searchable across accepted source boundaries")
        structuralHit.click()
        let currentTime = app.staticTexts["player-current-time"]
        XCTAssertTrue(currentTime.waitForExistence(timeout: 5))
        let mergedSeek = expectation(
            for: NSPredicate(format: "value == '0:03'"),
            evaluatedWith: currentTime)
        wait(for: [mergedSeek], timeout: 10)

        search.click()
        search.typeKey("a", modifierFlags: .command)
        search.typeKey(.delete, modifierFlags: [])
        XCTAssertTrue(correct.waitForExistence(timeout: 5))
        correct.click()
        let undo = app.buttons["transcript-structure-undo"]
        XCTAssertTrue(
            undo.waitForExistence(timeout: 5),
            "merged evidence must expose durable restore-based undo")
        undo.click()

        XCTAssertTrue(
            app.staticTexts["El rollout del modelo queda para el viernes."]
                .waitForExistence(timeout: 5))
        search.click()
        search.typeText("viernes")
        let acceptedHit = app.descendants(matching: .any)
            .matching(NSPredicate(
                format: "identifier BEGINSWITH 'library-search-hit-'"))
            .firstMatch
        XCTAssertTrue(
            acceptedHit.waitForExistence(timeout: 10),
            "restore-based merge undo must reactivate accepted search identity")
        XCTAssertTrue(correct.waitForExistence(timeout: 5))
        correct.click()
        let hide = app.buttons["transcript-structure-suppress"]
        XCTAssertTrue(hide.waitForExistence(timeout: 5))
        hide.click()
        app.buttons["transcript-structure-confirm"].click()

        let suppressed = expectation(
            for: NSPredicate(format: "exists == false"),
            evaluatedWith: acceptedHit)
        wait(for: [suppressed], timeout: 10)

        let hiddenLines = app.buttons["transcript-hidden-lines"]
        XCTAssertTrue(
            hiddenLines.waitForExistence(timeout: 5),
            "suppressed speech must remain discoverable as hidden evidence")
        hiddenLines.click()
        let hiddenSheet = app.control(withIdentifier: "transcript-hidden-lines-sheet")
        XCTAssertTrue(hiddenSheet.waitForExistence(timeout: 5))
        XCTAssertTrue(hiddenSheet.staticTexts[
            "El rollout del modelo queda para el viernes."
        ].exists)
        let restore = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH 'transcript-hidden-restore-'"
        )).firstMatch
        XCTAssertTrue(restore.waitForExistence(timeout: 5))
        restore.click()

        XCTAssertTrue(
            app.staticTexts["El rollout del modelo queda para el viernes."]
                .waitForExistence(timeout: 5),
            "restore must recover the accepted row without erasing history")
        XCTAssertTrue(
            acceptedHit.waitForExistence(timeout: 10),
            "restoring hidden speech must reactivate its accepted search result")
    }

    @MainActor
    func testUnnamedSpeakerOffersExplicitNameSuggestions() {
        let app = launchOnSeededMeeting(unnamedSpeaker: true)
        defer { app.terminate() }

        XCTAssertTrue(
            app.control(withIdentifier: "detail-header-section")
                .waitForExistence(timeout: 10),
            "meeting identity and participants must stay inside the header section")
        XCTAssertTrue(
            app.control(withIdentifier: "detail-suggest-names")
                .waitForExistence(timeout: 10),
            "an unnamed remote speaker must retain the explicit suggestion action")
        XCTAssertFalse(
            app.control(withIdentifier: "cast-speaker-Me").label.isEmpty,
            "the local speaker remains distinct from remote naming candidates")
        // Let the NavigationSplitView selection animation finish so visual
        // evidence never captures the title/sidebar midway through transition.
        Thread.sleep(forTimeInterval: 0.5)
        attachScreenshot(of: app, named: "meeting-name-suggestions")
    }

    @MainActor
    func testAISuggestionsCanBeIgnoredAndPlaybackOffersClearMix() {
        let app = launchOnSeededMeeting(
            unnamedSpeaker: true,
            aiSuggestions: true)
        defer { app.terminate() }

        let titleDismiss = app.buttons["detail-title-suggestion-dismiss"]
        XCTAssertTrue(titleDismiss.waitForExistence(timeout: 10))
        titleDismiss.click()
        XCTAssertFalse(app.buttons["detail-title-suggestion"].exists)

        let recipeDismiss = app.buttons["detail-recipe-suggestion-dismiss"]
        XCTAssertTrue(recipeDismiss.waitForExistence(timeout: 10))
        recipeDismiss.click()
        XCTAssertFalse(app.buttons["detail-recipe-suggestion"].exists)

        let suggestNames = app.control(withIdentifier: "detail-suggest-names")
        XCTAssertTrue(suggestNames.waitForExistence(timeout: 5))
        suggestNames.click()
        let nameDismiss = app.buttons["detail-name-suggestion-dismiss-S1"]
        XCTAssertTrue(nameDismiss.waitForExistence(timeout: 10))
        nameDismiss.click()
        XCTAssertFalse(app.buttons["detail-name-suggestion-S1"].exists)

        XCTAssertTrue(
            app.control(withIdentifier: "player-clear-playback")
                .waitForExistence(timeout: 10),
            "two-channel playback must expose the reversible clear mix")
        attachScreenshot(of: app, named: "dismissible-ai-suggestions-and-clear-playback")
    }

    @MainActor
    func testFailedDurableProcessingOffersOneRecoveryAction() {
        let app = launchOnSeededMeeting(processingFailure: true)
        defer { app.terminate() }

        XCTAssertTrue(
            app.control(withIdentifier: "detail-trust-section")
                .waitForExistence(timeout: 10),
            "durable recovery and privacy state must stay inside the trust section")
        XCTAssertTrue(
            app.control(withIdentifier: "detail-processing-status")
                .waitForExistence(timeout: 10),
            "a durable failure must be visible beside the meeting")
        let retry = app.buttons["detail-retry-processing"]
        XCTAssertTrue(
            retry.waitForExistence(timeout: 5),
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
            notice.waitForExistence(timeout: 10),
            "a cancelled automatic summary must be visible, not silently absent")
        XCTAssertTrue(
            app.buttons["detail-generate-summary"].waitForExistence(timeout: 10),
            "the explicit generation route must stay available beside the notice")
        XCTAssertTrue(
            app.prepareForInteraction(),
            "Portavoz must own the foreground before capturing the recovery state")
        attachScreenshot(of: app, named: "meeting-detail-abandoned-summary")
    }

    @MainActor
    func testSequoiaSummaryFailureOpensExactSetupAndExplainsApuntador() {
        let app = launchOnSeededMeeting(
            withoutSummary: true,
            simulateSequoiaCapabilities: true,
            summaryEngine: "appleOnDevice")
        defer { app.terminate() }

        let generate = app.buttons["detail-generate-summary"]
        XCTAssertTrue(
            generate.waitForExistence(timeout: 10),
            "a meeting without a summary must offer generation")
        generate.click()

        let openSettings = app.buttons["detail-summary-open-settings"]
        XCTAssertTrue(
            openSettings.waitForExistence(timeout: 10),
            "an unavailable Apple engine must offer an actionable Settings route")
        openSettings.click()

        XCTAssertTrue(
            app.control(withIdentifier: "settings-summary-engine-picker")
                .waitForExistence(timeout: 10),
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
        XCTAssertTrue(
            app.control(withIdentifier: "settings-apuntador-status")
                .waitForExistence(timeout: 5),
            "the voice pane must explain Apuntador's real platform requirement")
        XCTAssertFalse(
            app.control(withIdentifier: "settings-apuntador-enabled").exists,
            "Sequoia must not expose a toggle that cannot work")
        attachScreenshot(of: app, named: "sequoia-apuntador-requirements")
    }

    @MainActor
    func testTabbedSummaryRevealsTheCoauthoringBullet() {
        let app = launchOnSeededMeeting()
        defer { app.terminate() }

        XCTAssertTrue(
            app.control(withIdentifier: "detail-generated-document")
                .waitForExistence(timeout: 10),
            "generated claims and commitments must stay inside one document section")
        // The transcript rendered (this line is unique to the transcript).
        XCTAssertTrue(
            app.staticTexts["Revisemos el presupuesto de transcripción."]
                .waitForExistence(timeout: 10),
            "the detail view must render the seeded transcript")

        // The default "Summary" tab shows the intro/overview.
        XCTAssertTrue(
            app.staticTexts["El equipo revisó el presupuesto y fijó el rollout."]
                .waitForExistence(timeout: 10),
            "the summary's Summary tab must show the overview")
        XCTAssertFalse(
            app.control(withIdentifier: "summary-tab-2").exists,
            "the canonical commitment appendix must not duplicate the typed To-dos tab")

        // The ▸ coauthoring marker lives under the Decisiones section, now
        // behind its own tab — switching to it reveals the bullet.
        let decisionsTab = app.control(withIdentifier: "summary-tab-1")
        XCTAssertTrue(app.prepareForInteraction())
        XCTAssertTrue(decisionsTab.waitForStableFrame(timeout: 5))
        decisionsTab.click()
        XCTAssertTrue(
            app.staticTexts["▸"].waitForExistence(timeout: 5),
            "the Decisiones tab must reveal the ▸ coauthored bullet (D28)")

        // A real mutation crosses MeetingDetailModel's client and the scoped
        // summary observation returns the completed count to the same view.
        let todosTab = app.control(withIdentifier: "summary-tab-todos")
        XCTAssertTrue(todosTab.waitForStableFrame(timeout: 5))
        todosTab.click()
        let actionItem = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'action-item-'"))
            .firstMatch
        guard actionItem.waitForExistence(timeout: 10) else {
            XCTFail("the seeded action item must expose its stable control boundary")
            return
        }
        XCTAssertTrue(actionItem.waitForStableFrame(timeout: 5))
        actionItem.click()
        let updatedTodosTab = app.control(withIdentifier: "summary-tab-todos")
        let completed = expectation(
            for: NSPredicate(format: "label CONTAINS '1/1'"),
            evaluatedWith: updatedTodosTab)
        wait(for: [completed], timeout: 10)
        attachScreenshot(of: app, named: "meeting-detail-generated-document")
    }

    @MainActor
    func testMyNotesSectionShowsRawNotesAndOffersEnhancement() {
        let app = launchOnSeededMeeting()
        defer { app.terminate() }

        // Presence-only scope: clicking Enhance would invoke a real model
        // provider, which is not deterministic on a runner. The seeded raw
        // note and the section's stable controls are.
        XCTAssertTrue(
            app.control(withIdentifier: "detail-notes-section")
                .waitForExistence(timeout: 10),
            "notes must retain one explicit presentation boundary")
        XCTAssertTrue(
            app.control(withIdentifier: "detail-notes-title")
                .waitForExistence(timeout: 10),
            "a meeting with notes must surface the My notes section")
        XCTAssertTrue(
            app.staticTexts["revisar budget Q3"].exists,
            "the raw seeded note is shown verbatim before any enhancement")
        XCTAssertTrue(
            app.control(withIdentifier: "detail-enhance-notes")
                .waitForExistence(timeout: 5),
            "a meeting with transcript and notes must offer the enhance menu")
        attachScreenshot(of: app, named: "meeting-detail-my-notes")
    }

    @MainActor
    func testSummarySourceJumpsToItsTranscriptAndAudio() {
        let app = launchOnSeededMeeting()
        defer { app.terminate() }

        let source = app.control(withIdentifier: "summary-evidence-0")
        guard source.waitForExistence(timeout: 10) else {
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
            citedRow.waitForExistence(timeout: 5),
            "source navigation must focus the exact persisted transcript segment")
        let focused = expectation(
            for: NSPredicate(format: "isSelected == true"),
            evaluatedWith: citedRow)
        wait(for: [focused], timeout: 5)

        let currentTime = app.control(withIdentifier: "player-current-time")
        let seeked = expectation(
            for: NSPredicate(format: "value == '0:03'"),
            evaluatedWith: currentTime)
        wait(for: [seeked], timeout: 5)
        attachScreenshot(of: app, named: "meeting-detail-summary-evidence")
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
        XCTAssertTrue(decisions.waitForExistence(timeout: 10))
        decisions.click()

        let confirm = app.control(withIdentifier: "summary-decision-0-0-confirm")
        XCTAssertTrue(
            confirm.waitForExistence(timeout: 5),
            "an unconfirmed decision over current evidence offers the gesture")
        confirm.click()

        let sheet = app.control(withIdentifier: "decision-confirm-sheet")
        XCTAssertTrue(sheet.waitForExistence(timeout: 5))
        let statement = app.control(withIdentifier: "decision-confirm-statement")
        XCTAssertTrue(statement.exists, "the sheet quotes the exact statement")

        let field = app.textFields["decision-confirm-topic-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.click()
        field.typeText("atlasrollout")
        app.control(withIdentifier: "decision-confirm-submit").click()

        let badge = app.control(withIdentifier: "summary-decision-0-0-confirmed")
        XCTAssertTrue(
            badge.waitForExistence(timeout: 10),
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
            retract.waitForExistence(timeout: 5),
            "each linked topic offers its withdrawal from the badge menu")
        retract.click()

        let unlinked = app.control(withIdentifier: "summary-decision-0-0-confirmed")
        let topicGone = expectation(
            for: NSPredicate(format: "NOT (label CONTAINS %@)", "atlasrollout"),
            evaluatedWith: unlinked)
        wait(for: [topicGone], timeout: 10)
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
            menu.waitForExistence(timeout: 10),
            "a processed meeting with a summary must surface skill offers")
        XCTAssertTrue(app.prepareForInteraction())
        XCTAssertTrue(
            menu.waitForStableFrame(timeout: 5),
            "the localized skill menu must settle before opening")

        // 1 · Preview: the sheet shows the exact draft before any claim.
        menu.click()
        let recapItem = app.menuItems["skill-offer-recap-draft"]
        guard recapItem.waitForExistence(timeout: 5) else {
            XCTFail("the open skill menu must expose the recap proposal")
            return
        }
        recapItem.click()
        let sheet = app.control(withIdentifier: "skill-confirm-sheet")
        XCTAssertTrue(sheet.waitForExistence(timeout: 5))
        let cancel = app.buttons["skill-confirm-cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        XCTAssertTrue(cancel.isEnabled)
        let body = app.control(withIdentifier: "skill-confirm-preview-body")
        XCTAssertTrue(body.waitForExistence(timeout: 5))
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
        guard receipt.waitForExistence(timeout: 10) else {
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
            if emailDismiss.waitForExistence(timeout: 3) { break }
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
        XCTAssertTrue(gistDismiss.waitForExistence(timeout: 5))
        gistDismiss.click()
        XCTAssertTrue(menu.waitForStableFrame(timeout: 5))
        menu.click()
        XCTAssertTrue(exportDismiss.waitForExistence(timeout: 5))
        exportDismiss.click()
        let gone = expectation(
            for: NSPredicate(format: "exists == false"),
            evaluatedWith: menu)
        wait(for: [gone], timeout: 5)
        attachScreenshot(of: app, named: "meeting-detail-skill-receipt")
    }

    /// D327 — the external boundary stays review-first: exact summary-derived
    /// text, no inferred recipients, an explicit sync warning, and a separate
    /// Send action in the user's email app. The disposable UI adapter traverses
    /// the production proposal/effect path without launching the host client.
    @MainActor
    func testEmailRecapSkillPreviewsAndHandsOffWithoutSending() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString("email-skill-sentinel", forType: .string)
        let app = launchOnSeededMeeting()
        defer { app.terminate() }

        let menu = app.control(withIdentifier: "skill-offer-menu")
        XCTAssertTrue(menu.waitForStableFrame(timeout: 10))
        menu.click()
        let email = app.menuItems["skill-offer-email-recap-draft"]
        guard email.waitForExistence(timeout: 5) else {
            XCTFail("the meeting must expose its review-first email draft")
            return
        }
        email.click()

        let sheet = app.control(withIdentifier: "skill-confirm-sheet")
        XCTAssertTrue(sheet.waitForExistence(timeout: 5))
        let subjectElement = app.control(
            withIdentifier: "skill-confirm-preview-subject")
        let bodyElement = app.control(
            withIdentifier: "skill-confirm-preview-body")
        XCTAssertTrue(subjectElement.waitForExistence(timeout: 5))
        XCTAssertTrue(bodyElement.waitForExistence(timeout: 5))
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
        XCTAssertTrue(recipientPolicy.waitForExistence(timeout: 5))
        XCTAssertTrue(boundary.waitForExistence(timeout: 5))
        let expectedRecipientCopy = UITestLocale.environmentLocale == "es"
            ? "Sin destinatarios — los eliges en tu app de correo."
            : "No recipients — you choose them in your email app."
        let recipientText = accessibleText(of: recipientPolicy)
        XCTAssertTrue(
            recipientText.contains(expectedRecipientCopy),
            "expected recipient policy in accessible text, got: \(recipientText)")
        let expectedBoundaryCopy = UITestLocale.environmentLocale == "es"
            ? "Portavoz nunca lo envía."
            : "Portavoz never sends it."
        let boundaryText = accessibleText(of: boundary)
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
            receipt.waitForExistence(timeout: 10),
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

        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(app.openSettingsWindow())
        XCTAssertTrue(app.openSettingsCategory(
            "settings-category-skills",
            revealing: "settings-skills-pause-all"))
        let settingsReceipt = app.control(
            withIdentifier: "settings-skill-receipt-email-recap-draft")
        XCTAssertTrue(
            settingsReceipt.waitForExistence(timeout: 10),
            "Skills Settings must project the same durable handoff receipt")
        let expectedSettingsReceipt = UITestLocale.environmentLocale == "es"
            ? "Entrega solicitada"
            : "Handoff requested"
        let settingsReceiptText = accessibleText(of: settingsReceipt)
        XCTAssertTrue(
            settingsReceiptText.contains(expectedSettingsReceipt),
            "Settings must describe the external boundary as a handoff; got: \(settingsReceiptText)")
    }

    /// D328 — exact canonical Markdown is visible before the single GitHub
    /// mutation. The disposable gateway writes the real content-free egress
    /// receipt and returns a provider-shaped URL without touching network.
    @MainActor
    func testSecretGistSkillPreviewsPublishesAndReceiptsExactDocument() {
        let app = launchOnSeededMeeting()
        defer { app.terminate() }

        let menu = app.control(withIdentifier: "skill-offer-menu")
        XCTAssertTrue(menu.waitForStableFrame(timeout: 10))
        menu.click()
        let gist = app.menuItems["skill-offer-secret-gist-publish"]
        guard gist.waitForExistence(timeout: 5) else {
            XCTFail("the meeting must expose one review-first Gist proposal")
            return
        }
        gist.click()

        let sheet = app.control(withIdentifier: "skill-confirm-sheet")
        XCTAssertTrue(sheet.waitForExistence(timeout: 5))
        let destination = app.control(
            withIdentifier: "skill-confirm-gist-destination")
        let body = app.control(withIdentifier: "skill-confirm-preview-body")
        let boundary = app.control(
            withIdentifier: "skill-confirm-gist-boundary")
        XCTAssertTrue(destination.waitForExistence(timeout: 5))
        XCTAssertTrue(body.waitForExistence(timeout: 5))
        XCTAssertTrue(boundary.waitForExistence(timeout: 5))
        let destinationText = accessibleText(of: destination)
        XCTAssertTrue(destinationText.contains("test-meeting.md"))
        XCTAssertTrue(destinationText.contains("api.github.com"))
        let bodyText = accessibleText(of: body)
        XCTAssertTrue(bodyText.contains("# Test meeting"))
        XCTAssertTrue(
            bodyText.contains("El rollout del modelo queda para el viernes."),
            "the exact canonical document must include the seeded transcript")
        let expectedBoundary = UITestLocale.environmentLocale == "es"
            ? "Cualquier persona con el enlace puede leerlo."
            : "Anyone with the link can read it."
        XCTAssertTrue(
            accessibleText(of: boundary).contains(expectedBoundary),
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
            resultURL.waitForExistence(timeout: 10),
            "successful publication must return its transient provider URL")
        XCTAssertTrue(accessibleText(of: resultURL).contains(
            "https://gist.github.com/portavoz/skill-preview"))
        XCTAssertTrue(app.buttons["gist-result-copy-link"].exists)
        XCTAssertTrue(app.buttons["gist-result-open-link"].exists)
        let dismissResult = app.buttons["gist-result-dismiss"]
        XCTAssertTrue(dismissResult.exists)
        dismissResult.click()

        let receipt = app.control(
            withIdentifier: "skill-receipt-secret-gist-publish")
        XCTAssertTrue(
            receipt.waitForExistence(timeout: 10),
            "the remote mutation must leave one durable Skill receipt")
        let expectedReceipt = UITestLocale.environmentLocale == "es"
            ? "publicado"
            : "published"
        XCTAssertTrue(
            receipt.label.localizedCaseInsensitiveContains(expectedReceipt))
        let remoteReceipts = app.staticTexts.matching(NSPredicate(
            format: "identifier BEGINSWITH 'privacy-remote-event-'"))
        XCTAssertTrue(
            remoteReceipts.element(boundBy: 1).waitForExistence(timeout: 10),
            "the same run must record the content-free GitHub egress attempt")
        let remoteReceiptTexts = (0..<remoteReceipts.count).map {
            accessibleText(of: remoteReceipts.element(boundBy: $0))
        }
        XCTAssertTrue(
            remoteReceiptTexts.contains { $0.contains("api.github.com") },
            "the egress ledger must include api.github.com; got: \(remoteReceiptTexts)")

        menu.click()
        XCTAssertFalse(
            app.menuItems["skill-offer-secret-gist-publish"].exists,
            "one remote creation must retire its proposal")
        XCTAssertTrue(app.menuItems["skill-offer-recap-draft"].exists)
        XCTAssertTrue(app.menuItems["skill-offer-email-recap-draft"].exists)
        XCTAssertTrue(app.menuItems["skill-offer-package-export"].exists)
        attachScreenshot(of: app, named: "meeting-detail-secret-gist-receipts")

        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(app.openSettingsWindow())
        XCTAssertTrue(app.openSettingsCategory(
            "settings-category-skills",
            revealing: "settings-skills-pause-all"))
        let settingsReceipt = app.control(
            withIdentifier: "settings-skill-receipt-secret-gist-publish")
        XCTAssertTrue(settingsReceipt.waitForExistence(timeout: 10))
        let expectedSettingsStatus = UITestLocale.environmentLocale == "es"
            ? "Gist secreto publicado"
            : "Secret Gist published"
        XCTAssertTrue(
            accessibleText(of: settingsReceipt).contains(expectedSettingsStatus))
    }

    @MainActor
    private func accessibleText(of element: XCUIElement) -> String {
        [element.label, element.value as? String]
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
        XCTAssertTrue(recap.waitForExistence(timeout: 5))
        recap.click()

        let sheet = app.control(withIdentifier: "skill-confirm-sheet")
        let submit = app.buttons["skill-confirm-submit"]
        guard sheet.waitForExistence(timeout: 10) else {
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
            failure.waitForExistence(timeout: 10),
            "the recoverable failure must be visible inside the open sheet")
        let retryReady = expectation(
            for: NSPredicate(format: "exists == true AND enabled == true"),
            evaluatedWith: submit)
        wait(for: [retryReady], timeout: 10)
        XCTAssertTrue(
            sheet.exists,
            "a failed effect must keep its exact preview available for retry")

        XCTAssertTrue(app.prepareForInteraction())
        XCTAssertTrue(submit.waitForStableFrame(timeout: 5))
        submit.click()
        let receipt = app.control(withIdentifier: "skill-receipt-recap-draft")
        XCTAssertTrue(
            receipt.waitForExistence(timeout: 10),
            "the retry must settle the original claim as succeeded")
        XCTAssertFalse(sheet.exists)
        XCTAssertEqual(
            NSPasteboard.general.string(forType: .string),
            "\(subject)\n\n\(body)",
            "retry must deliver the same preview that was confirmed")
        attachScreenshot(of: app, named: "meeting-detail-skill-retry-receipt")
    }

    @MainActor
    func testDecisionSourceJumpsToItsTranscriptAndAudio() {
        let app = launchOnSeededMeeting()
        defer { app.terminate() }

        let decisions = app.control(withIdentifier: "summary-tab-1")
        XCTAssertTrue(decisions.waitForExistence(timeout: 10))
        decisions.click()
        let source = app.control(
            withIdentifier: "summary-decision-0-0-evidence-0")
        guard source.waitForExistence(timeout: 5) else {
            XCTFail("the first decision must expose its exact transcript source")
            return
        }
        XCTAssertEqual(
            source.value as? String,
            "El rollout del modelo queda para el viernes.")
        source.click()

        let citedRow = app.control(
            withIdentifier: "transcript-segment-B5B00000-0000-4000-8000-000000000002")
        let focused = expectation(
            for: NSPredicate(format: "isSelected == true"),
            evaluatedWith: citedRow)
        wait(for: [focused], timeout: 5)
        let currentTime = app.control(withIdentifier: "player-current-time")
        let seeked = expectation(
            for: NSPredicate(format: "value == '0:03'"),
            evaluatedWith: currentTime)
        wait(for: [seeked], timeout: 5)
        attachScreenshot(of: app, named: "meeting-detail-decision-evidence")
    }

    @MainActor
    func testActionItemSourceJumpsToItsTranscriptAndAudio() {
        let app = launchOnSeededMeeting()
        defer { app.terminate() }

        let todos = app.control(withIdentifier: "summary-tab-todos")
        XCTAssertTrue(todos.waitForExistence(timeout: 10))
        todos.click()
        let source = app.control(
            withIdentifier:
                "summary-action-item-B5E00000-0000-4000-8000-000000000001-evidence-0")
        guard source.waitForExistence(timeout: 5) else {
            XCTFail("the action item must expose its exact transcript source")
            return
        }
        XCTAssertEqual(
            source.value as? String,
            "El rollout del modelo queda para el viernes.")
        source.click()

        let citedRow = app.control(
            withIdentifier: "transcript-segment-B5B00000-0000-4000-8000-000000000002")
        let focused = expectation(
            for: NSPredicate(format: "isSelected == true"),
            evaluatedWith: citedRow)
        wait(for: [focused], timeout: 5)
        let currentTime = app.control(withIdentifier: "player-current-time")
        let seeked = expectation(
            for: NSPredicate(format: "value == '0:03'"),
            evaluatedWith: currentTime)
        wait(for: [seeked], timeout: 5)
        attachScreenshot(of: app, named: "meeting-detail-action-item-evidence")
    }

    @MainActor
    func testCommitmentInboxRequiresEvidenceReviewBeforeConfirmation() {
        let app = launchOnSeededMeeting(commitmentInbox: true)
        defer { app.terminate() }

        let candidateID = "B5E00000-0000-4000-8000-000000000001"
        let inbox = app.control(withIdentifier: "detail-commitment-inbox")
        XCTAssertTrue(
            inbox.waitForExistence(timeout: 10),
            "an unconfirmed generated action item must enter the review inbox")
        XCTAssertTrue(
            app.control(withIdentifier: "commitment-\(candidateID)-owner-suggestion")
                .exists,
            "only an exact canonical participant link may prefill the owner")

        let evidence = app.control(
            withIdentifier: "commitment-\(candidateID)-evidence-0")
        XCTAssertTrue(
            evidence.waitForExistence(timeout: 5),
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
        XCTAssertTrue(artifacts.waitForExistence(timeout: 5))
        // The detail artifacts live in a fixed-height vertical viewport. The
        // evidence link can exist in the accessibility tree below that fold,
        // where XCUITest's implicit click scrolling incorrectly tries the
        // horizontal axis. A bounded vertical wheel sequence reaches the
        // candidate card across the supported test-window sizes.
        for _ in 0..<10 {
            artifacts.scroll(byDeltaX: 0, deltaY: -18)
        }
        XCTAssertTrue(
            evidence.waitForStableFrame(timeout: 5),
            "the review viewport must reveal the exact transcript evidence")
        evidence.click()
        let citedRow = app.control(
            withIdentifier: "transcript-segment-B5B00000-0000-4000-8000-000000000002")
        let focused = expectation(
            for: NSPredicate(format: "isSelected == true"),
            evaluatedWith: citedRow)
        wait(for: [focused], timeout: 5)
        let currentTime = app.control(withIdentifier: "player-current-time")
        let seeked = expectation(
            for: NSPredicate(format: "value == '0:03'"),
            evaluatedWith: currentTime)
        wait(for: [seeked], timeout: 5)

        let review = app.control(withIdentifier: "commitment-\(candidateID)-review")
        XCTAssertTrue(review.waitForStableFrame(timeout: 5))
        review.click()
        XCTAssertTrue(
            app.control(withIdentifier: "commitment-editor").waitForExistence(timeout: 5),
            "the user must get one explicit wording, owner, and deadline review boundary")
        let ownerPicker = app.control(withIdentifier: "commitment-editor-owner")
        XCTAssertTrue(ownerPicker.waitForExistence(timeout: 5))
        ownerPicker.click()
        let me = app.menuItems["commitment-owner-me"]
        XCTAssertTrue(
            me.waitForExistence(timeout: 5),
            "the local user must be distinct from an external person and an unassigned owner")
        me.click()
        attachScreenshot(of: app, named: "meeting-detail-commitment-self-assignment")
        app.control(withIdentifier: "commitment-editor-confirm").click()

        let removed = expectation(
            for: NSPredicate(format: "exists == false"),
            evaluatedWith: inbox)
        wait(for: [removed], timeout: 10)
    }

    @MainActor
    func testApuntadorAnswerSourceJumpsToItsTranscriptAndAudio() {
        let app = launchOnSeededMeeting()
        defer { app.terminate() }

        XCTAssertTrue(
            app.control(withIdentifier: "detail-apuntador-section")
                .waitForExistence(timeout: 10),
            "persisted Companion evidence must retain one accessible section boundary")
        let source = app.control(
            withIdentifier:
                "apuntador-card-B5F00000-0000-4000-8000-000000000002-answer-evidence-0")
        guard source.waitForExistence(timeout: 10) else {
            XCTFail("the Apuntador answer must expose its exact transcript source")
            return
        }
        XCTAssertEqual(
            source.value as? String,
            "El rollout del modelo queda para el viernes.")
        source.click()

        let citedRow = app.control(
            withIdentifier: "transcript-segment-B5B00000-0000-4000-8000-000000000002")
        let focused = expectation(
            for: NSPredicate(format: "isSelected == true"),
            evaluatedWith: citedRow)
        wait(for: [focused], timeout: 5)
        let currentTime = app.control(withIdentifier: "player-current-time")
        let seeked = expectation(
            for: NSPredicate(format: "value == '0:03'"),
            evaluatedWith: currentTime)
        wait(for: [seeked], timeout: 5)
        attachScreenshot(of: app, named: "meeting-detail-apuntador-evidence")
    }

    @MainActor
    func testSummaryFeedbackIsExplicitReversibleAndLocal() {
        let app = launchOnSeededMeeting()
        defer { app.terminate() }

        let unsupported = app.control(withIdentifier: "summary-feedback-unsupported")
        XCTAssertTrue(
            unsupported.waitForExistence(timeout: 10),
            "an evidenced overview must expose explicit review controls")
        XCTAssertTrue(
            unsupported.waitForStableFrame(),
            "the localized feedback control must finish layout before activation")
        unsupported.click()
        let selected = expectation(
            for: NSPredicate(format: "isSelected == true"),
            evaluatedWith: unsupported)
        wait(for: [selected], timeout: 5)
        XCTAssertTrue(
            app.control(withIdentifier: "summary-feedback-status").exists,
            "the unsupported assessment must stay visibly attached to the claim")

        app.control(withIdentifier: "summary-feedback-correction").click()
        let sheet = app.sheets.firstMatch
        XCTAssertTrue(
            sheet.waitForExistence(timeout: 5),
            "correction must use an explicit editor instead of rewriting generated text")
        let editor = sheet.textViews["summary-feedback-correction-text"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertTrue(editor.waitForStableFrame(timeout: 5))
        editor.click()
        editor.typeText("El rollout queda para el lunes tras QA")
        app.control(withIdentifier: "summary-feedback-save").click()

        XCTAssertTrue(
            app.staticTexts["El rollout queda para el lunes tras QA"]
                .waitForExistence(timeout: 5),
            "the saved correction must be visible without replacing the generated overview")
        XCTAssertTrue(
            app.staticTexts["El equipo revisó el presupuesto y fijó el rollout."].exists,
            "feedback must not mutate the immutable generated summary")
        attachScreenshot(of: app, named: "meeting-detail-summary-feedback")

        app.control(withIdentifier: "summary-feedback-clear").click()
        let cleared = expectation(
            for: NSPredicate(format: "exists == false"),
            evaluatedWith: app.control(withIdentifier: "summary-feedback-status"))
        wait(for: [cleared], timeout: 5)
    }

    @MainActor
    func testNamedSpeakerCanBeRememberedAsCanonicalPerson() {
        let app = launchOnSeededMeeting()
        defer { app.terminate() }

        let speaker = app.control(withIdentifier: "cast-speaker-S1")
        XCTAssertTrue(
            speaker.waitForExistence(timeout: 10),
            "the observed participant must expose a stable rename boundary")
        speaker.click()

        // SwiftUI's macOS alert bridge strips a TextField's custom AX
        // identifier. Scope the query to the alert sheet so we never type
        // into the library search field behind it.
        let field = app.sheets.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeText("Ana")
        app.control(withIdentifier: "speaker-rename-save").click()

        let remember = app.buttons["person-remember-offer"]
        XCTAssertTrue(
            remember.waitForExistence(timeout: 5),
            "a confirmed meeting-local name must offer explicit person memory")
        remember.click()

        let expectedValue = Locale.current.identifier.hasPrefix("es")
            ? "Vinculado a una persona recordada"
            : "Linked to a remembered person"
        let linked = expectation(
            for: NSPredicate(format: "value == %@", expectedValue),
            evaluatedWith: speaker)
        wait(for: [linked], timeout: 5)
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
            badge.waitForExistence(timeout: 10),
            "the active summary must expose its recipe-aware badge")
        XCTAssertEqual(
            badge.value as? String,
            "v1 · es · Standup",
            "the latest Standup snapshot must remain selected after Meeting Detail reloads")
        XCTAssertTrue(
            app.staticTexts["El resumen de standup sigue visible después de recargar."]
                .waitForExistence(timeout: 5),
            "reload must not replace the latest structured summary with the older General one")
    }

    @MainActor
    func testRightRailShowsHealthAndChapters() {
        let app = launchOnSeededMeeting()
        defer { app.terminate() }

        XCTAssertTrue(
            app.control(withIdentifier: "detail-secondary-rail")
                .waitForExistence(timeout: 10),
            "secondary review panels must retain one independently scrolling boundary")
        XCTAssertTrue(
            app.control(withIdentifier: "detail-meeting-health").waitForExistence(timeout: 10),
            "the right rail must show meeting health")
        XCTAssertTrue(
            app.control(withIdentifier: "detail-privacy-receipt").waitForExistence(timeout: 10),
            "the right rail must show the local privacy receipt")
        XCTAssertTrue(
            app.control(withIdentifier: "privacy-remote-event-0").exists,
            "the fixture's content-free remote summary attempt must be auditable")
        // The fixture acknowledges one sync generation, so the receipt must
        // also disclose the private iCloud copy — never an all-local claim.
        let syncDisclosure = app.control(withIdentifier: "detail-privacy-receipt-sync")
        XCTAssertTrue(
            syncDisclosure.exists,
            "the receipt must disclose the acknowledged private iCloud copy")
        let expectedSyncDescription = Locale.current.identifier.hasPrefix("es")
            ? "El texto de esta reunión se guardó en campos cifrados de tu base de datos privada de iCloud."
            : "This meeting's text was stored in encrypted fields in your private iCloud database."
        let localizedSyncValue = expectation(
            for: NSPredicate(format: "value == %@", expectedSyncDescription),
            evaluatedWith: syncDisclosure)
        wait(for: [localizedSyncValue], timeout: 5)
        // The refine control (now a menu with a per-meeting language override)
        // is present for a meeting that keeps its audio.
        XCTAssertTrue(
            app.control(withIdentifier: "detail-refine").exists,
            "the action row must offer the refine control")
        XCTAssertTrue(
            app.control(withIdentifier: "detail-transcript-section").exists,
            "the transcript must expose its correction-ready reading boundary")
        XCTAssertTrue(
            app.control(withIdentifier: "detail-chapters").exists,
            "the right rail must show the ✦ chapters (the seed has a second chapter)")
        // The second chapter is the 200 s turn — proving a real break was
        // found (the title itself truncates in the narrow rail).
        let laterChapter = app.control(withIdentifier: "chapter-200")
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
        let chapterSeeked = expectation(
            for: NSPredicate(format: "value != '0:00'"),
            evaluatedWith: currentTime)
        wait(for: [chapterSeeked], timeout: 5)
        // The persisted Apuntador cards (D26) render in the rail: the seed
        // has an answered card (askedAt 6) and an "asked you" ping (200).
        // These WAIT: the cards are fetched separately from the meeting
        // detail, so the section lands a beat after the rest of the rail.
        XCTAssertTrue(
            app.control(withIdentifier: "detail-apuntador").waitForExistence(timeout: 5),
            "the right rail must show the persisted Apuntador answers")
        XCTAssertTrue(
            app.control(withIdentifier: "apuntador-card-6").waitForExistence(timeout: 5),
            "the answered Apuntador card must render for review")

        attachScreenshot(of: app, named: "meeting-detail-privacy-receipt")
        attachScreenshot(of: app, named: "meeting-detail-transcript-navigation")
    }

    @MainActor
    func testFreshQualifyingMeetingShowsThePostMeetingMirror() {
        let app = launchOnSeededMeeting(justRecorded: true)
        defer { app.terminate() }

        XCTAssertTrue(
            app.control(withIdentifier: "mirror-card").waitForExistence(timeout: 10),
            "an opted-in fresh qualifying meeting must show its factual mirror")
        attachScreenshot(of: app, named: "meeting-detail-post-meeting-mirror")
    }

    @MainActor
    func testRunningRefineCanBeCanceledWithoutChangingTheTranscript() {
        let app = launchOnSeededMeeting(refineRunning: true)
        defer { app.terminate() }

        XCTAssertTrue(
            app.control(withIdentifier: "detail-actions").waitForExistence(timeout: 10),
            "meeting actions must retain one accessible section boundary")
        let refine = app.control(withIdentifier: "detail-refine")
        XCTAssertTrue(refine.waitForExistence(timeout: 10))
        let enteredRunningState = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == 'cancel'"),
            object: refine)
        XCTAssertEqual(
            XCTWaiter.wait(for: [enteredRunningState], timeout: 10),
            .completed,
            "the injected running refine must settle before cancellation")
        refine.click()

        let returnedToRefine = expectation(
            for: NSPredicate(format: "value == 'refine'"),
            evaluatedWith: refine)
        wait(for: [returnedToRefine], timeout: 5)
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
            play.waitForExistence(timeout: 10),
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
        play.click()  // smoke: play doesn't crash
        Thread.sleep(forTimeInterval: 0.5)
        attachScreenshot(of: app, named: "meeting-detail-waveform")
    }

    /// The export menu is the only path to subtitle files, so both the SRT
    /// and VTT items must exist for a seeded diarized meeting.
    @MainActor
    func testExportMenuOffersSubtitleFormats() {
        let app = launchOnSeededMeeting(staleDerived: true)
        defer { app.terminate() }

        XCTAssertTrue(
            app.control(withIdentifier: "detail-actions").waitForExistence(timeout: 10),
            "exports must remain inside the explicit meeting-actions boundary")
        let menu = app.control(withIdentifier: "detail-export-menu")
        XCTAssertTrue(
            menu.waitForExistence(timeout: 10),
            "the action row must offer the export menu")
        menu.click()
        XCTAssertTrue(
            app.menuItems["detail-export-srt"].waitForExistence(timeout: 5),
            "the diarized transcript must export as SRT")
        XCTAssertTrue(
            app.menuItems["detail-export-vtt"].waitForExistence(timeout: 5),
            "the diarized transcript must export as VTT")
        let provenance = app.menuItems["detail-export-correction-provenance-off"]
        XCTAssertTrue(
            provenance.waitForExistence(timeout: 5),
            "the export menu must disclose the opt-in correction provenance control")
        XCTAssertTrue(provenance.isEnabled)
        provenance.click()

        menu.click()
        let included = app.menuItems["detail-export-correction-provenance-on"]
        XCTAssertTrue(included.waitForExistence(timeout: 5))
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
        XCTAssertTrue(menu.waitForExistence(timeout: 10))
        menu.click()
        let recapItem = app.menuItems["detail-share-recap"]
        XCTAssertTrue(
            recapItem.waitForExistence(timeout: 5),
            "a summarized meeting must offer the recap")
        recapItem.click()

        XCTAssertTrue(
            app.control(withIdentifier: "recap-title").waitForExistence(timeout: 10),
            "the recap opens for review instead of sending anything")
        let editor = app.control(withIdentifier: "recap-body")
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
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
            menu.waitForExistence(timeout: 10),
            "a summarized meeting must offer the regenerate menu")
        XCTAssertTrue(app.prepareForInteraction())
        XCTAssertTrue(
            menu.waitForStableFrame(timeout: 5),
            "the localized regenerate menu must settle before opening")
        menu.click()
        let structure = app.menuItems["detail-structure-menu"]
        guard structure.waitForExistence(timeout: 5) else {
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
                app.menuItems["detail-structure-\(id)"].waitForExistence(timeout: 5),
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

        XCTAssertTrue(app.buttons["player-play-pause"].waitForExistence(timeout: 15))
        app.buttons["player-play-pause"].click()  // play → the playhead moves
        app.buttons["clip-mark-start"].click()
        Thread.sleep(forTimeInterval: 1.5)  // let the playhead advance
        app.buttons["clip-mark-end"].click()  // end after start → valid range

        XCTAssertTrue(
            app.buttons["clip-export"].waitForExistence(timeout: 5),
            "marking a valid in/out range must reveal the export button")
    }
}
