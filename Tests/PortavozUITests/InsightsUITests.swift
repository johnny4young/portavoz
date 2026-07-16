import XCTest

/// The Insights dashboard (design system 3a): navigating to it from the
/// library renders the redesigned view — the stat tiles and the rhythm
/// heatmap, computed locally from the seeded library.
final class InsightsUITests: XCTestCase {
    @MainActor
    func testInsightsRendersHeatmap() {
        let app = XCUIApplication.portavoz(seedDemo: true)
        // Keep the retained evidence independent of the user's persisted picker choice.
        app.launchArguments += ["-insightsScope", "week"]
        app.launchPortavoz()
        defer { app.terminate() }

        let insights = app.buttons["library-insights-button"]
        XCTAssertTrue(insights.waitForExistence(timeout: 15), "the library must offer Insights")
        insights.click()

        XCTAssertTrue(
            app.control(withIdentifier: "insights-title").waitForExistence(timeout: 10),
            "Insights must render its title")
        XCTAssertTrue(
            app.control(withIdentifier: "insights-heatmap").exists,
            "Insights must render the rhythm heatmap (3a), not the old bar chart")
        // The week/month/year scope control (3a).
        XCTAssertTrue(
            app.control(withIdentifier: "insights-scope").exists,
            "Insights must offer the week/month/year scope")
        // The talk-balance tile, computed from the seeded voice mix.
        XCTAssertTrue(
            app.control(withIdentifier: "insights-balance").exists,
            "Insights must show the talk-balance tile")
        attachScreenshot(of: app, named: "band-2p-insights")
    }

    @MainActor
    func testInsightsShowsWhoYouTalkWith() {
        let app = XCUIApplication.portavoz(seedDemo: true)
        app.launchPortavoz()
        defer { app.terminate() }

        app.buttons["library-insights-button"].click()
        XCTAssertTrue(
            app.control(withIdentifier: "insights-participants").waitForExistence(timeout: 10),
            "Insights must show the 'who you talk with' panel (3a)")
        // The seeded named participant (Ana) gets a participation bar.
        XCTAssertTrue(
            app.control(withIdentifier: "insights-participant-Ana").exists,
            "each named participant must get an amber/violet participation bar")
    }
}
