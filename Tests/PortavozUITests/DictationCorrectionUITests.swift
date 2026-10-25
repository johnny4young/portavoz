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
    }
}
