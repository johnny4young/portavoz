import XCTest

/// Drives a seeded meeting to verify the redesigned detail view renders —
/// the automated stand-in for eyeballing it. Launches with `-seed-demo`
/// so the library has one deterministic meeting with a transcript, a
/// tabbed summary (with a coauthoring ▸ bullet under Decisiones), meeting
/// health and chapters in the right rail, and a player.
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
        // Select the real library row by structure, not the duplicated title
        // text (it also appears under To-dos and can point at a stale scroll
        // snapshot during rapid relaunches).
        let meeting = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'library-meeting-'"))
            .firstMatch
        XCTAssertTrue(
            meeting.waitForExistence(timeout: 15), "the seeded meeting must appear in the library")
        meeting.click()
        return app
    }

    @MainActor
    func testTabbedSummaryRevealsTheCoauthoringBullet() {
        let app = launchOnSeededMeeting()
        defer { app.terminate() }

        // The transcript rendered (this line is unique to the transcript).
        XCTAssertTrue(
            app.staticTexts["Revisemos el presupuesto de transcripción."]
                .waitForExistence(timeout: 10),
            "the detail view must render the seeded transcript")

        // The default "Summary" tab shows the intro/overview.
        XCTAssertTrue(
            app.staticTexts["El equipo revisó el presupuesto y fijó el rollout."]
                .waitForExistence(timeout: 10),
            "the summary's Summary tab must show the overview")

        // The ▸ coauthoring marker lives under the Decisiones section, now
        // behind its own tab — switching to it reveals the bullet.
        app.control(withIdentifier: "summary-tab-1").click()
        XCTAssertTrue(
            app.staticTexts["▸"].waitForExistence(timeout: 5),
            "the Decisiones tab must reveal the ▸ coauthored bullet (D28)")
    }

    @MainActor
    func testRightRailShowsHealthAndChapters() {
        let app = launchOnSeededMeeting()
        defer { app.terminate() }

        XCTAssertTrue(
            app.control(withIdentifier: "detail-meeting-health").waitForExistence(timeout: 10),
            "the right rail must show meeting health")
        // The refine control (now a menu with a per-meeting language override)
        // is present for a meeting that keeps its audio.
        XCTAssertTrue(
            app.control(withIdentifier: "detail-refine").exists,
            "the action row must offer the refine control")
        XCTAssertTrue(
            app.control(withIdentifier: "detail-chapters").exists,
            "the right rail must show the ✦ chapters (the seed has a second chapter)")
        // The second chapter is the 200 s turn — proving a real break was
        // found (the title itself truncates in the narrow rail).
        XCTAssertTrue(
            app.control(withIdentifier: "chapter-200").exists,
            "a chapter must mark the later turn the seed placed at 200 s")
        // The persisted Companion cards (D26) render in the rail: the seed
        // has an answered card (askedAt 6) and an "asked you" ping (200).
        XCTAssertTrue(
            app.control(withIdentifier: "detail-companion").exists,
            "the right rail must show the persisted Companion answers")
        XCTAssertTrue(
            app.control(withIdentifier: "companion-card-6").exists,
            "the answered Companion card must render for review")
    }

    @MainActor
    func testPlayerExposesSkipAndOnlyMyVoice() {
        let app = launchOnSeededMeeting()
        defer { app.terminate() }

        let play = app.buttons["player-play-pause"]
        XCTAssertTrue(
            play.waitForExistence(timeout: 10),
            "the player transport must render for a meeting that has audio")
        XCTAssertTrue(
            app.control(withIdentifier: "player-only-my-voice").exists,
            "the player must offer the 'only my voice' filter")
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
