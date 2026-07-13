import XCTest

/// The redesigned Settings (design system 2a): a category sidebar with the
/// panes behind it. These verify the navigation works and that the
/// app-only language override updates SwiftUI text live.
final class SettingsUITests: XCTestCase {
    @MainActor
    func testCategoryNavigationRevealsEachPane() {
        let app = XCUIApplication.portavoz(openSettings: true)
        app.launchPortavoz()
        defer { app.terminate() }

        // The nav renders every category…
        let intelligence = app.control(withIdentifier: "settings-category-intelligence")
        XCTAssertTrue(
            intelligence.waitForExistence(timeout: 10),
            "the Settings category sidebar must render (2a)")
        XCTAssertTrue(app.control(withIdentifier: "settings-category-data").exists)

        // …and picking Intelligence reveals the summary-engine picker, which
        // now lives in that pane rather than one long scroll (M12).
        intelligence.click()
        XCTAssertTrue(
            app.control(withIdentifier: "settings-summary-engine-picker").waitForExistence(timeout: 5),
            "the Intelligence pane must show the summary-engine picker")

        // Your data shows the export action.
        app.control(withIdentifier: "settings-category-data").click()
        XCTAssertTrue(
            app.buttons["settings-export-all-button"].waitForExistence(timeout: 5),
            "the Your-data pane must show the export-all action")
    }

    @MainActor
    func testIntelligencePaneCreatesACustomStructure() {
        // The Intelligence pane lets you author your own summary structures;
        // "Add structure" opens the editor sheet with a name field.
        let app = XCUIApplication.portavoz(openSettings: true)
        app.launchPortavoz()
        defer { app.terminate() }

        let intelligence = app.control(withIdentifier: "settings-category-intelligence")
        XCTAssertTrue(intelligence.waitForExistence(timeout: 10))
        intelligence.click()

        let add = app.buttons["settings-add-structure"]
        XCTAssertTrue(
            add.waitForExistence(timeout: 5),
            "the Intelligence pane must offer the custom-structure creator")
        add.click()

        XCTAssertTrue(
            app.textFields["structure-name"].waitForExistence(timeout: 5),
            "Add structure must open the editor sheet with a name field")
    }

    @MainActor
    func testVoicePaneOffersTheMirrorOptIn() {
        // The post-meeting mirror (6a-2) is opt-in and off by default; its
        // switch lives in the "My voice & Companion" pane.
        let app = XCUIApplication.portavoz(openSettings: true)
        app.launchPortavoz()
        defer { app.terminate() }

        let voice = app.control(withIdentifier: "settings-category-voice")
        XCTAssertTrue(voice.waitForExistence(timeout: 10))
        voice.click()

        let mirror = app.control(withIdentifier: "settings-mirror-after-meeting")
        XCTAssertTrue(
            mirror.waitForExistence(timeout: 5),
            "the voice pane must offer the post-meeting mirror opt-in")
    }

    @MainActor
    func testLanguageToggleSwitchesVisibleTextWithoutRelaunch() {
        // The standalone Settings window (⌘,), not the test sheet: the sheet
        // clips the trailing-edge toggle, the real window lays it out fully.
        let app = XCUIApplication.portavoz(launchLocale: "en")
        app.launchPortavoz()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["library-new-recording-button"].waitForExistence(timeout: 15))
        app.typeKey(",", modifierFlags: .command)  // open Settings

        let systemToggle = app.control(withIdentifier: "settings-language-system-toggle")
        XCTAssertTrue(systemToggle.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Use system language"].exists)

        systemToggle.click()  // manual English by default
        let languagePicker = app.control(withIdentifier: "settings-language-picker")
        XCTAssertTrue(languagePicker.waitForExistence(timeout: 5))
        languagePicker.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.5)).click()
        // The whole UI re-localizes live: the pane label AND a nav category.
        XCTAssertTrue(app.staticTexts["Usar idioma del sistema"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["General e idioma"].exists)

        systemToggle.click()  // back to launch/system English
        XCTAssertTrue(app.staticTexts["Use system language"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["General & language"].exists)
    }
}
