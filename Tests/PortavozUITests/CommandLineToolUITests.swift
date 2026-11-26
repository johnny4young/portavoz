import XCTest

/// The install link lives in a scratch directory for disposable launches, so
/// these journeys never touch the user's `~/.local/bin`.
final class CommandLineToolUITests: PortavozUITestCase {
    @MainActor
    func testIntegrationsInstallsAndRemovesTheCommandLineToolLink() throws {
        let app = try XCUIApplication.portavoz(openSettings: true)
        app.launchArguments += ["-seed-command-line-tool"]
        app.launchPortavoz()
        defer { finishUITestApplication(app) }

        XCTAssertTrue(app.openSettingsCategory("settings-category-skills", revealing: "settings-cli-install"))
        let settingsWindow = app.windows.containing(
            .any, identifier: "settings-category-list"
        ).firstMatch
        let settingsForm = settingsWindow.scrollViews.element(boundBy: 1)
        let install = app.buttons["settings-cli-install"]
        XCTAssertTrue(
            install.revealVertically(
                in: settingsForm,
                maximumStep: max(settingsForm.frame.height, 240)),
            "the command-line tool section must scroll into view in Automations")
        XCTAssertTrue(app.buttons["settings-cli-copy-claude"].exists)
        XCTAssertTrue(app.buttons["settings-cli-copy-json"].exists)
        install.click()
        let confirm = app.buttons["settings-cli-install-confirm"]
        XCTAssertTrue(confirm.waitForExistenceFast(timeout: 5))
        confirm.click()

        let remove = app.buttons["settings-cli-remove"]
        XCTAssertTrue(remove.waitForExistenceFast(timeout: 5))
        XCTAssertTrue(
            remove.revealVertically(
                in: settingsForm,
                maximumStep: max(settingsForm.frame.height, 240)))
        XCTAssertTrue(app.buttons["settings-cli-copy-path"].exists)
        attachScreenshot(of: app, named: "settings-command-line-tool")
        remove.click()
        XCTAssertTrue(app.buttons["settings-cli-install"].waitForExistenceFast(timeout: 5))
        XCTAssertFalse(app.control(withIdentifier: "settings-cli-error").exists)
    }

    @MainActor
    func testABuildWithoutTheToolSaysSo() throws {
        let app = try XCUIApplication.portavoz(openSettings: true)
        app.launchPortavoz()
        defer { finishUITestApplication(app) }

        XCTAssertTrue(app.openSettingsCategory("settings-category-skills", revealing: "settings-cli-unavailable"))
        XCTAssertFalse(app.buttons["settings-cli-install"].exists)
    }
}
