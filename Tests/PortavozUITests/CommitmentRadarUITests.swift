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
