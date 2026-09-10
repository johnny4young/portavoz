import XCTest

final class StatedPriorityUITests: PortavozUITestCase {
    /// GAPS #13 / D505: a priority somebody states out loud used to have
    /// nowhere to go — the transcript kept it, the summary reduced it to a
    /// status line, and no typed truth held it. The real detector runs over the
    /// caption here; only its text is seeded.
    @MainActor
    func testAStatedPriorityIsOfferedAndBecomesAnObjective() {
        let app = XCUIApplication.portavoz(
            seedDemo: true,
            simulateSequoiaCapabilities: true,
            simulateLiveTranscriptBrowsing: true)
        app.launchArguments.append("-seed-stated-priority-ui")
        app.launchPortavoz()
        defer { app.terminate() }

        let record = app.buttons["library-new-recording-button"]
        XCTAssertTrue(record.waitForExistenceFast(timeout: 15))
        record.click()
        XCTAssertTrue(
            app.waitForLiveTranscriptFrontier(),
            "the detector runs on finalized captions")

        let card = app.control(withIdentifier: "recording-priority-card")
        XCTAssertTrue(
            card.waitForExistenceFast(timeout: 15),
            "an explicitly stated priority must reach the focus slot")
        XCTAssertTrue(
            app.staticTexts["the billing migration"].exists,
            "the offer names the bounded subject, not the whole sentence")

        let accept = app.control(withIdentifier: "recording-priority-accept")
        XCTAssertTrue(accept.exists, "the offer is inert until the user accepts it")
        XCTAssertTrue(
            app.control(withIdentifier: "recording-priority-dismiss").exists,
            "declining is what records the subject as handled, so it must be there")
        accept.click()

        XCTAssertFalse(
            card.waitForExistenceFast(timeout: 3),
            "an accepted offer leaves the slot")

        // Objectives are what carry it past Stop: they persist as context items
        // and shape the final summary.
        app.openAssistTab("objectives")
        let saved = app.descendants(matching: .any)
            .matching(NSPredicate(
                format: "identifier BEGINSWITH %@ AND label == %@",
                "recording-objective-text-",
                "the billing migration"))
            .firstMatch
        XCTAssertTrue(
            saved.waitForExistenceFast(timeout: 5),
            "accepting must add the exact subject as an objective")
    }
}
