import XCTest

/// A library upgraded from 1.x: the one notice that dictation moved, and deleting what it kept.
final class LegacyDictationUITests: PortavozUITestCase {
    @MainActor
    func testAnUpgradedLibraryLearnsDictationMovedAndCanDeleteItsHistory() throws {
        let app = try XCUIApplication.portavoz()
        app.launchArguments += ["-seed-legacy-dictation", "-show-dictation-moved-notice"]
        app.launchPortavoz()
        defer { finishUITestApplication(app) }

        let title = app.staticTexts["dictation-moved-title"]
        XCTAssertTrue(title.waitForExistenceFast(timeout: 15))
        let delete = app.buttons["dictation-moved-delete"]
        XCTAssertTrue(delete.waitForExistenceFast(timeout: 5), "kept rows can be deleted from the notice")
        attachScreenshot(of: app, named: "pr-dictation-moved-notice")
        delete.click()
        let confirm = app.buttons["dictation-moved-delete-confirm"]
        XCTAssertTrue(confirm.waitForExistenceFast(timeout: 5))
        confirm.click()
        XCTAssertTrue(delete.waitForDisappearance(timeout: 5), "nothing is left to delete")
        app.buttons["dictation-moved-dismiss"].click()
        XCTAssertTrue(title.waitForDisappearance(timeout: 5))
    }

    @MainActor
    func testTheDataPaneDeletesLegacyDictationHistory() throws {
        let app = try XCUIApplication.portavoz(openSettings: true)
        app.launchArguments.append("-seed-legacy-dictation")
        app.launchPortavoz()
        defer { finishUITestApplication(app) }

        XCTAssertTrue(app.openSettingsCategory("settings-category-data", revealing: "settings-legacy-dictation-delete"))
        XCTAssertFalse(app.staticTexts["dictation-moved-title"].exists, "a disposable library is told only when forced")
        attachScreenshot(of: app, named: "pr-settings-legacy-dictation")
        app.buttons["settings-legacy-dictation-delete"].click()
        let confirm = app.buttons["settings-legacy-dictation-delete-confirm"]
        XCTAssertTrue(confirm.waitForExistenceFast(timeout: 5))
        confirm.click()
        XCTAssertTrue(app.buttons["settings-legacy-dictation-delete"].waitForDisappearance(timeout: 5))
    }
}
