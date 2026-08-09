import XCTest

/// D317 — the management pane and the proposal surface share one durable
/// policy. This one-launch journey proves both directions plus the bounded
/// receipt projection without touching the user's real library.
final class SkillsSettingsUITests: PortavozUITestCase {
    @MainActor
    func testSkillsPaneFailsClosedWhenDurablePolicyCannotLoad() {
        let app = XCUIApplication.portavoz(openSettings: true)
        app.launchArguments.append("-simulate-skill-control-unavailable")
        app.launchPortavoz()
        defer { app.terminate() }

        let category = app.control(
            withIdentifier: "settings-category-skills")
        XCTAssertTrue(category.waitForExistence(timeout: 10))
        category.click()

        XCTAssertTrue(
            app.control(withIdentifier: "settings-skills-load-error")
                .waitForExistence(timeout: 10))
        let retry = app.buttons["settings-skills-retry"]
        XCTAssertTrue(retry.waitForExistence(timeout: 5))
        XCTAssertFalse(
            app.control(withIdentifier: "settings-skills-pause-all").exists,
            "a missing durable policy must never become implicit authority")
        XCTAssertFalse(
            app.control(withIdentifier: "settings-skill-recap-draft-enabled").exists,
            "a missing durable policy must not expose a partial catalogue")
        retry.click()
        XCTAssertTrue(retry.waitForExistence(timeout: 5))
        attachScreenshot(of: app, named: "skills-control-fail-closed")
    }

    @MainActor
    func testSkillsPaneControlsOffersAndShowsTheConfirmedReceipt() {
        let app = XCUIApplication.portavoz(seedDemo: true)
        app.launchPortavoz()
        defer { app.terminate() }

        XCTAssertTrue(app.waitForSeededLibraryToSettle())
        openSkillsSettings(in: app)
        assertInitialCatalogueAndPause(in: app)

        closeSettings(in: app)
        openSeededMeeting(in: app)
        XCTAssertTrue(
            app.control(withIdentifier: "summary-tab-0")
                .waitForExistence(timeout: 10))
        assertOfferMenuStaysAbsent(in: app)

        openSkillsSettings(in: app)
        assertDurableChoicesAndResume(in: app)
        closeSettings(in: app)
        reloadSeededMeeting(in: app)
        confirmRecapOffer(in: app)
        assertRecentReceiptInSettings(in: app)
    }

    @MainActor
    private func assertInitialCatalogueAndPause(in app: XCUIApplication) {
        let pause = app.control(
            withIdentifier: "settings-skills-pause-all")
        let recap = app.control(
            withIdentifier: "settings-skill-recap-draft-enabled")
        let export = app.control(
            withIdentifier: "settings-skill-meeting-package-export-enabled")
        XCTAssertTrue(pause.waitForExistence(timeout: 5))
        XCTAssertTrue(recap.waitForExistence(timeout: 5))
        XCTAssertTrue(export.waitForExistence(timeout: 5))
        XCTAssertFalse(Self.isOn(pause))
        XCTAssertTrue(Self.isOn(recap))
        XCTAssertTrue(Self.isOn(export))
        XCTAssertTrue(
            app.control(withIdentifier: "settings-skill-reminder-draft-planned")
                .waitForExistence(timeout: 5))
        let brief = app.control(
            withIdentifier: "settings-skill-pre-meeting-brief-enabled")
        XCTAssertTrue(brief.waitForExistence(timeout: 5))
        XCTAssertTrue(Self.isOn(brief))

        // Individual choices survive the independent global pause override.
        export.click()
        XCTAssertTrue(waitForToggle(export, toBeOn: false))
        pause.click()
        XCTAssertTrue(waitForToggle(pause, toBeOn: true))
        XCTAssertTrue(
            app.staticTexts["settings-skills-paused-status"]
                .waitForExistence(timeout: 5))
        attachScreenshot(of: app, named: "skills-control-paused")
    }

    @MainActor
    private func assertDurableChoicesAndResume(in app: XCUIApplication) {
        // The settings snapshot is durable across window reconstruction.
        let durablePause = app.control(
            withIdentifier: "settings-skills-pause-all")
        let durableExport = app.control(
            withIdentifier: "settings-skill-meeting-package-export-enabled")
        XCTAssertTrue(durablePause.waitForExistence(timeout: 5))
        XCTAssertTrue(durableExport.waitForExistence(timeout: 5))
        XCTAssertTrue(Self.isOn(durablePause))
        XCTAssertFalse(Self.isOn(durableExport))
        durablePause.click()
        XCTAssertTrue(waitForToggle(durablePause, toBeOn: false))
    }

