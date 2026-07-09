import XCTest

/// Verifies the Settings window renders stable controls and the app-only
/// language override updates SwiftUI text without relaunching.
final class SettingsUITests: XCTestCase {
    @MainActor
    func testSettingsShowsSummaryEngineSectionByIdentifier() {
        let app = XCUIApplication.portavoz(openSettings: true)
        app.launchPortavoz()
        defer { app.terminate() }

        XCTAssertTrue(
            app.control(withIdentifier: "settings-summary-engine-picker").waitForExistence(timeout: 10),
            "Settings must render the summary-engine picker (M12)")
    }

    @MainActor
    func testLanguageToggleSwitchesVisibleTextWithoutRelaunch() {
        let app = XCUIApplication.portavoz(openSettings: true, launchLocale: "en")
        app.launchPortavoz()
        defer { app.terminate() }

        let systemToggle = app.control(withIdentifier: "settings-language-system-toggle")
        let languagePicker = app.control(withIdentifier: "settings-language-picker")
        XCTAssertTrue(systemToggle.waitForExistence(timeout: 10))
        XCTAssertTrue(languagePicker.exists)
        XCTAssertTrue(app.staticTexts["Use system language"].exists)

        systemToggle.click()  // manual English by default
        XCTAssertTrue(languagePicker.waitForExistence(timeout: 5))
        languagePicker.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.5)).click()
        XCTAssertTrue(app.staticTexts["Usar idioma del sistema"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Grabaciones"].exists)

        systemToggle.click()  // back to launch/system English
        XCTAssertTrue(app.staticTexts["Use system language"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Recordings"].exists)
    }
}
