import XCTest

/// D322 — the phase-3 proposal moment uses the exact production menu-bar
/// content/model in a disposable main-window host. The host avoids brittle
/// SystemUIServer status-item automation while preserving the real app flow.
final class MenuBarUITests: PortavozUITestCase {
    @MainActor
    func testPreMeetingBriefMovesFromExactProposalToDurableReceipt() throws {
        let app = try XCUIApplication.portavoz(
            seedDemo: true,
            seedBrief: true,
            showMenuBarContent: true)
        app.launchPortavoz()
        defer { finishUITestApplication(app) }

        XCTAssertTrue(app.waitForSeedFixtureReady())
        XCTAssertTrue(app.prepareForInteraction())
        let card = app.control(withIdentifier: "menu-bar-next-meeting")
        let prepare = app.buttons["menu-bar-brief-prepare"]
        XCTAssertTrue(card.waitForExistenceFast(timeout: 10))
        XCTAssertTrue(prepare.waitForStableFrame(timeout: 10))
        XCTAssertTrue(app.buttons["menu-bar-brief-dismiss"].exists)
        XCTAssertTrue(app.buttons["menu-bar-record-next"].exists)
        XCTAssertTrue(app.buttons["menu-bar-record"].exists)
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

    @MainActor
    func testRecordingPanelNamesWhoIsSpeakingOverTheLiveStrip() throws {
        let app = try XCUIApplication.portavoz(
            seedDemo: true,
            seedBrief: true,
            showMenuBarContent: true)
        app.launchArguments += ["-simulate-live-voices", "-seed-dark-appearance"]
        app.launchPortavoz()
        defer { finishUITestApplication(app) }

        XCTAssertTrue(app.waitForSeedFixtureReady())
        let panel = app.control(withIdentifier: "menu-bar-panel")
        XCTAssertTrue(panel.waitForExistenceFast(timeout: 10))
        let speaker = app.control(withIdentifier: "menu-bar-speaker")
        XCTAssertTrue(speaker.waitForExistenceFast(timeout: 15))
        // The scripted call ends on your open turn, after S1 and S2.
        _ = speaker.waitForLabelContaining("You speaking", timeout: 10)
        attachElementScreenshot(of: panel, named: "pr-menu-bar-recording")
        XCTAssertTrue(speaker.label.hasPrefix("You speaking, then S1, S2"), speaker.label)
        XCTAssertTrue(speaker.label.hasSuffix("12 voices"), speaker.label)

        let clock = app.control(withIdentifier: "menu-bar-elapsed-time")
        XCTAssertTrue(renderedText(of: clock).hasPrefix("12:"), renderedText(of: clock))
        XCTAssertTrue(app.control(withIdentifier: "menu-bar-recording-title").exists)
        XCTAssertTrue(app.control(withIdentifier: "menu-bar-live-strip").exists)
        XCTAssertTrue(app.buttons["menu-bar-stop"].exists)
        XCTAssertTrue(app.buttons["menu-bar-ask"].exists)
        XCTAssertFalse(app.buttons["menu-bar-record"].exists, "Stop replaces Record while recording")
        XCTAssertFalse(app.buttons["menu-bar-record-next"].exists, "one recording at a time")
        XCTAssertTrue(app.control(withIdentifier: "menu-bar-next-meeting").exists)
        XCTAssertTrue(app.buttons["menu-bar-brief-prepare"].exists)
        XCTAssertTrue(app.buttons["menu-bar-open"].exists)
        XCTAssertTrue(app.control(withIdentifier: "menu-bar-launch-at-login").exists)
        XCTAssertTrue(app.buttons["menu-bar-quit"].exists)

        XCTAssertTrue(app.control(withIdentifier: "menu-bar-recent-strip").exists)
    }
}