    @MainActor
    private func confirmRecapOffer(in app: XCUIApplication) {
        // Resuming restores the recap choice but keeps export disabled.
        let menu = app.control(withIdentifier: "skill-offer-menu")
        XCTAssertTrue(menu.waitForExistence(timeout: 10))
        XCTAssertTrue(menu.waitForStableFrame(timeout: 5))
        menu.click()
        let recapOffer = app.menuItems["skill-offer-recap-draft"]
        XCTAssertTrue(recapOffer.waitForExistence(timeout: 5))
        XCTAssertFalse(app.menuItems["skill-offer-package-export"].exists)
        recapOffer.click()

        let submit = app.buttons["skill-confirm-submit"]
        XCTAssertTrue(submit.waitForStableFrame(timeout: 5))
        submit.click()
        XCTAssertTrue(
            app.control(withIdentifier: "skill-receipt-recap-draft")
                .waitForExistence(timeout: 10))
    }

    @MainActor
    private func assertRecentReceiptInSettings(in app: XCUIApplication) {
        openSkillsSettings(in: app)
        let receipt = app.control(
            withIdentifier: "settings-skill-receipt-recap-draft")
        XCTAssertTrue(
            receipt.waitForExistence(timeout: 10),
            "the management pane must project the confirmed durable receipt")
        XCTAssertFalse(Self.isOn(app.control(
            withIdentifier: "settings-skill-meeting-package-export-enabled")))
        scrollToVisible(receipt, in: app)
        attachScreenshot(of: app, named: "skills-control-recent-receipt")
    }

    @MainActor
    private func openSkillsSettings(in app: XCUIApplication) {
        app.typeKey(",", modifierFlags: .command)
        let category = app.control(
            withIdentifier: "settings-category-skills")
        XCTAssertTrue(category.waitForExistence(timeout: 10))
        category.click()
    }

    @MainActor
    private func closeSettings(in app: XCUIApplication) {
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(app.prepareForInteraction())
    }

    @MainActor
    private func openSeededMeeting(in app: XCUIApplication) {
        let meeting = seededMeeting(in: app)
        XCTAssertTrue(meeting.waitForStableFrame(timeout: 10))
        meeting.click()
    }

    @MainActor
    private func reloadSeededMeeting(in app: XCUIApplication) {
        let insights = app.control(
            withIdentifier: "library-insights-button")
        XCTAssertTrue(insights.waitForStableFrame(timeout: 5))
        insights.click()
        openSeededMeeting(in: app)
    }

    @MainActor
    private func seededMeeting(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(
                format: "identifier BEGINSWITH 'library-meeting-'"))
            .firstMatch
    }

    @MainActor
    private func assertOfferMenuStaysAbsent(in app: XCUIApplication) {
        let unexpected = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true"),
            object: app.control(withIdentifier: "skill-offer-menu"))
        unexpected.isInverted = true
        XCTAssertEqual(
            XCTWaiter.wait(for: [unexpected], timeout: 2),
            .completed,
            "global pause must keep every proposal off the meeting surface")
    }

    @MainActor
    private func waitForToggle(
        _ toggle: XCUIElement,
        toBeOn expected: Bool,
        timeout: TimeInterval = 5
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if toggle.exists, Self.isOn(toggle) == expected { return true }
            Thread.sleep(forTimeInterval: 0.1)
        } while Date() < deadline
        return false
    }

    @MainActor
    private func scrollToVisible(
        _ element: XCUIElement,
        in app: XCUIApplication
    ) {
        let window = app.windows.containing(
            .any,
            identifier: "settings-skills-pause-all"
        ).firstMatch
        guard window.exists else { return }
        let form = window.scrollViews.element(boundBy: 1)
        guard form.exists else { return }
        for _ in 0..<16 where !element.isHittable {
            form.scroll(byDeltaX: 0, deltaY: -5)
        }
    }

    @MainActor
    private static func isOn(_ toggle: XCUIElement) -> Bool {
        (toggle.value as? Int) == 1 || (toggle.value as? String) == "1"
    }
}
