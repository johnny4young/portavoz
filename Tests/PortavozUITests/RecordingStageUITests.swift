import XCTest

/// The live recording stage: the clock beside the meeting, Stop, and the live
/// Voices table led by whoever is speaking now.
final class RecordingStageUITests: PortavozUITestCase {
    @MainActor
    func testLiveVoicesLeadWithTheCurrentSpeakerAndFoldTheRest() throws {
        let app = try launchStage(["-seed-wide-window", "-seed-dark-appearance"])
        defer { finishUITestApplication(app) }

        let you = app.control(withIdentifier: "recording-voice-you")
        XCTAssertTrue(you.waitForExistenceFast(timeout: 10))
        XCTAssertTrue(you.label.hasPrefix("You, speaking now"), "you lead while your turn is open: \(you.label)")
        let latest = app.control(withIdentifier: "recording-voice-S1")
        let earlier = app.control(withIdentifier: "recording-voice-S2")
        XCTAssertTrue(latest.waitForExistenceFast(timeout: 5) && earlier.exists)
        XCTAssertLessThan(you.frame.minY, latest.frame.minY)
        XCTAssertLessThan(latest.frame.minY, earlier.frame.minY, "the most recent voice comes first")
        XCTAssertTrue(latest.label.hasPrefix("S1, ") && latest.label.contains("s ago"), latest.label)

        let detail = app.control(withIdentifier: "recording-stage-detail")
        XCTAssertTrue(renderedText(of: detail).contains("12 voices so far"), renderedText(of: detail))
        let clock = app.control(withIdentifier: "recording-elapsed-time")
        XCTAssertTrue(renderedText(of: clock).hasPrefix("12:"), "the clock reads the call's elapsed time: \(renderedText(of: clock))")
        let returnToRecording = app.buttons["library-return-to-recording"]
        XCTAssertTrue(returnToRecording.label.contains("12:"), "the sidebar shows the elapsed time: \(returnToRecording.label)")

        let others = app.buttons["recording-voices-others"]
        XCTAssertTrue(others.exists)
        XCTAssertEqual(others.label, "Others · 6")
        XCTAssertFalse(app.control(withIdentifier: "recording-voice-S6").exists)
        attachScreenshot(of: app, named: "pr-recording-stage")
        others.click()
        XCTAssertTrue(app.control(withIdentifier: "recording-voice-S6").waitForExistenceFast(timeout: 3))
        others.click()
        XCTAssertTrue(app.control(withIdentifier: "recording-voice-S6").waitForDisappearance(timeout: 3))
        XCTAssertTrue(app.control(withIdentifier: "recording-talk-balance").exists)
        XCTAssertTrue(app.control(withIdentifier: "recording-mute-mic").exists)
    }

    @MainActor
    func testTheStageKeepsStopAndTheTitleApartAtTheMinimumWidth() throws {
        let app = try launchStage(["-seed-narrow-window", "-seed-dark-appearance"])
        defer { finishUITestApplication(app) }

        XCTAssertTrue(app.control(withIdentifier: "recording-voice-you").waitForExistenceFast(timeout: 10))
        let stop = app.buttons["recording-stop"]
        let title = app.control(withIdentifier: "recording-stage-title")
        let clock = app.control(withIdentifier: "recording-elapsed-time")
        XCTAssertTrue(stop.isHittable)
        XCTAssertFalse(title.frame.intersects(stop.frame), "the title must not run under Stop")
        XCTAssertFalse(clock.frame.intersects(title.frame))
        XCTAssertGreaterThan(clock.frame.width, clock.frame.height, "the clock stays on one line")
        XCTAssertTrue(app.buttons["recording-catch-up"].isHittable)
        attachScreenshot(of: app, named: "pr-recording-stage-min")
    }

    @MainActor
    func testTheStageReadsInLightAtTheStandardWidth() throws {
        let app = try launchStage(["-AppleInterfaceStyle", "Light"])
        defer { finishUITestApplication(app) }

        XCTAssertTrue(app.control(withIdentifier: "recording-voice-you").waitForExistenceFast(timeout: 10))
        XCTAssertTrue(app.buttons["recording-stop"].isHittable)
        attachScreenshot(of: app, named: "pr-recording-stage-mid")
    }

    @MainActor
    private func launchStage(_ arguments: [String]) throws -> XCUIApplication {
        let app = try XCUIApplication.portavoz(seedDemo: true, simulateNoAppleIntelligence: true)
        app.launchArguments += ["-simulate-live-voices"] + arguments
        app.launchPortavoz()
        XCTAssertTrue(app.waitForSeededLibraryToSettle())
        app.buttons["library-new-recording-button"].click()
        XCTAssertTrue(app.buttons["recording-stop"].waitForExistenceFast(timeout: 10))
        return app
    }
}
