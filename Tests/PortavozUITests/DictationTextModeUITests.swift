import AppKit
import XCTest

final class DictationTextModeUITests: PortavozUITestCase {
    @MainActor
    func testApplicationProfileUsesNativePickerAndKeepsTheOriginal() throws {
        let app = try XCUIApplication.portavoz(openSettings: true)
        app.launchArguments.append("-seed-dictation-profile-picker")
        app.launchEnvironment["PORTAVOZ_UI_TEST_DEFAULTS"] =
            #"{"globalDictationEnabled":true,"dictationTextMode":"literal","dictationApplicationTextProfiles":"[]"}"#
        let original = try makeApplication(in: app)
        let originalBytes = try Data(contentsOf: original)
        app.launchPortavoz()
        defer { app.terminate() }
        XCTAssertTrue(app.openSettingsCategory("settings-category-audio", revealing: "settings-dictation-text-mode"))
        let global = app.control(withIdentifier: "settings-dictation-text-mode")
        try select(.clean, prefix: "settings-dictation-text-mode", in: app)
        XCTAssertTrue(waitForUITestCondition(timeout: 5) { renderedText(of: global).contains(cleanTitle) })
        try openProfiles(in: app)
        XCTAssertTrue(app.staticTexts["settings-dictation-profile-privacy"].exists)
        let add = app.buttons["settings-dictation-profile-add"]
        try revealSettings(add, in: app)
        add.click()
        let picker = app.sheets["open-panel"]
        guard picker.waitForExistenceFast(timeout: 5) else {
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "dictation-profile-picker-hierarchy"
            hierarchy.lifetime = .keepAlways
            self.add(hierarchy)
            XCTFail("The real application chooser must appear")
            return
        }
        typeKey("2", modifierFlags: .command, in: app, modalAnchor: "open-panel")
        typeKey("a", modifierFlags: .command, in: app, modalAnchor: "open-panel")
        XCTAssertTrue(picker.buttons["OKButton"].waitForEnabled(timeout: 5))
        typeKey(.return, modifierFlags: [], in: app, modalAnchor: "open-panel")
        XCTAssertTrue(picker.waitForDisappearance(timeout: 5))
        let prefix = "settings-dictation-profile-mode-app.portavoz.profile.fixture"
        let profile = app.control(withIdentifier: prefix)
        XCTAssertTrue(profile.waitForExistenceFast(timeout: 5))
        XCTAssertTrue(renderedText(of: profile).contains(cleanTitle), "A new profile starts with the chosen global mode")
        try select(.literal, prefix: prefix, in: app)
        XCTAssertTrue(waitForUITestCondition(timeout: 5) { renderedText(of: profile).contains("Literal") })
        XCTAssertTrue(renderedText(of: global).contains(cleanTitle), "An application override must not rewrite the default")
        let remove = app.buttons["settings-dictation-profile-remove-app.portavoz.profile.fixture"]
        try revealSettings(remove, in: app)
        remove.click()
        XCTAssertTrue(profile.waitForDisappearance(timeout: 5))
        XCTAssertEqual(try Data(contentsOf: original), originalBytes)
    }

    @MainActor
    func testCorruptProfilesShowAnExplicitResetWithoutChangingTheDefault() throws {
        let app = try XCUIApplication.portavoz(openSettings: true)
        app.launchEnvironment["PORTAVOZ_UI_TEST_DEFAULTS"] =
            #"{"globalDictationEnabled":true,"dictationTextMode":"literal","dictationApplicationTextProfiles":"not json"}"#
        app.launchPortavoz()
        defer { app.terminate() }
        XCTAssertTrue(app.openSettingsCategory("settings-category-audio", revealing: "settings-dictation-text-mode"))
        try openProfiles(in: app)
        let warning = app.staticTexts["settings-dictation-profiles-invalid"]
        XCTAssertTrue(warning.waitForExistenceFast(timeout: 5))
        XCTAssertFalse(app.buttons["settings-dictation-profile-add"].exists)
        let reset = app.buttons["settings-dictation-profile-reset"]
        try revealSettings(reset, in: app)
        reset.click()
        XCTAssertTrue(warning.waitForDisappearance(timeout: 5))
        XCTAssertTrue(app.buttons["settings-dictation-profile-add"].waitForEnabled(timeout: 5))
        XCTAssertTrue(renderedText(of: app.control(withIdentifier: "settings-dictation-text-mode")).contains("Literal"))
        let disclosure = app.buttons["settings-dictation-profiles"]
        try revealSettings(disclosure, in: app)
        disclosure.click()
        XCTAssertTrue(app.buttons["settings-dictation-profile-add"].waitForDisappearance(timeout: 5))
        XCTAssertTrue(renderedText(of: disclosure).contains(
            UITestLocale.environmentLocale == "es" ? "Contraído" : "Collapsed"))
    }

