import XCTest

/// The fixture receiver verifies every paste in memory, so the second dictation can correct the first.
final class DictationCorrectionUITests: PortavozUITestCase {
    @MainActor
    func testASpokenCorrectionChangesTheLastDictationInsteadOfPasting() throws {
        let app = try XCUIApplication.portavoz(showMenuBarContent: true)
        app.launchArguments += ["-seed-dictation", "-seed-dictation-english", "-seed-dictation-delivery",
                                "-seed-dictation-verified", "-seed-dictation-correction"]
        app.launchEnvironment["PORTAVOZ_UI_TEST_DEFAULTS"] =
            #"{"globalDictationEnabled":true,"dictationCorrectionCommands":true}"#
        app.launchPortavoz()
        defer { finishUITestApplication(app) }
        XCTAssertTrue(app.prepareForInteraction())
        let dictate = app.buttons["menu-bar-dictate"]
        let status = app.staticTexts["dictation-panel-delivery-status"]
        for _ in 0..<2 {
            XCTAssertTrue(dictate.waitForStableFrame(timeout: 5))
            dictate.click()
            XCTAssertTrue(app.staticTexts["dictation-panel-transcript"].waitForExistenceFast(timeout: 5))
            dictate.click()
            XCTAssertTrue(status.waitForExistenceFast(timeout: 5))
            if renderedText(of: status).contains("Changed") { break }
            XCTAssertTrue(status.waitForDisappearance(timeout: 5))
        }
        XCTAssertTrue(renderedText(of: status).contains("“notes” to “files”"))
        let learn = app.buttons["dictation-panel-learn-correction"]
        XCTAssertTrue(learn.waitForHittable(timeout: 4), "A new spelling is offered, never learned silently")
        XCTAssertTrue(renderedText(of: learn).contains("files"))
        learn.click()
        XCTAssertTrue(waitForUITestCondition(timeout: 5) {
            renderedText(of: status).contains("From now on, “notes” is written “files”.")
        })
        XCTAssertFalse(learn.exists)
    }

    @MainActor
    func testTheDictionaryGroupsEveryHeardFormUnderItsSpelling() throws {
        let app = try XCUIApplication.portavoz(openSettings: true)
        let rules = #"[{\"trigger\":\"porta voz\",\"replacement\":\"Portavoz\"},"#
            + #"{\"trigger\":\"portavós\",\"replacement\":\"Portavoz\"}]"#
        app.launchEnvironment["PORTAVOZ_UI_TEST_DEFAULTS"] =
            #"{"globalDictationEnabled":true,"dictationReplacements":""# + rules + #""}"#
        app.launchPortavoz()
        defer { finishUITestApplication(app) }
        XCTAssertTrue(app.openSettingsCategory("settings-category-audio", revealing: "settings-dictation-dict-add"))
        let window = app.windows.containing(.any, identifier: "settings-search-field").firstMatch
        let form = window.scrollViews.element(boundBy: 1)
        let addHeard = app.buttons.matching(identifier: "settings-dictation-dict-add-heard")
        XCTAssertTrue(addHeard.firstMatch.revealVertically(in: form, maxScrolls: 8, maximumStep: 240))
        XCTAssertEqual(addHeard.count, 1, "Two heard forms of one spelling are one term")
        XCTAssertEqual(app.buttons.matching(identifier: "settings-dictation-dict-remove").count, 2)
        addHeard.firstMatch.click()
        let replacement = app.textFields["settings-dictation-dict-replacement"]
        XCTAssertTrue(waitForUITestCondition(timeout: 5) { replacement.value as? String == "Portavoz" })
    }
}
