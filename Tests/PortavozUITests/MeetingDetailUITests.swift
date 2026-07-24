import XCTest

/// Drives a seeded meeting to verify the redesigned detail view renders —
/// the automated stand-in for eyeballing it. Launches with `-seed-demo`
/// so the library has one deterministic meeting with a transcript, a
/// tabbed summary (with a coauthoring ▸ bullet under Decisiones), meeting
/// health, chapters, a content-free privacy receipt in the right rail, and a
/// player.
final class MeetingDetailUITests: XCTestCase {
    @MainActor
    func testFiveThousandSegmentDetailRendersFromDisposableScaleFixture() {
        let app = XCUIApplication.portavoz(
            seedScale: true,
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
        attachScreenshot(of: app, named: "band-4a-scale-detail-5000-segments")
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
        simulateSequoiaCapabilities: Bool = false,
        unnamedSpeaker: Bool = false,
        summaryEngine: String? = nil
    ) -> XCUIApplication {
        let app = XCUIApplication.portavoz(
            seedDemo: true,
            seedLatestRecipe: latestRecipe,
            seedRefineRunning: refineRunning,
            seedJustRecorded: justRecorded,
            seedProcessingFailure: processingFailure,
            seedWithoutSummary: withoutSummary,
            simulateSequoiaCapabilities: simulateSequoiaCapabilities)
        if justRecorded {
            app.launchArguments += ["-mirrorAfterMeeting", "true"]
        }
        if unnamedSpeaker {
            app.launchArguments.append("-seed-unnamed-speaker")
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
        let settled = expectation(
            for: NSPredicate(format: "isHittable == true"), evaluatedWith: meeting)
        wait(for: [settled], timeout: 10)
        meeting.click()
        return app
    }

    @MainActor
    func testUnnamedSpeakerOffersExplicitNameSuggestions() {
        let app = launchOnSeededMeeting(unnamedSpeaker: true)
        defer { app.terminate() }

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
    func testFailedDurableProcessingOffersOneRecoveryAction() {
        let app = launchOnSeededMeeting(processingFailure: true)
        defer { app.terminate() }

        XCTAssertTrue(
            app.control(withIdentifier: "detail-processing-status")
                .waitForExistence(timeout: 10),
            "a durable failure must be visible beside the meeting")
        let retry = app.buttons["detail-retry-processing"]
        XCTAssertTrue(
            retry.waitForExistence(timeout: 5),
            "a terminal durable failure must expose one explicit retry action")
        attachScreenshot(of: app, named: "band-3i-actionable-processing")
        retry.click()
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

        app.control(withIdentifier: "settings-category-voice").click()
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

        // The ▸ coauthoring marker lives under the Decisiones section, now
        // behind its own tab — switching to it reveals the bullet.
        app.control(withIdentifier: "summary-tab-1").click()
        XCTAssertTrue(
            app.staticTexts["▸"].waitForExistence(timeout: 5),
            "the Decisiones tab must reveal the ▸ coauthored bullet (D28)")

        // A real mutation crosses MeetingDetailModel's client and the scoped
        // summary observation returns the completed count to the same view.
        let todosTab = app.control(withIdentifier: "summary-tab-todos")
        todosTab.click()
        let actionItem = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'action-item-'"))
            .firstMatch
        XCTAssertTrue(
            actionItem.waitForExistence(timeout: 5),
            "the seeded action item must expose its stable control boundary")
        actionItem.click()
        let completed = expectation(
            for: NSPredicate(format: "label CONTAINS '1/1'"),
            evaluatedWith: todosTab)
        wait(for: [completed], timeout: 5)
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
        attachScreenshot(of: app, named: "band-5b-summary-evidence")
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
        attachScreenshot(of: app, named: "band-5d-decision-evidence")
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
        attachScreenshot(of: app, named: "band-5e-action-item-evidence")
    }

    @MainActor
    func testApuntadorAnswerSourceJumpsToItsTranscriptAndAudio() {
        let app = launchOnSeededMeeting()
        defer { app.terminate() }

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
        attachScreenshot(of: app, named: "band-5f-apuntador-evidence")
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
        let editor = sheet.descendants(matching: .any)
            .matching(identifier: "summary-feedback-correction-text")
            .firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.click()
        editor.typeText("El rollout queda para el lunes después de QA.")
        app.control(withIdentifier: "summary-feedback-save").click()

        XCTAssertTrue(
            app.staticTexts["El rollout queda para el lunes después de QA."]
                .waitForExistence(timeout: 5),
            "the saved correction must be visible without replacing the generated overview")
        XCTAssertTrue(
            app.staticTexts["El equipo revisó el presupuesto y fijó el rollout."].exists,
            "feedback must not mutate the immutable generated summary")
        attachScreenshot(of: app, named: "band-5c-local-summary-feedback")

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
        attachScreenshot(of: app, named: "band-5a-confirmed-person-memory")
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
            app.control(withIdentifier: "detail-chapters").exists,
            "the right rail must show the ✦ chapters (the seed has a second chapter)")
        // The second chapter is the 200 s turn — proving a real break was
        // found (the title itself truncates in the narrow rail).
        XCTAssertTrue(
            app.control(withIdentifier: "chapter-200").exists,
            "a chapter must mark the later turn the seed placed at 200 s")
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

        attachScreenshot(of: app, named: "band-3h-privacy-receipt")
    }

    @MainActor
    func testFreshQualifyingMeetingShowsThePostMeetingMirror() {
        let app = launchOnSeededMeeting(justRecorded: true)
        defer { app.terminate() }

        XCTAssertTrue(
            app.control(withIdentifier: "mirror-card").waitForExistence(timeout: 10),
            "an opted-in fresh qualifying meeting must show its factual mirror")
        attachScreenshot(of: app, named: "band-2q-post-meeting-mirror")
    }

    @MainActor
    func testRunningRefineCanBeCanceledWithoutChangingTheTranscript() {
        let app = launchOnSeededMeeting(refineRunning: true)
        defer { app.terminate() }

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
            app.control(withIdentifier: "player-only-my-voice").exists,
            "the player must offer the 'only my voice' filter")
        XCTAssertTrue(
            app.control(withIdentifier: "detail-compress-audio").exists,
            "raw seeded meeting audio must keep its compression action")
        play.click()  // smoke: play doesn't crash
        Thread.sleep(forTimeInterval: 0.5)
        attachScreenshot(of: app, named: "band-4f-vectorized-waveform")
    }

    /// The export menu is the only path to subtitle files, so both the SRT
    /// and VTT items must exist for a seeded diarized meeting.
    @MainActor
    func testExportMenuOffersSubtitleFormats() {
        let app = launchOnSeededMeeting()
        defer { app.terminate() }

        let menu = app.control(withIdentifier: "detail-export-menu")
        XCTAssertTrue(
            menu.waitForExistence(timeout: 10),
            "the action row must offer the export menu")
        menu.click()
        XCTAssertTrue(
            app.menuItems["detail-export-srt"].waitForExistence(timeout: 5),
            "the diarized transcript must export as SRT")
        XCTAssertTrue(
            app.menuItems["detail-export-vtt"].exists,
            "the diarized transcript must export as VTT")
        // Close the menu without exporting — the save panel is native UI.
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
