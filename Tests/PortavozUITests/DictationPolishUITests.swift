import XCTest

/// Polish runs a deterministic fixture rewrite; no engine, model or network is involved.
final class DictationPolishUITests: PortavozUITestCase {
    @MainActor
    func testPolishIsOfferedAsTheDefaultTextMode() throws {
        let app = try XCUIApplication.portavoz(openSettings: true)
        app.launchEnvironment["PORTAVOZ_UI_TEST_DEFAULTS"] =
            #"{"globalDictationEnabled":true,"dictationTextMode":"literal","dictationApplicationTextProfiles":"[]"}"#
        app.launchPortavoz()
        defer { finishUITestApplication(app) }
        XCTAssertTrue(app.openSettingsCategory("settings-category-audio", revealing: "settings-dictation-text-mode"))
        let picker = app.control(withIdentifier: "settings-dictation-text-mode")
        let window = app.windows.containing(.any, identifier: "settings-search-field").firstMatch
        let form = window.scrollViews.element(boundBy: 1)
        XCTAssertTrue(picker.revealVertically(in: form, maxScrolls: 6, maximumStep: 240))
        XCTAssertTrue(picker.waitForHittable(timeout: 5))
        picker.click()
        let polish = app.menuItems["settings-dictation-text-mode-polish"]
        XCTAssertTrue(polish.waitForExistenceFast(timeout: 5))
        polish.click()
        XCTAssertTrue(waitForUITestCondition(timeout: 5) { renderedText(of: picker).contains("Polish") })
        XCTAssertTrue(app.staticTexts["settings-dictation-text-mode-help"].exists)
    }

    @MainActor
    func testAPolishedDictationCanStillBePastedWithoutPolish() throws {
        let app = try launchPolishing()
        defer { finishUITestApplication(app) }
        deliver(app)
        XCTAssertFalse(app.staticTexts["dictation-panel-polish-notice"].exists)
        XCTAssertTrue(app.buttons["menu-bar-paste-unpolished"].waitForExistenceFast(timeout: 5))
        XCTAssertTrue(app.buttons["menu-bar-paste-last"].exists)
    }

    @MainActor
    func testPolishingCanBeSkippedToPasteTheCleanText() throws {
        let app = try launchPolishing("-seed-dictation-polish-held")
        defer { finishUITestApplication(app) }
        XCTAssertTrue(app.prepareForInteraction())
        let dictate = app.buttons["menu-bar-dictate"]
        XCTAssertTrue(dictate.waitForStableFrame(timeout: 5))
        dictate.click()
        XCTAssertTrue(app.staticTexts["dictation-panel-transcript"].waitForExistenceFast(timeout: 5))
        dictate.click()
        let skip = app.buttons["dictation-panel-skip-polish"]
        XCTAssertTrue(skip.waitForHittable(timeout: 4))
        XCTAssertTrue(app.staticTexts["dictation-panel-polish-hint"].exists)
        XCTAssertTrue(renderedText(of: app.staticTexts["dictation-panel-state"]).contains("Polishing"))
        skip.click()
        XCTAssertTrue(app.staticTexts["dictation-panel-delivery-status"].waitForExistenceFast(timeout: 5))
        XCTAssertTrue(app.staticTexts["dictation-panel-polish-notice"].waitForExistenceFast(timeout: 5))
        XCTAssertFalse(app.buttons["menu-bar-paste-unpolished"].exists)
    }

    @MainActor
    func testARewriteThatChangesTheMeaningPastesCleanAndSaysWhy() throws {
        let app = try launchPolishing("-seed-dictation-polish-unfaithful")
        defer { finishUITestApplication(app) }
        deliver(app)
        XCTAssertTrue(app.staticTexts["dictation-panel-polish-notice"].waitForExistenceFast(timeout: 5))
        XCTAssertFalse(app.buttons["menu-bar-paste-unpolished"].exists)
    }

    @MainActor
    private func launchPolishing(_ arguments: String...) throws -> XCUIApplication {
        let app = try XCUIApplication.portavoz(showMenuBarContent: true)
        app.launchArguments += ["-seed-dictation", "-seed-dictation-delivery", "-seed-dictation-verified",
                                "-seed-dictation-english"] + arguments
        app.launchEnvironment["PORTAVOZ_UI_TEST_DEFAULTS"] =
            #"{"globalDictationEnabled":true,"dictationTextMode":"polish"}"#
        app.launchPortavoz()
        return app
    }

    @MainActor
    private func deliver(_ app: XCUIApplication) {
        XCTAssertTrue(app.prepareForInteraction())
        let dictate = app.buttons["menu-bar-dictate"]
        XCTAssertTrue(dictate.waitForStableFrame(timeout: 5))
        dictate.click()
        XCTAssertTrue(app.staticTexts["dictation-panel-transcript"].waitForExistenceFast(timeout: 5))
        dictate.click()
        XCTAssertTrue(app.staticTexts["dictation-panel-delivery-status"].waitForExistenceFast(timeout: 5))
    }
}
