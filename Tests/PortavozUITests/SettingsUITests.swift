import XCTest

/// Verifies the Settings window renders the summary-engine section (M12).
final class SettingsUITests: XCTestCase {
    @MainActor
    func testSettingsShowsSummaryEngineSection() {
        let app = XCUIApplication()
        app.launchArguments = ["-use-temp-store"]
        app.launch()
        defer { app.terminate() }

        app.typeKey(",", modifierFlags: .command)  // ⌘, opens Settings

        XCTAssertTrue(
            app.staticTexts["Generar resúmenes con"].waitForExistence(timeout: 10),
            "Settings must render the summary-engine picker (M12)")
    }
}
