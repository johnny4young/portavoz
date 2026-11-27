import XCTest

/// The live recording stage: the clock beside the meeting, Stop, the live
/// Voices table led by whoever is speaking now, the strip and the assist panel.
final class RecordingStageUITests: PortavozUITestCase {
    @MainActor
    func testLiveVoicesLeadWithTheCurrentSpeakerAndFoldTheRest() throws {
        let app = try launchStage(["-seed-wide-window", "-seed-dark-appearance"])
        defer { finishUITestApplication(app) }

        let clock = app.control(withIdentifier: "recording-elapsed-time")
        XCTAssertTrue(clock.waitForExistenceFast(timeout: 10))
        XCTAssertTrue(renderedText(of: clock).hasPrefix("12:"), "the clock reads the call's elapsed time: \(renderedText(of: clock))")
        let returnToRecording = app.buttons["library-return-to-recording"]
        XCTAssertTrue(returnToRecording.label.contains("12:"), "the sidebar shows the elapsed time: \(returnToRecording.label)")
        // A 1024 pt display has room for the shared row, and so three rows, only without the sidebar.
        app.setSidebar(visible: false)

        let you = app.control(withIdentifier: "recording-voice-you")
        XCTAssertTrue(you.waitForExistenceFast(timeout: 10))
        // The scripted call streams in; your open turn is its last row.
        _ = you.waitForLabelContaining("speaking now", timeout: 10)
        XCTAssertTrue(you.label.hasPrefix("You, speaking now"), "you lead while your turn is open: \(you.label)")
        let latest = app.control(withIdentifier: "recording-voice-S1")
        let earlier = app.control(withIdentifier: "recording-voice-S2")
        XCTAssertTrue(latest.waitForExistenceFast(timeout: 5) && earlier.exists)
        XCTAssertLessThan(you.frame.minY, latest.frame.minY)
        XCTAssertLessThan(latest.frame.minY, earlier.frame.minY, "the most recent voice comes first")
        XCTAssertTrue(latest.label.hasPrefix("S1, ") && latest.label.contains("s ago"), latest.label)

        let detail = app.control(withIdentifier: "recording-stage-detail")
        XCTAssertTrue(renderedText(of: detail).contains("12 voices so far"), renderedText(of: detail))
        let others = app.buttons["recording-voices-others"]
        XCTAssertTrue(others.exists)
        // A short display folds more rows; every voice is still a row or in the fold.
        let shown = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'recording-voice-'"))
            .count
        XCTAssertEqual(others.label, "Others · \(12 - shown)")
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
    func testTheStripMarksNowAndYourNoteWithThePanelBesideTheVoices() throws {
        let app = try launchStage(["-seed-wide-window", "-seed-dark-appearance"])
        defer { finishUITestApplication(app) }

        // A 1024 pt display has room for the shared row only without the sidebar.
        app.setSidebar(visible: false)
        let you = app.control(withIdentifier: "recording-voice-you")
        XCTAssertTrue(you.waitForExistenceFast(timeout: 10))
        let panel = app.control(withIdentifier: "recording-assist-panel")
        XCTAssertTrue(panel.exists)
        XCTAssertGreaterThan(panel.frame.minX, you.frame.maxX, "the assist panel sits beside the voices")
        XCTAssertFalse(
            app.control(withIdentifier: "recording-assist-divider").exists, "nothing to split beside the voices")
        XCTAssertTrue(app.buttons["recording-assist-tab-companion"].isSelected, "Apuntador opens first")

        let strip = app.control(withIdentifier: "recording-strip")
        let now = app.control(withIdentifier: "recording-strip-now")
        XCTAssertTrue(strip.exists && now.exists)
        XCTAssertGreaterThan(strip.frame.minY, panel.frame.minY)
        let transcript = app.control(withIdentifier: "recording-live-transcript")
        XCTAssertGreaterThanOrEqual(transcript.frame.minY, strip.frame.maxY, "the captions run under the strip")

        let field = app.control(withIdentifier: "recording-note-field")
        XCTAssertTrue(field.waitForHittable(timeout: 5))
        field.click()
        typeText("Ask about the dashboards", in: app)
        typeKey(.return, modifierFlags: [], in: app)
        let tick = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'recording-strip-tick-'"))
            .firstMatch
        XCTAssertTrue(tick.waitForExistenceFast(timeout: 5), "a note lands on the strip")
        XCTAssertTrue(tick.label.hasPrefix("your note · 12:"), tick.label)
        XCTAssertLessThanOrEqual(tick.frame.maxX, now.frame.minX, "the label flips left of the now edge")
        XCTAssertTrue(app.buttons["recording-assist-tab-notes"].label.hasPrefix("Notes · 1"))
        attachScreenshot(of: app, named: "pr-recording-stage-strip")
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
        let transcript = app.control(withIdentifier: "recording-live-transcript")
        let panel = app.control(withIdentifier: "recording-assist-panel")
        XCTAssertTrue(app.control(withIdentifier: "recording-strip").exists)
        XCTAssertGreaterThanOrEqual(
            panel.frame.minY, transcript.frame.maxY, "narrow, the panel goes under the captions")
        XCTAssertLessThanOrEqual(
            panel.frame.maxY, app.control(withIdentifier: "recording-talk-balance").frame.minY,
            "a short window keeps the panel above the footer")
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
