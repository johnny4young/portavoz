import XCTest

/// Drives a seeded meeting to verify the detail view renders — the
/// automated stand-in for eyeballing it. Launches with `-seed-demo` so the
/// library has one deterministic meeting with a transcript, a summary, and
/// a coauthoring bullet (D28).
final class MeetingDetailUITests: XCTestCase {
    /// Launches the app on the seeded meeting with isolated audio. Point
    /// PORTAVOZ_TEST_AUDIO_ROOT at a folder holding a REAL recording
    /// (Audio/<uuid>/…) to exercise the player on real audio instead.
    @MainActor
    private func launchOnSeededMeeting() -> XCUIApplication {
        let app = XCUIApplication.portavoz(seedDemo: true)
        app.launchEnvironment["PORTAVOZ_AUDIO_ROOT"] =
            ProcessInfo.processInfo.environment["PORTAVOZ_TEST_AUDIO_ROOT"]
            ?? (NSTemporaryDirectory() + "portavoz-uitest-\(UUID().uuidString)")
        app.launchPortavoz()
        let meeting = app.staticTexts["Test meeting"]
        XCTAssertTrue(
            meeting.waitForExistence(timeout: 15), "the seeded meeting must appear in the library")
        meeting.click()
        return app
    }

    @MainActor
    func testSeededMeetingShowsTranscriptAndCoauthoringBullet() {
        let app = launchOnSeededMeeting()
        defer { app.terminate() }

        // The transcript rendered (this line is unique to the transcript).
        XCTAssertTrue(
            app.staticTexts["Revisemos el presupuesto de transcripción."]
                .waitForExistence(timeout: 10),
            "the detail view must render the seeded transcript")

        // The summary rendered (its overview is unique to the summary block).
        XCTAssertTrue(
            app.staticTexts["El equipo revisó el presupuesto y fijó el rollout."]
                .waitForExistence(timeout: 10),
            "the summary block must render")

        // The D28 coauthoring marker: only the note-derived bullet carries "▸".
        XCTAssertTrue(
            app.staticTexts["▸"].waitForExistence(timeout: 5),
            "a bullet born from a user note must render its ▸ coauthoring marker")

        // The player rendered — the seed wrote audio, so the transport bar
        // (M11) exists and can be played.
        let play = app.buttons["player-play-pause"]
        XCTAssertTrue(
            play.waitForExistence(timeout: 5),
            "the player transport must render for a meeting that has audio")
        play.click()  // smoke: play doesn't crash
    }

    /// Marking in/out reveals the clip export button (M11). Advances the
    /// playhead by playing, so it doesn't depend on clicking a transcript
    /// line (dimmed/clipped in the focus carousel).
    @MainActor
    func testClipMarkingRevealsExport() {
        let app = launchOnSeededMeeting()
        defer { app.terminate() }

        XCTAssertTrue(app.buttons["player-play-pause"].waitForExistence(timeout: 15))
        app.buttons["player-play-pause"].click()  // play → the playhead moves
        app.buttons["clip-mark-start"].click()
        Thread.sleep(forTimeInterval: 1.5)  // let the playhead advance
        app.buttons["clip-mark-end"].click()  // end after start → valid range

        XCTAssertTrue(
            app.buttons["clip-export"].waitForExistence(timeout: 5),
            "marking a valid in/out range must reveal the export button")
    }
}
