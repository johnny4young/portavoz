import XCTest

/// The Insights dashboard (design system 3a): navigating to it from the
/// library renders the redesigned view — the stat tiles and the rhythm
/// heatmap, computed locally from the seeded library.
final class InsightsUITests: PortavozUITestCase {
    @MainActor
    func testInsightsShowsCompleteLocalDashboard() {
        let app = XCUIApplication.portavoz(seedDemo: true)
        // Keep the retained evidence independent of the user's persisted picker choice.
        app.launchArguments += ["-insightsScope", "week"]
        app.launchPortavoz()
        defer { app.terminate() }

        XCTAssertTrue(
            app.waitForSeededLibraryToSettle(),
            "the seeded library must settle before navigating away")
        let insights = app.buttons["library-insights-button"]
        XCTAssertTrue(insights.waitForExistenceFast(timeout: 15), "the library must offer Insights")
        insights.click()

        XCTAssertTrue(
            app.control(withIdentifier: "insights-title").waitForExistenceFast(timeout: 10),
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
        XCTAssertTrue(
            app.control(withIdentifier: "insights-participants").exists,
            "Insights must show the 'who you talk with' panel (3a)")
        XCTAssertTrue(
            app.control(withIdentifier: "insights-participant-Ana").exists,
            "each named participant must get an amber/violet participation bar")
        attachScreenshot(of: app, named: "band-2p-insights")
    }
}
