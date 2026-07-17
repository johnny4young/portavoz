import XCTest

/// UI smoke tests (M11 tooling). These launch the real app under XCUITest so
/// we verify the UI renders without driving the screen by hand. Run with
/// `make test-ui`. The app honors `-use-temp-store` so a test run never
/// touches the real library.
final class LibraryUITests: XCTestCase {
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
    }
}
