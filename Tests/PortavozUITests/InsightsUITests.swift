import XCTest

/// The Insights dashboard (design system 3a): navigating to it from the
/// library renders the redesigned view — the stat tiles and the rhythm
/// heatmap, computed locally from the seeded library.
final class InsightsUITests: XCTestCase {
    @MainActor
    func testInsightsRendersHeatmap() {
        let app = XCUIApplication.portavoz(seedDemo: true)
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
    }
}
