import XCTest

final class CommitmentRadarUITests: PortavozUITestCase {
    @MainActor
    func testRadarFiltersConfirmedWorkAndOpensItsExactSourceMeeting() {
        let app = XCUIApplication.portavoz(
            seedDemo: true,
            seedCommitmentRadar: true)
        app.launchPortavoz()
        defer { app.terminate() }

        XCTAssertTrue(app.waitForSeededLibraryToSettle())
        let radar = app.buttons["library-commitment-radar-button"]
        XCTAssertTrue(radar.waitForExistence(timeout: 10))
        radar.click()

        XCTAssertTrue(
            app.control(withIdentifier: "commitment-radar-title")
                .waitForExistence(timeout: 10))
        let enableReminders = app.control(
            withIdentifier: "commitment-reminder-enable")
        XCTAssertTrue(
            enableReminders.waitForExistence(timeout: 10),
            "launch inspection must not prompt before the explicit Radar action")
        enableReminders.click()
        XCTAssertTrue(
            app.control(withIdentifier: "commitment-reminder-enabled")
                .waitForExistence(timeout: 10),
            "explicit permission should reconcile confirmed due work")
        XCTAssertFalse(enableReminders.exists)
        attachScreenshot(of: app, named: "commitment-radar-reminders-enabled")

        let mineID = "B5D10000-0000-4000-8000-000000000002"
        let otherID = "B5D10000-0000-4000-8000-000000000001"
        XCTAssertTrue(
            app.control(withIdentifier: "commitment-radar-item-\(mineID)")
                .waitForExistence(timeout: 10))
        XCTAssertTrue(
            app.control(withIdentifier: "commitment-radar-item-\(otherID)").exists)

        let owner = app.control(withIdentifier: "commitment-radar-owner-filter")
        XCTAssertTrue(owner.waitForExistence(timeout: 5))
        owner.click()
        let mine = app.menuItems["commitment-radar-owner-mine"]
        XCTAssertTrue(mine.waitForExistence(timeout: 5))
        mine.click()

        XCTAssertTrue(
            app.control(withIdentifier: "commitment-radar-item-\(mineID)")
                .waitForExistence(timeout: 10))
        XCTAssertFalse(
            app.control(withIdentifier: "commitment-radar-item-\(otherID)").exists,
            "the owner filter must not mix another person's confirmed work")
        attachScreenshot(of: app, named: "commitment-radar")

        let due = app.control(withIdentifier: "commitment-radar-due-\(mineID)")
        XCTAssertTrue(due.waitForExistence(timeout: 5))
        due.click()
        XCTAssertTrue(
            app.control(withIdentifier: "commitment-radar-due-editor")
                .waitForExistence(timeout: 5))
        attachScreenshot(of: app, named: "commitment-radar-due-date")
        app.control(withIdentifier: "commitment-radar-due-toggle").click()
        app.control(withIdentifier: "commitment-radar-due-save").click()
        XCTAssertTrue(
            app.control(
                withIdentifier: "commitment-radar-due-value-\(mineID)-none")
                .waitForExistence(timeout: 10),
            "rescheduling must persist and reload the exact Radar item")
        attachScreenshot(of: app, named: "commitment-radar-rescheduled")

        let complete = app.control(
            withIdentifier: "commitment-radar-complete-\(mineID)")
        XCTAssertTrue(complete.waitForExistence(timeout: 5))
        complete.click()
        XCTAssertTrue(
            app.control(withIdentifier: "commitment-radar-reopen-\(mineID)")
                .waitForExistence(timeout: 10),
            "completion must persist and return as a durable Radar action")
        attachScreenshot(of: app, named: "commitment-radar-completed")

        let source = app.control(
            withIdentifier: "commitment-radar-source-B5D20000-0000-4000-8000-000000000002")
        XCTAssertTrue(source.waitForExistence(timeout: 5))
        source.click()
        XCTAssertTrue(
            app.control(withIdentifier: "detail-header-section")
                .waitForExistence(timeout: 10),
            "a Radar source must open its exact durable meeting")
        XCTAssertTrue(app.staticTexts["Test meeting"].exists)
    }
}
