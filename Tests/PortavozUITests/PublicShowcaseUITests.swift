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
        // The hero meeting is the newest row and carries a fixed identity, so
        // the screenshot journey never depends on which row happens to be first.
        let meeting = app.descendants(matching: .any)
            .matching(identifier: "library-meeting-5E0C0A5E-0000-4000-8000-000000000001")
            .firstMatch
        XCTAssertTrue(meeting.waitForStableFrame(timeout: 10))
        meeting.click()

        XCTAssertTrue(
            app.staticTexts["2026-07-10 Sprint Demo · Zephyr"]
                .waitForExistenceFast(timeout: 10))
        XCTAssertTrue(
            app.buttons["detail-title-suggestion-dismiss"]
                .waitForExistenceFast(timeout: 10))
        XCTAssertTrue(
            app.buttons["detail-recipe-suggestion-dismiss"]
                .waitForExistenceFast(timeout: 10))
        let suggestNames = app.control(withIdentifier: "detail-suggest-names")
        XCTAssertTrue(suggestNames.waitForExistenceFast(timeout: 5))
        suggestNames.click()
        XCTAssertTrue(
            app.buttons["detail-name-suggestion-dismiss-S3"]
                .waitForExistenceFast(timeout: 10))
        XCTAssertTrue(
            app.control(withIdentifier: "player-clear-playback")
                .waitForExistenceFast(timeout: 10))
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
        XCTAssertTrue(record.waitForExistenceFast(timeout: 10))
        record.click()

        XCTAssertTrue(
            app.waitForLiveTranscriptFrontier(),
            "the showcase fixture must publish its initial caption frontier")
        XCTAssertTrue(
            app.resumeLiveTranscriptFixture(),
            "the showcase fixture must resume its final captions")
        XCTAssertTrue(
            app.waitForLiveTranscriptFixtureToFinish(),
            "the showcase fixture must finish before screenshot evidence")
        let translation = app.descendants(matching: .any)
            .matching(NSPredicate(
                format: "identifier BEGINSWITH 'recording-live-translation-'"))
            .firstMatch
        XCTAssertTrue(
            translation.waitForExistenceFast(timeout: 10),
            "the translated rail must exist after the final caption")
        attachScreenshot(of: app, named: "public-live-translation")
    }

    @MainActor
    func testTodayShowcase() {
        let app = XCUIApplication.portavoz(seedShowcase: true)
        app.launchArguments.append("-seed-showcase-agenda")
        app.launchPortavoz()
        defer { app.terminate() }

        // Today renders in the detail pane, so this journey waits on its own
        // surface rather than on a sidebar row the agenda may push down.
        XCTAssertTrue(app.waitForSeedFixtureReady())
        XCTAssertTrue(app.prepareForInteraction())
        XCTAssertTrue(app.staticTexts["home-title"].waitForExistenceFast(timeout: 20))
        XCTAssertTrue(
            app.control(withIdentifier: "home-upcoming-showcase-sync-qvtl")
                .waitForExistenceFast(timeout: 10))
        XCTAssertTrue(app.staticTexts["Review the Aurora Suite English docs draft"].exists)
        XCTAssertTrue(
            app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier BEGINSWITH 'home-recent-'"))
                .firstMatch.waitForExistenceFast(timeout: 10))
        attachScreenshot(of: app, named: "public-today")
    }

    @MainActor
    func testInsightsShowcase() {
        let app = XCUIApplication.portavoz(seedShowcase: true)
        app.launchArguments += ["-insightsScope", "month"]
        app.launchPortavoz()
        defer { app.terminate() }

        XCTAssertTrue(app.waitForSeededLibraryToSettle())
        let insights = app.buttons["library-insights-button"]
        XCTAssertTrue(insights.waitForExistenceFast(timeout: 10))
        insights.click()

        XCTAssertTrue(
            app.control(withIdentifier: "insights-title")
                .waitForExistenceFast(timeout: 10))
        XCTAssertTrue(
            app.control(withIdentifier: "insights-participant-Marta")
                .waitForExistenceFast(timeout: 10))
        let meetingCount = app.buttons["library-new-recording-button"].label == "Nueva grabación"
            ? "1 reunión · 1 min"
            : "1 meeting · 1 min"
        XCTAssertTrue(
            app.staticTexts[meetingCount]
                .waitForExistenceFast(timeout: 10))
        XCTAssertTrue(
            app.control(withIdentifier: "insights-heatmap")
                .waitForExistenceFast(timeout: 10))
        attachScreenshot(of: app, named: "public-insights")
    }
}
