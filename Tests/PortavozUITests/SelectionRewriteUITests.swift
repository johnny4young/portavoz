import XCTest

/// The fixture supplies a fixed selection and receiver; no Accessibility, clipboard or engine.
final class SelectionRewriteUITests: PortavozUITestCase {
    @MainActor
    func testRewriteSelectionPreviewsBeforeReplacing() throws {
        let app = try launchRewrite()
        defer { finishUITestApplication(app) }
        openRewrite(app)
        XCTAssertTrue(app.staticTexts["rewrite-original"].waitForExistenceFast(timeout: 5))
        app.buttons["rewrite-choice-polish"].click()
        let preview = app.staticTexts["rewrite-preview"]
        XCTAssertTrue(preview.waitForExistenceFast(timeout: 5))
        XCTAssertTrue(renderedText(of: preview).contains("Don't delete these notes!"))
        app.buttons["rewrite-replace"].click()
        let state = app.staticTexts["rewrite-state"]
        XCTAssertTrue(waitForUITestCondition(timeout: 5) { renderedText(of: state).contains("Rewrite test receiver") })
        XCTAssertFalse(app.buttons["rewrite-replace"].exists)
    }

    @MainActor
    func testARecipeRewriteIsNeverPastedOverAChangedSelection() throws {
        let app = try launchRewrite("-seed-rewrite-selection-changes")
        defer { finishUITestApplication(app) }
        openRewrite(app)
        let recipes = app.control(withIdentifier: "rewrite-recipes")
        XCTAssertTrue(recipes.waitForHittable(timeout: 5))
        recipes.click()
        let bullets = app.menuItems["rewrite-choice-builtin.bullets"]
        XCTAssertTrue(bullets.waitForExistenceFast(timeout: 5))
        bullets.click()
        let preview = app.staticTexts["rewrite-preview"]
        XCTAssertTrue(preview.waitForExistenceFast(timeout: 5))
        XCTAssertTrue(renderedText(of: preview).hasPrefix("- "))
        app.buttons["rewrite-replace"].click()
        XCTAssertTrue(app.buttons["rewrite-copy"].waitForExistenceFast(timeout: 5))
        XCTAssertFalse(app.buttons["rewrite-replace"].exists)
    }

    @MainActor
    func testRewritingWithoutASelectionExplainsWhatToDo() throws {
        let app = try launchRewrite("-seed-rewrite-nothing-selected")
        defer { finishUITestApplication(app) }
        openRewrite(app)
        let state = app.staticTexts["rewrite-state"]
        XCTAssertTrue(state.waitForExistenceFast(timeout: 5))
        XCTAssertTrue(waitForUITestCondition(timeout: 5) { renderedText(of: state).contains("Select some text") })
        XCTAssertFalse(app.buttons["rewrite-choice-polish"].exists)
    }

    @MainActor
    private func launchRewrite(_ arguments: String...) throws -> XCUIApplication {
        let app = try XCUIApplication.portavoz(showMenuBarContent: true)
        app.launchArguments += arguments
        app.launchEnvironment["PORTAVOZ_UI_TEST_DEFAULTS"] = #"{"globalDictationEnabled":true}"#
        app.launchPortavoz()
        return app
    }

    @MainActor
    private func openRewrite(_ app: XCUIApplication) {
        XCTAssertTrue(app.prepareForInteraction())
        let rewrite = app.buttons["menu-bar-rewrite-selection"]
        XCTAssertTrue(rewrite.waitForStableFrame(timeout: 5))
        rewrite.click()
    }
}
