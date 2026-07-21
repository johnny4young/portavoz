import XCTest

/// UI smoke tests (M11 tooling). These launch the real app under XCUITest so
/// we verify the UI renders without driving the screen by hand. Run with
/// `make test-ui`. The app honors `-use-temp-store` so a test run never
/// touches the real library.
final class LibraryUITests: XCTestCase {
    @MainActor
    func testUpcomingMeetingBriefShowsRelatedEvidenceAndOpenCommitment() {
        let app = XCUIApplication.portavoz(seedDemo: true, seedBrief: true)
        app.launchPortavoz()
        defer { app.terminate() }

        XCTAssertTrue(app.waitForSeededLibraryToSettle())
        let upcoming = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'library-upcoming-'"))
            .firstMatch
        XCTAssertTrue(upcoming.waitForExistence(timeout: 10))
        upcoming.click()

        XCTAssertTrue(app.control(withIdentifier: "brief-title").waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Presupuesto rollout"].exists)
        let related = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'brief-related-'"))
            .firstMatch
        XCTAssertTrue(
            related.waitForExistence(timeout: 10),
            "the brief must surface the related seeded meeting")
        XCTAssertTrue(app.staticTexts["Test meeting"].exists)
        let commitment = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'brief-open-'"))
            .firstMatch
        XCTAssertTrue(commitment.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Prepare the rollout"].exists)
        XCTAssertTrue(app.buttons["brief-record-button"].exists)
        attachScreenshot(of: app, named: "meeting-preparation-brief")
    }

    @MainActor
    func testLibraryRendersRecordButtonAndActionChips() {
        let app = XCUIApplication.portavoz()
        app.launchPortavoz()
        defer { app.terminate() }

        let record = app.buttons["library-new-recording-button"]
        XCTAssertTrue(
            record.waitForExistence(timeout: 15),
            "the library window must render its primary action on launch")

        if let locale = UITestLocale.environmentLocale {
            XCTAssertEqual(record.label, locale == "es" ? "Nueva grabación" : "New recording")
        }

        // The design-system action chips replace the old full-width buttons.
        XCTAssertTrue(app.buttons["library-import-audio-button"].exists)
        XCTAssertTrue(app.buttons["library-ask-button"].exists)
        XCTAssertTrue(app.buttons["library-insights-button"].exists)
    }

    @MainActor
    func testRecordingStartFailureOffersTypedRecovery() {
        let app = XCUIApplication.portavoz(simulateRecordingStartFailure: true)
        app.launchPortavoz()
        defer { app.terminate() }

        let record = app.buttons["library-new-recording-button"]
        XCTAssertTrue(record.waitForExistence(timeout: 15))
        let isSpanish = record.label == "Nueva grabación"
        record.click()

        XCTAssertTrue(
            app.control(withIdentifier: "recording-failure").waitForExistence(timeout: 10),
            "a deterministic start failure must become an actionable error state")
        let expected = isSpanish
            ? "Portavoz no pudo preparar los dispositivos de grabación. Revisa los permisos y vuelve a intentarlo."
            : "Portavoz could not prepare the recording devices. Check permissions and try again."
        XCTAssertTrue(app.staticTexts[expected].exists)
        XCTAssertTrue(app.control(withIdentifier: "recording-retry").exists)
        XCTAssertTrue(app.control(withIdentifier: "recording-back").exists)

        // ContentUnavailableView can expose SwiftUI children as `.other` even
        // when the underlying controls retain their stable identifiers.
        let reference = app.control(withIdentifier: "recording-failure-reference")
        XCTAssertTrue(reference.exists)
        let expectedReference = isSpanish
            ? "Referencia del error: recording.start.preparation.unavailable"
            : "Error reference: recording.start.preparation.unavailable"
        XCTAssertTrue(app.staticTexts[expectedReference].exists)
        attachScreenshot(of: app, named: "band-3j-typed-recording-failure")
    }

    @MainActor
    func testRecordingWarnsWhenRemoteAudioCallbacksStop() {
        let app = XCUIApplication.portavoz(simulateSystemCaptureStall: true)
        app.launchPortavoz()
        defer { app.terminate() }

        let record = app.buttons["library-new-recording-button"]
        XCTAssertTrue(record.waitForExistence(timeout: 15))
        record.click()

        let warning = app.control(withIdentifier: "recording-system-capture-health")
        XCTAssertTrue(
            warning.waitForExistence(timeout: 10),
            "callback death must become visible while microphone capture continues")
        attachScreenshot(of: app, named: "recording-remote-audio-recovery")
    }

    @MainActor
    func testSeededMeetingsGroupByRecency() {
        let app = XCUIApplication.portavoz(seedDemo: true)
        app.launchPortavoz()
        defer { app.terminate() }

        // The seeded meeting appears under a time-bucket section header, not
        // one flat "Meetings" list (design system timeline).
        XCTAssertTrue(
            app.staticTexts["Test meeting"].firstMatch.waitForExistence(timeout: 15),
            "the seeded meeting must appear in the grouped library")
        // Its timestamp (Nov 2023) is old, so it lands under "Earlier".
        XCTAssertTrue(
            app.staticTexts["Earlier"].exists || app.staticTexts["Antes"].exists,
            "an old meeting must sit under the Earlier bucket")

        attachScreenshot(of: app, named: "band-2o-library-voice-mix")

        // Search crosses the SwiftUI binding, feature-model debounce, and
        // real FTS projection before publishing a new Library snapshot.
        let search = app.textFields["library-search-field"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.click()
        search.typeText("presupuesto")
        XCTAssertTrue(
            app.staticTexts["Test meeting · 00:00"].waitForExistence(timeout: 10),
            "the feature model must publish the seeded transcript search hit")
        attachScreenshot(of: app, named: "band-4c-fast-local-search")
    }

    @MainActor
    func testAskConversationAnswersAndSeeksToExactCitation() {
        let app = XCUIApplication.portavoz(seedDemo: true)
        app.launchPortavoz()
        defer { app.terminate() }

        XCTAssertTrue(app.waitForSeededLibraryToSettle())
        app.buttons["library-ask-button"].click()
        let field = app.textFields["ask-question-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.click()
        field.typeText("viernes")
        app.buttons["ask-submit"].click()

        XCTAssertTrue(
            app.staticTexts["El presupuesto se revisó y el rollout quedó para el viernes."]
                .waitForExistence(timeout: 10),
            "the full Ask model must publish the seeded local answer")
        let citation = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'ask-citation-'"))
            .firstMatch
        XCTAssertTrue(citation.waitForExistence(timeout: 5))
        XCTAssertTrue(citation.label.contains("Test meeting · 00:03"))
        attachScreenshot(of: app, named: "band-6c5-full-ask-answer")

        citation.click()
        let currentTime = app.staticTexts["player-current-time"]
        XCTAssertTrue(currentTime.waitForExistence(timeout: 10))
        let seeked = expectation(
            for: NSPredicate(format: "value == '0:03'"),
            evaluatedWith: currentTime)
        wait(for: [seeked], timeout: 10)
    }

    @MainActor
    func testCommandPaletteSearchAnswerAndCitationSurviveNoStaleState() {
        let app = XCUIApplication.portavoz(seedDemo: true)
        app.launchPortavoz()
        defer { app.terminate() }

        XCTAssertTrue(app.waitForSeededLibraryToSettle())
        // Keep the citation destination open before invoking the resident
        // palette. Reassigning the same route does not reconstruct SwiftUI,
        // so this proves the navigation request reaches a mounted detail.
        let meeting = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'library-meeting-'"))
            .firstMatch
        meeting.click()
        XCTAssertTrue(
            app.control(withIdentifier: "player-current-time").waitForExistence(timeout: 10))
        app.typeKey("k", modifierFlags: .command)
        let field = app.textFields["palette-query-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.click()
        field.typeText("viernes")
        XCTAssertTrue(
            app.buttons["palette-hit-0"].waitForExistence(timeout: 10),
            "the palette must publish instant local FTS results")
        field.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(
            app.staticTexts["El presupuesto se revisó y el rollout quedó para el viernes."]
                .waitForExistence(timeout: 10),
            "Enter must use the same full Ask workflow")
        XCTAssertTrue(app.buttons["palette-copy-answer"].exists)
        let citation = app.buttons["palette-citation-0"]
        XCTAssertTrue(citation.exists)
        XCTAssertTrue(citation.label.contains("Test meeting · 00:03"))
        let paletteWindow = app.windows["command-palette-window"]
        XCTAssertTrue(
            paletteWindow.waitForExistence(timeout: 5),
            "the palette window must remain visible while showing its answer")
        attachElementScreenshot(of: paletteWindow, named: "band-6c5-command-palette-answer")

        citation.click()
        let currentTime = app.staticTexts["player-current-time"]
        XCTAssertTrue(currentTime.waitForExistence(timeout: 10))
        let seeked = expectation(
            for: NSPredicate(format: "value == '0:03'"),
            evaluatedWith: currentTime)
        wait(for: [seeked], timeout: 10)
    }

    @MainActor
    func testLaunchRecoversInterruptedStagingAudio() {
        let app = XCUIApplication.portavoz(seedRecovery: true)
        app.launchPortavoz()
        defer { app.terminate() }

        XCTAssertTrue(
            app.staticTexts["Recovered recording"].firstMatch.waitForExistence(timeout: 15),
            "launch recovery must return interrupted audio to the library")
        let meeting = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'library-meeting-'"))
            .firstMatch
        XCTAssertTrue(meeting.waitForExistence(timeout: 5))
        meeting.click()
        XCTAssertTrue(
            app.control(withIdentifier: "player-play-pause").waitForExistence(timeout: 10),
            "the recovered CAF must be playable without loading an ML model")
        XCTAssertTrue(
            app.control(withIdentifier: "detail-refine").exists,
            "the recovered meeting must retain its explicit transcript recovery action")
    }

    @MainActor
    func testLaunchResumesDurablePostCaptureProcessing() {
        let app = XCUIApplication.portavoz(seedProcessing: true)
        app.launchPortavoz()
        defer { app.terminate() }

        XCTAssertTrue(
            app.staticTexts["Durable processing recovery"]
                .firstMatch.waitForExistence(timeout: 15),
            "the durable processing fixture must remain discoverable while work resumes")
        let meeting = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'library-meeting-'"))
            .firstMatch
        XCTAssertTrue(meeting.waitForExistence(timeout: 5))
        let settled = expectation(
            for: NSPredicate(format: "isHittable == true"), evaluatedWith: meeting)
        wait(for: [settled], timeout: 10)
        meeting.click()

        XCTAssertTrue(
            app.staticTexts["El procesamiento durable conserva este texto."]
                .waitForExistence(timeout: 10),
            "diarization completion must atomically preserve the original transcript")
        XCTAssertTrue(
            app.staticTexts["Durable processing finished."]
                .waitForExistence(timeout: 15),
            "the resumed worker must publish its dependent summary and refresh the detail")
        attachScreenshot(of: app, named: "durable-post-capture-recovery")
    }
}
