import XCTest

/// Drives a seeded meeting to verify the redesigned detail view renders —
/// the automated stand-in for eyeballing it. Launches with `-seed-demo`
/// so the library has one deterministic meeting with a transcript, a
/// tabbed summary (with a coauthoring ▸ bullet under Decisiones), meeting
/// health, chapters, a content-free privacy receipt in the right rail, and a
/// player.
final class MeetingDetailUITests: XCTestCase {
    /// Launches the app on the seeded meeting with isolated audio. Point
    /// PORTAVOZ_TEST_AUDIO_ROOT at a folder holding a REAL recording
    /// (Audio/<uuid>/…) to exercise the player on real audio instead.
    @MainActor
    private func launchOnSeededMeeting(
        latestRecipe: Bool = false,
        refineRunning: Bool = false,
        justRecorded: Bool = false,
        processingFailure: Bool = false,
        withoutSummary: Bool = false,
        simulateSequoiaCapabilities: Bool = false,
        summaryEngine: String? = nil
    ) -> XCUIApplication {
        let app = XCUIApplication.portavoz(
            seedDemo: true,
            seedLatestRecipe: latestRecipe,
            seedRefineRunning: refineRunning,
            seedJustRecorded: justRecorded,
            seedProcessingFailure: processingFailure,
            seedWithoutSummary: withoutSummary,
            simulateSequoiaCapabilities: simulateSequoiaCapabilities)
        if justRecorded {
            app.launchArguments += ["-mirrorAfterMeeting", "true"]
        }
        if let summaryEngine {
            app.launchArguments += ["-summaryEngine", summaryEngine]
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
    func testFailedDurableProcessingOffersOneRecoveryAction() {
        let app = launchOnSeededMeeting(processingFailure: true)
        defer { app.terminate() }

        XCTAssertTrue(
            app.control(withIdentifier: "detail-processing-status")
                .waitForExistence(timeout: 10),
            "a durable failure must be visible beside the meeting")
        let retry = app.buttons["detail-retry-processing"]
        XCTAssertTrue(
            retry.waitForExistence(timeout: 5),
            "a terminal durable failure must expose one explicit retry action")
        attachScreenshot(of: app, named: "band-3i-actionable-processing")
        retry.click()
    }

    @MainActor
    func testSequoiaSummaryFailureOpensExactSetupAndExplainsCompanion() {
        let app = launchOnSeededMeeting(
            withoutSummary: true,
            simulateSequoiaCapabilities: true,
            summaryEngine: "appleOnDevice")
        defer { app.terminate() }

        let generate = app.buttons["detail-generate-summary"]
        XCTAssertTrue(
            generate.waitForExistence(timeout: 10),
            "a meeting without a summary must offer generation")
        generate.click()

        let openSettings = app.buttons["detail-summary-open-settings"]
        XCTAssertTrue(
            openSettings.waitForExistence(timeout: 10),
            "an unavailable Apple engine must offer an actionable Settings route")
        openSettings.click()

        XCTAssertTrue(
            app.control(withIdentifier: "settings-summary-engine-picker")
                .waitForExistence(timeout: 10),
            "the recovery action must land directly in Intelligence Settings")
        XCTAssertTrue(
            app.control(withIdentifier: "settings-summary-apple-unavailable").exists,
            "the selected Apple engine must explain that it cannot run on Sequoia")
        if Locale.current.identifier.hasPrefix("es") {
            let localizedRecommendations = [
                "Apple Intelligence: resúmenes en el dispositivo, gratis y rápidos.",
                "Ollama local: resúmenes 100 % en tu Mac, sin Apple Intelligence.",
                "Modelo local integrado: resúmenes sin instalar nada.",
                "No hay ningún motor local de resúmenes."
            ]
            XCTAssertTrue(
                localizedRecommendations.contains { app.staticTexts[$0].exists },
                "the recommendation must cross the app localization boundary")
        }
        attachScreenshot(of: app, named: "sequoia-summary-actionable-settings")

        app.control(withIdentifier: "settings-category-voice").click()
        XCTAssertTrue(
            app.control(withIdentifier: "settings-companion-status")
                .waitForExistence(timeout: 5),
            "the voice pane must explain Companion's real platform requirement")
        XCTAssertFalse(
            app.control(withIdentifier: "settings-companion-enabled").exists,
            "Sequoia must not expose a toggle that cannot work")
        attachScreenshot(of: app, named: "sequoia-companion-requirements")
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

        // A real mutation crosses MeetingDetailModel's client and the scoped
        // summary observation returns the completed count to the same view.
        let todosTab = app.control(withIdentifier: "summary-tab-todos")
        todosTab.click()
        let actionItem = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'action-item-'"))
            .firstMatch
        XCTAssertTrue(
            actionItem.waitForExistence(timeout: 5),
            "the seeded action item must expose its stable control boundary")
        actionItem.click()
        let completed = expectation(
            for: NSPredicate(format: "label CONTAINS '1/1'"),
            evaluatedWith: todosTab)
        wait(for: [completed], timeout: 5)
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
        XCTAssertTrue(
            app.control(withIdentifier: "detail-privacy-receipt").waitForExistence(timeout: 10),
            "the right rail must show the local privacy receipt")
        XCTAssertTrue(
            app.control(withIdentifier: "privacy-remote-event-0").exists,
            "the fixture's content-free remote summary attempt must be auditable")
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

        attachScreenshot(of: app, named: "band-3h-privacy-receipt")
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
