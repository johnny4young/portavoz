import AppKit
import XCTest

/// The practice field delivers a real dictation session into Portavoz itself,
/// so these journeys prove delivery without another app or the clipboard.
final class DictationPracticeUITests: PortavozUITestCase {
    @MainActor
    func testOnboardingDictationStepPracticesInItsOwnFieldWithoutTheClipboard() throws {
        let app = try practiceApp(showOnboarding: true, dictationEnabled: false)
        app.launchArguments.append("-simulate-onboarding-model-recovery")
        app.launchPortavoz()
        defer { finishUITestApplication(app) }

        XCTAssertTrue(app.control(withIdentifier: "onboarding-first-listen").waitForExistenceFast(timeout: 15))
        for _ in 0..<4 {
            app.control(withIdentifier: "onboarding-continue").click()
        }
        XCTAssertTrue(app.control(withIdentifier: "onboarding-dictation").waitForExistenceFast(timeout: 5))
        XCTAssertFalse(
            Self.isOn(app.control(withIdentifier: "onboarding-dictation-toggle")),
            "continuing past the step must not turn dictation on")
        XCTAssertFalse(app.control(withIdentifier: "onboarding-dictation-accessibility-status").exists)

        // The microphone stays off until the model is ready; a failed attempt can retry.
        XCTAssertFalse(app.control(withIdentifier: "onboarding-dictation-practice-start").exists)
        let prepare = app.buttons["onboarding-dictation-practice-prepare"]
        prepare.click()
        let expectedFailure = UITestLocale.environmentLocale == "es"
            ? "No se pudieron descargar los modelos. Comprueba la conexión e inténtalo de nuevo."
            : "Models could not be downloaded. Check your connection and try again."
        let status = app.control(withIdentifier: "onboarding-dictation-practice-model-status")
        XCTAssertTrue(waitForUITestCondition(timeout: 5) { renderedText(of: status) == expectedFailure })
        prepare.click()

        practice(in: app, prefix: "onboarding-dictation")
        attachScreenshot(of: app, named: "onboarding-dictation-practice")
        app.control(withIdentifier: "onboarding-continue").click()
        XCTAssertTrue(app.control(withIdentifier: "onboarding-voice-enroll").waitForExistenceFast(timeout: 5))
    }

    @MainActor
    func testOnboardingDictationStepOffersShortcutAndAccessibilityOnceTurnedOn() throws {
        let app = try practiceApp(showOnboarding: true, dictationEnabled: true)
        app.launchPortavoz()
        defer { finishUITestApplication(app) }

        XCTAssertTrue(app.control(withIdentifier: "onboarding-first-listen").waitForExistenceFast(timeout: 15))
        for _ in 0..<4 {
            app.control(withIdentifier: "onboarding-continue").click()
        }
        XCTAssertTrue(Self.isOn(app.control(withIdentifier: "onboarding-dictation-toggle")))
        XCTAssertTrue(app.control(withIdentifier: "settings-dictation-hotkey-recorder").exists)
        let status = app.control(withIdentifier: "onboarding-dictation-accessibility-status")
        XCTAssertTrue(status.waitForExistenceFast(timeout: 5))
        let expectedStatus = UITestLocale.environmentLocale == "es"
            ? "Permite que el dictado escriba en otras apps. Puedes probarlo aquí sin este permiso."
            : "Lets dictation type into other apps. You can try it here without it."
        XCTAssertEqual(renderedText(of: status), expectedStatus)
        // The disposable launch never shows the system prompt; Continue still works.
        app.buttons["onboarding-dictation-accessibility-allow"].click()
        XCTAssertEqual(renderedText(of: status), expectedStatus)
        attachScreenshot(of: app, named: "onboarding-dictation-enabled")
        app.control(withIdentifier: "onboarding-continue").click()
        XCTAssertTrue(app.control(withIdentifier: "onboarding-voice-enroll").waitForExistenceFast(timeout: 5))
    }

    @MainActor
    func testSettingsPracticeFieldReceivesDictationWithoutTheClipboard() throws {
        let app = try practiceApp(openSettings: true, dictationEnabled: true)
        app.launchPortavoz()
        defer { finishUITestApplication(app) }

        XCTAssertTrue(app.openSettingsCategory(
            "settings-category-audio", revealing: "settings-dictation-practice-start"))
        practice(in: app, prefix: "settings-dictation")
        attachScreenshot(of: app, named: "settings-dictation-practice")
    }

    @MainActor
    private func practiceApp(
        showOnboarding: Bool = false, openSettings: Bool = false, dictationEnabled: Bool
    ) throws -> XCUIApplication {
        let app = try XCUIApplication.portavoz(openSettings: openSettings, showOnboarding: showOnboarding)
        // The verified fixture's clock makes the session long enough to deliver at once.
        app.launchArguments += ["-seed-dictation", "-seed-dictation-delivery", "-seed-dictation-verified"]
        if UITestLocale.environmentLocale == "en" { app.launchArguments.append("-seed-dictation-english") }
        app.launchEnvironment["PORTAVOZ_UI_TEST_DEFAULTS"] = #"{"globalDictationEnabled":\#(dictationEnabled)}"#
        return app
    }

    @MainActor
    private func practice(in app: XCUIApplication, prefix: String) {
        let expected = UITestLocale.environmentLocale == "en" ? "Don't delete these notes." : "No borres estas notas."
        let start = app.buttons["\(prefix)-practice-start"]
        XCTAssertTrue(start.waitForStableFrame(timeout: 5))
        let clipboard = NSPasteboard.general.changeCount
        start.click()
        let transcript = app.staticTexts["dictation-panel-transcript"]
        XCTAssertTrue(waitForUITestCondition(timeout: 5) { renderedText(of: transcript).contains(expected) })
        start.click()

        let field = app.control(withIdentifier: "\(prefix)-practice-field")
        XCTAssertTrue(waitForUITestCondition(timeout: 5) { renderedText(of: field) == expected })
        XCTAssertEqual(NSPasteboard.general.changeCount, clipboard, "Practice never borrows the clipboard")
        // The verified notice closes itself; nothing else is clicked while it is up.
        XCTAssertTrue(app.dialogs["dictation-panel"].waitForDisappearance(timeout: 5))
        app.buttons["\(prefix)-practice-clear"].click()
        XCTAssertTrue(waitForUITestCondition(timeout: 5) { renderedText(of: field) != expected })
        XCTAssertFalse(app.buttons["\(prefix)-practice-clear"].exists)
    }

    /// A macOS switch reports its state as "1"/1 through Accessibility.
    @MainActor
    private static func isOn(_ toggle: XCUIElement) -> Bool {
        (toggle.value as? Int) == 1 || (toggle.value as? String) == "1"
    }
}