    @MainActor
    func testSessionModeOverrideCancelsAndRestartsWithoutChangingDefaults() throws {
        let app = try XCUIApplication.portavoz(showMenuBarContent: true)
        app.launchArguments.append("-seed-dictation")
        app.launchEnvironment["PORTAVOZ_UI_TEST_DEFAULTS"] =
            #"{"globalDictationEnabled":true,"dictationTextMode":"literal"}"#
        app.launchPortavoz()
        defer { app.terminate() }
        let dictate = app.buttons["menu-bar-dictate"]
        XCTAssertTrue(dictate.waitForHittable(timeout: 5))
        dictate.click()
        let mode = app.control(withIdentifier: "dictation-panel-text-mode")
        XCTAssertTrue(mode.waitForExistenceFast(timeout: 5))
        XCTAssertTrue(renderedText(of: mode).contains("Literal"))
        try select(.clean, prefix: "dictation-panel-text-mode", in: app)
        XCTAssertTrue(waitForUITestCondition(timeout: 5) { renderedText(of: mode).contains(cleanTitle) })
        app.buttons["dictation-panel-cancel"].click()
        XCTAssertTrue(mode.waitForDisappearance(timeout: 5))
        XCTAssertTrue(app.prepareForInteraction())
        dictate.click()
        XCTAssertTrue(mode.waitForExistenceFast(timeout: 5))
        XCTAssertTrue(renderedText(of: mode).contains("Literal"), "A cancelled session must not retain its override")
        app.buttons["dictation-panel-cancel"].click()
        XCTAssertTrue(mode.waitForDisappearance(timeout: 5))
    }

    @MainActor
    private func openProfiles(in app: XCUIApplication) throws {
        let disclosure = app.control(withIdentifier: "settings-dictation-profiles")
        try revealSettings(disclosure, in: app)
        disclosure.click()
        XCTAssertTrue(app.staticTexts["settings-dictation-profile-privacy"].waitForExistenceFast(timeout: 5))
        XCTAssertTrue(renderedText(of: disclosure).contains(
            UITestLocale.environmentLocale == "es" ? "Expandido" : "Expanded"))
    }

    @MainActor
    private func revealSettings(_ control: XCUIElement, in app: XCUIApplication) throws {
        let window = app.windows.containing(.any, identifier: "settings-search-field").firstMatch
        let form = window.scrollViews.element(boundBy: 1)
        _ = try XCTUnwrap(control.revealVertically(in: form, maxScrolls: 3, maximumStep: 240) ? control : nil,
                          "The settings control must be fully visible before interaction")
    }

    private enum Mode: String { case literal, clean }

    @MainActor
    private func select(_ mode: Mode, prefix: String, in app: XCUIApplication) throws {
        let picker = app.control(withIdentifier: prefix)
        if prefix.hasPrefix("settings-") { try revealSettings(picker, in: app) }
        XCTAssertTrue(picker.waitForHittable(timeout: 5))
        picker.click()
        let option = app.menuItems[prefix + "-" + mode.rawValue]
        XCTAssertTrue(option.waitForExistenceFast(timeout: 5))
        option.click()
    }

    private var cleanTitle: String { UITestLocale.environmentLocale == "es" ? "Limpio" : "Clean" }

    @MainActor
    private func makeApplication(in app: XCUIApplication) throws -> URL {
        let root = URL(fileURLWithPath: try XCTUnwrap(app.launchEnvironment["TMPDIR"]), isDirectory: true)
        let directory = root.appendingPathComponent("dictation-profile-applications/Fixture.app/Contents")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let plist = directory.appendingPathComponent("Info.plist")
        let values = ["CFBundleIdentifier": "app.portavoz.profile.fixture", "CFBundlePackageType": "APPL",
                      "CFBundleName": "Fixture", "CFBundleVersion": "1"]
        try PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0).write(to: plist)
        return plist
    }
}
