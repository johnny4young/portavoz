import XCTest

/// Generates the fictional, disposable app-window evidence published in the
/// README and on portavoz.app. It never reads the user's library or captures
/// the desktop outside the Portavoz window.
final class PublicShowcaseUITests: PortavozUITestCase {
    @MainActor
    func testMeetingDetailShowcase() {
        let app = XCUIApplication.portavoz(seedShowcase: true)
        app.launchArguments += ["-seed-ai-suggestions"]
        app.launchPortavoz()
        defer { app.terminate() }

        XCTAssertTrue(app.waitForSeededLibraryToSettle())
        let meeting = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'library-meeting-'"))
            .firstMatch
        XCTAssertTrue(meeting.waitForStableFrame(timeout: 10))
        meeting.click()

        XCTAssertTrue(
            app.staticTexts["2026-07-10 Sprint Demo · Zephyr"]
                .waitForExistence(timeout: 10))
        XCTAssertTrue(
            app.buttons["detail-title-suggestion-dismiss"]
                .waitForExistence(timeout: 10))
        XCTAssertTrue(
            app.buttons["detail-recipe-suggestion-dismiss"]
                .waitForExistence(timeout: 10))
        let suggestNames = app.control(withIdentifier: "detail-suggest-names")
        XCTAssertTrue(suggestNames.waitForExistence(timeout: 5))
        suggestNames.click()
        XCTAssertTrue(
            app.buttons["detail-name-suggestion-dismiss-S3"]
                .waitForExistence(timeout: 10))
        XCTAssertTrue(
            app.control(withIdentifier: "player-clear-playback")
                .waitForExistence(timeout: 10))
        attachScreenshot(of: app, named: "public-meeting-detail")
    }

    @MainActor
    func testLiveTranslationShowcase() {
        let app = XCUIApplication.portavoz(
            seedShowcase: true,
            simulateLiveTranscriptBrowsing: true)
        app.launchArguments.append("-seed-live-translation-ui")
        app.launchPortavoz()
        defer { app.terminate() }

        XCTAssertTrue(app.waitForSeededLibraryToSettle())
        let record = app.buttons["library-new-recording-button"]
        XCTAssertTrue(record.waitForExistence(timeout: 10))
        record.click()

        XCTAssertTrue(
            app.staticTexts["Perfecto, cerramos con responsables y fechas claras."]
                .waitForExistence(timeout: 12),
            "the final fictional caption must establish the screenshot frontier")
        let translation = app.descendants(matching: .any)
            .matching(NSPredicate(
                format: "identifier BEGINSWITH 'recording-live-translation-'"))
            .firstMatch
        XCTAssertTrue(
            translation.waitForExistence(timeout: 10),
            "the translated rail must remain visible at the final caption")
        attachScreenshot(of: app, named: "public-live-translation")
    }

    @MainActor
    func testInsightsShowcase() {
        let app = XCUIApplication.portavoz(seedShowcase: true)
        app.launchArguments += ["-insightsScope", "month"]
        app.launchPortavoz()
        defer { app.terminate() }

        XCTAssertTrue(app.waitForSeededLibraryToSettle())
        let insights = app.buttons["library-insights-button"]
        XCTAssertTrue(insights.waitForExistence(timeout: 10))
        insights.click()

        XCTAssertTrue(
            app.control(withIdentifier: "insights-title")
                .waitForExistence(timeout: 10))
        XCTAssertTrue(
            app.control(withIdentifier: "insights-participant-Marta")
                .waitForExistence(timeout: 10))
        let meetingCount = app.buttons["library-new-recording-button"].label == "Nueva grabación"
            ? "1 reunión · 1 min"
            : "1 meeting · 1 min"
        XCTAssertTrue(
            app.staticTexts[meetingCount]
                .waitForExistence(timeout: 10))
        XCTAssertTrue(
            app.control(withIdentifier: "insights-heatmap")
                .waitForExistence(timeout: 10))
        attachScreenshot(of: app, named: "public-insights")
    }
}
