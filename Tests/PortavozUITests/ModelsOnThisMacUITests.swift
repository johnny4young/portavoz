import XCTest

final class ModelsOnThisMacUITests: PortavozUITestCase {
    @MainActor
    func testTheDataPaneListsAModelAnotherAppAlsoUses() throws {
        let app = try XCUIApplication.portavoz(openSettings: true)
        app.launchArguments.append("-seed-shared-model")
        app.launchPortavoz()
        defer { finishUITestApplication(app) }

        XCTAssertTrue(app.openSettingsCategory("settings-category-data", revealing: "settings-export-preferences"))
        let predicate = NSPredicate(
            format: "identifier BEGINSWITH 'settings-installed-model-shared-fixture' AND identifier ENDSWITH '-detail'")
        let row = app.descendants(matching: .any).matching(predicate).firstMatch

        XCTAssertTrue(row.waitForExistenceFast(timeout: 10), "the seeded model is listed")
        let expected = UITestLocale.environmentLocale == "es" ? "También lo usa Secreteo" : "Also used by Secreteo"
        XCTAssertTrue(waitForUITestCondition(timeout: 5) { renderedText(of: row).contains(expected) })
        attachScreenshot(of: app, named: "pr-models-on-this-mac")
    }
}
