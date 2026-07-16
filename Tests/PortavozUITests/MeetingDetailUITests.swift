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
    private func launchOnSeededMeeting(
        latestRecipe: Bool = false,
        refineRunning: Bool = false,
        justRecorded: Bool = false
    ) -> XCUIApplication {
        let app = XCUIApplication.portavoz(
            seedDemo: true,
            seedLatestRecipe: latestRecipe,
            seedRefineRunning: refineRunning,
            seedJustRecorded: justRecorded)
        if justRecorded {
            app.launchArguments += ["-mirrorAfterMeeting", "true"]
        }
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
        // Existing isn't enough on the coldest launch: seeding bumps
        // libraryVersion, the list re-renders, and `click` re-resolves this
        // query — against a snapshot that can already be stale ("Failed to get
        // matching snapshot"). Waiting for hittable re-resolves until it settles.
        let settled = expectation(
            for: NSPredicate(format: "isHittable == true"), evaluatedWith: meeting)
        wait(for: [settled], timeout: 10)
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
    func testMostRecentRecipeRemainsVisibleAfterReload() {
        let app = launchOnSeededMeeting(latestRecipe: true)
        defer { app.terminate() }

        let badge = app.control(withIdentifier: "summary-badge")
        XCTAssertTrue(
            badge.waitForExistence(timeout: 10),
            "the active summary must expose its recipe-aware badge")
        XCTAssertEqual(
            badge.value as? String,
            "v1 · es · Standup",
            "the latest Standup snapshot must remain selected after Meeting Detail reloads")
        XCTAssertTrue(
            app.staticTexts["El resumen de standup sigue visible después de recargar."]
                .waitForExistence(timeout: 5),
            "reload must not replace the latest structured summary with the older General one")
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
        // These WAIT: the cards are fetched separately from the meeting
        // detail, so the section lands a beat after the rest of the rail.
        XCTAssertTrue(
            app.control(withIdentifier: "detail-companion").waitForExistence(timeout: 5),
            "the right rail must show the persisted Companion answers")
        XCTAssertTrue(
            app.control(withIdentifier: "companion-card-6").waitForExistence(timeout: 5),
            "the answered Companion card must render for review")

        attachScreenshot(of: app, named: "band-2o-meeting-review")
    }

    @MainActor
    func testFreshQualifyingMeetingShowsThePostMeetingMirror() {
        let app = launchOnSeededMeeting(justRecorded: true)
        defer { app.terminate() }

        XCTAssertTrue(
            app.control(withIdentifier: "mirror-card").waitForExistence(timeout: 10),
            "an opted-in fresh qualifying meeting must show its factual mirror")
        attachScreenshot(of: app, named: "band-2q-post-meeting-mirror")
    }

    @MainActor
    func testRunningRefineCanBeCanceledWithoutChangingTheTranscript() {
        let app = launchOnSeededMeeting(refineRunning: true)
        defer { app.terminate() }

        let refine = app.control(withIdentifier: "detail-refine")
        XCTAssertEqual(refine.value as? String, "cancel")
        refine.click()

        let returnedToRefine = expectation(
            for: NSPredicate(format: "value == 'refine'"),
            evaluatedWith: refine)
        wait(for: [returnedToRefine], timeout: 5)
        XCTAssertTrue(
            app.staticTexts["Revisemos el presupuesto de transcripción."].exists,
            "canceling a quality pass must leave the current transcript visible")
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
