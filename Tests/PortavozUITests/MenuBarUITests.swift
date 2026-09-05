import XCTest

/// D322 — the phase-3 proposal moment uses the exact production menu-bar
/// content/model in a disposable main-window host. The host avoids brittle
/// SystemUIServer status-item automation while preserving the real app flow.
final class MenuBarUITests: PortavozUITestCase {
    @MainActor
    func testPreMeetingBriefMovesFromExactProposalToDurableReceipt() {
        let app = XCUIApplication.portavoz(
            seedDemo: true,
            seedBrief: true,
            showMenuBarContent: true)
        app.launchPortavoz()
        defer { app.terminate() }

        XCTAssertTrue(app.waitForSeedFixtureReady())
        XCTAssertTrue(app.prepareForInteraction())
        let card = app.control(withIdentifier: "menu-bar-next-meeting")
        let prepare = app.buttons["menu-bar-brief-prepare"]
        XCTAssertTrue(card.waitForExistenceFast(timeout: 10))
        XCTAssertTrue(prepare.waitForStableFrame(timeout: 10))
        XCTAssertTrue(app.buttons["menu-bar-brief-dismiss"].exists)
        XCTAssertTrue(app.buttons["menu-bar-record-next"].exists)
        prepare.click()

        let confirmation = app.control(
            withIdentifier: "menu-bar-brief-confirm-sheet")
        XCTAssertTrue(confirmation.waitForExistenceFast(timeout: 15))
        XCTAssertTrue(app.staticTexts["Presupuesto rollout"].exists)
        XCTAssertTrue(
            app.control(withIdentifier: "menu-bar-brief-capability-local").exists)
        let related = app.descendants(matching: .any)
            .matching(NSPredicate(
                format: "identifier BEGINSWITH 'brief-related-'"))
            .firstMatch
        let openItem = app.descendants(matching: .any)
            .matching(NSPredicate(
                format: "identifier BEGINSWITH 'brief-open-'"))
            .firstMatch
        XCTAssertTrue(
            related.waitForExistenceFast(timeout: 10),
            "the exact preview must carry its related meeting evidence")
        XCTAssertTrue(openItem.waitForExistenceFast(timeout: 10))
        let relatedIdentifier = related.identifier
        let openItemIdentifier = openItem.identifier
        XCTAssertTrue(app.staticTexts["Test meeting"].exists)
        XCTAssertTrue(app.staticTexts["Prepare the rollout"].exists)
        XCTAssertTrue(app.buttons["menu-bar-brief-confirm-cancel"].exists)

        let confirm = app.buttons["menu-bar-brief-confirm-submit"]
        XCTAssertTrue(app.prepareForInteraction())
        XCTAssertTrue(confirm.waitForStableFrame(timeout: 5))
        confirm.click()
        let result = app.control(withIdentifier: "menu-bar-brief-result")
        XCTAssertTrue(
            result.waitForExistenceFast(timeout: 15),
            "successful execution must reveal the same approved artifact")
        XCTAssertTrue(app.staticTexts["Presupuesto rollout"].exists)
        XCTAssertTrue(app.control(withIdentifier: relatedIdentifier).exists)
        XCTAssertTrue(app.control(withIdentifier: openItemIdentifier).exists)
        XCTAssertTrue(app.buttons["menu-bar-brief-result-record"].exists)
        app.buttons["menu-bar-brief-result-close"].click()
        XCTAssertTrue(
            app.control(withIdentifier: "menu-bar-brief-prepared")
                .waitForExistenceFast(timeout: 5))
        XCTAssertFalse(prepare.exists)

        XCTAssertTrue(
            app.openSettingsWindow(),
            "the production Settings command must open its window")
        XCTAssertTrue(
            app.openSettingsCategory(
                "settings-category-skills",
                revealing: "settings-skill-receipt-pre-meeting-brief"),
            "the menu-bar handoff must land in the global durable receipt history")
        attachScreenshot(of: app, named: "menu-bar-pre-meeting-brief-receipt")
    }
}
