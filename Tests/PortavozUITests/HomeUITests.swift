import XCTest

/// Today: the default destination for someone who lives in calls. The next
/// meeting, open work, recent meetings, and one-click questions must all be
/// reachable from one screen without scrolling or typing.
final class HomeUITests: PortavozUITestCase {
    @MainActor
    func testTodayShowsEverythingAboveTheFoldAndActsWithoutTyping() throws {
        let app = try XCUIApplication.portavoz(
            seedDemo: true,
            seedBrief: true,
            simulateLiveTranscriptBrowsing: true)
        app.launchPortavoz()
        defer { finishUITestApplication(app) }

        XCTAssertTrue(app.waitForSeededLibraryToSettle())
        let title = app.staticTexts["home-title"]
        XCTAssertTrue(title.waitForExistenceFast(timeout: 10))
        if let locale = UITestLocale.environmentLocale {
            XCTAssertEqual(renderedText(of: title), locale == "es" ? "Hoy" : "Today")
        }
        XCTAssertTrue(app.buttons["library-home-button"].isSelected)

        // Every Today surface is visible inside the window without scrolling.
        let window = app.windows.firstMatch.frame
        let upcoming = app.control(withIdentifier: "home-upcoming-ui-test-upcoming-rollout")
        XCTAssertTrue(upcoming.waitForExistenceFast(timeout: 10))
        let todo = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'home-todo-' AND NOT identifier BEGINSWITH 'home-todo-toggle-'"))
            .firstMatch
        XCTAssertTrue(todo.waitForExistenceFast(timeout: 10))
        let recent = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'home-recent-'"))
            .firstMatch
        XCTAssertTrue(recent.waitForExistenceFast(timeout: 10))
        let askField = app.control(withIdentifier: "home-ask-field")
        XCTAssertTrue(askField.waitForExistenceFast(timeout: 5), "Ask is one field on Today")
        let countdown = app.descendants(matching: .any)["home-upcoming-countdown"]
        XCTAssertTrue(countdown.waitForExistenceFast(timeout: 5), "the next meeting counts down")
        let record = app.buttons["home-upcoming-record-ui-test-upcoming-rollout"]
        for element in [upcoming, countdown, record, todo, recent, askField] {
            XCTAssertTrue(element.exists, "\(element) must render")
            XCTAssertTrue(window.contains(element.frame), "\(element) must sit above the fold")
        }
        // An empty brief holds the column beside the hero; it never stacks under it.
        let emptyBrief = app.descendants(matching: .any)["home-brief-empty"]
        if emptyBrief.exists {
            XCTAssertGreaterThan(emptyBrief.frame.minX, countdown.frame.maxX, "an empty brief must not cost the fold")
        }
        XCTAssertTrue(app.staticTexts["Presupuesto rollout"].exists)
        XCTAssertTrue(todo.label.contains("Prepare the rollout"), todo.label)
        attachScreenshot(of: app, named: "home-today")
        attachScreenshot(of: app, named: "pr-home-countdown-hero")

        // The field's glyph offers questions; one reaches Ask already submitted.
        let suggestions = app.descendants(matching: .any)["home-ask-suggestions"]
        XCTAssertTrue(suggestions.waitForStableFrame(timeout: 5))
        suggestions.click()
        let chip = app.menuItems["home-ask-chip-0"]
        XCTAssertTrue(chip.waitForExistenceFast(timeout: 5))
        attachScreenshot(of: app, named: "pr-home-ask-suggestions")
        chip.click()
        XCTAssertTrue(app.control(withIdentifier: "ask-question-field").waitForExistenceFast(timeout: 10))
        XCTAssertTrue(
            waitForUITestCondition(timeout: 15) {
                app.control(withIdentifier: "ask-pending-question").exists
                    || app.descendants(matching: .any)
                        .matching(NSPredicate(format: "identifier BEGINSWITH 'ask-answer-'"))
                        .firstMatch.exists
            },
            "the chip must submit its question, not only prefill it")
        XCTAssertTrue(app.buttons["library-ask-button"].isSelected)

        // Back on Today, the agenda offers a brief.
        let today = app.buttons["library-home-button"]
        XCTAssertTrue(today.waitForStableFrame(timeout: 5))
        today.click()
        let brief = app.buttons["home-upcoming-brief-ui-test-upcoming-rollout"]
        XCTAssertTrue(brief.waitForStableFrame(timeout: 10))
        brief.click()
        XCTAssertTrue(app.control(withIdentifier: "brief-title").waitForExistenceFast(timeout: 10))
        XCTAssertTrue(app.staticTexts["Presupuesto rollout"].exists)
        let close = app.buttons["brief-close-button"]
        XCTAssertTrue(close.waitForStableFrame(timeout: 5))
        close.click()

        // Checking a to-do is the same durable action as in Radar: the open
        // row leaves Today once the Library observation confirms it.
        let toggle = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'home-todo-toggle-'"))
            .firstMatch
        // Opening the brief records its source, so the card now has lines; in a
        // narrow window it stacks under the hero and open work scrolls into view.
        let scroll = app.scrollViews.containing(.staticText, identifier: "home-title").element
        XCTAssertTrue(toggle.revealVertically(in: scroll))
        XCTAssertTrue(toggle.waitForStableFrame(timeout: 5))
        toggle.click()
        XCTAssertTrue(
            waitForUITestCondition(timeout: 10) { !todo.exists },
            "a completed to-do must leave the open list")

        // A recent meeting opens its detail; Today remains one click away.
        XCTAssertTrue(recent.revealVertically(in: scroll))
        XCTAssertTrue(recent.waitForStableFrame(timeout: 5))
        recent.click()
        XCTAssertTrue(app.staticTexts["Test meeting"].waitForExistenceFast(timeout: 10))
        XCTAssertTrue(app.control(withIdentifier: "player-options").waitForExistenceFast(timeout: 10))
        let home = app.buttons["library-home-button"]
        XCTAssertTrue(home.waitForStableFrame(timeout: 5))
        home.click()
        XCTAssertTrue(title.waitForExistenceFast(timeout: 10))

        // The hero also offers a linked recording, which ends the journey.
        XCTAssertTrue(record.waitForStableFrame(timeout: 10))
        record.click()
        // The event-linked recording starts like the brief's own Record action;
        // the real title is assigned when the meeting is saved at Stop.
        XCTAssertTrue(app.control(withIdentifier: "recording-live-transcript").waitForExistenceFast(timeout: 10))
        XCTAssertTrue(app.buttons["library-return-to-recording"].waitForExistenceFast(timeout: 5))
    }

    @MainActor
    func testBriefCardShowsWhatEachPersonSaidLastTime() throws {
        let app = try XCUIApplication.portavoz(seedDemo: true, seedBrief: true)
        app.launchArguments += ["-seed-brief-previous", "-seed-wide-window", "-AppleInterfaceStyle", "Light"]
        app.launchPortavoz()
        defer { finishUITestApplication(app) }

        XCTAssertTrue(app.waitForSeededLibraryToSettle())
        let card = app.descendants(matching: .any)["home-brief"]
        XCTAssertTrue(card.waitForExistenceFast(timeout: 15), "the hero's previous occurrence fills the brief")
        let rows = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'home-brief-person-'"))
        XCTAssertTrue(
            waitForUITestCondition(timeout: 10) { rows.count == 2 }, "one row per person heard last time")
        let countdown = app.descendants(matching: .any)["home-upcoming-countdown"]
        XCTAssertTrue(countdown.waitForExistenceFast(timeout: 5))
        // A 1024 pt screen only has room for the wide layout without the sidebar.
        setSidebar(visible: false, in: app)
        XCTAssertTrue(card.waitForStableFrame(timeout: 5))
        XCTAssertGreaterThan(card.frame.minX, countdown.frame.maxX, "the brief sits beside the countdown")
        attachScreenshot(of: app, named: "pr-home-brief-card")

        // A row opens the previous meeting at the moment the line was said.
        let ana = rows.matching(NSPredicate(format: "label CONTAINS 'no confirmed owner'")).firstMatch
        XCTAssertTrue(ana.waitForStableFrame(timeout: 5))
        ana.click()
        XCTAssertTrue(
            app.staticTexts.matching(NSPredicate(format: "value CONTAINS 'no confirmed owner' OR label CONTAINS 'no confirmed owner'"))
                .firstMatch.waitForExistenceFast(timeout: 10),
            "the source meeting's transcript opens")
        XCTAssertFalse(card.exists)

        // Back on Today, the card opens the full brief.
        setSidebar(visible: true, in: app)
        let today = app.buttons["library-home-button"]
        XCTAssertTrue(today.waitForStableFrame(timeout: 5))
        today.click()
        let open = app.buttons["home-brief-open"]
        XCTAssertTrue(open.waitForStableFrame(timeout: 10))
        open.click()
        XCTAssertTrue(app.control(withIdentifier: "brief-title").waitForExistenceFast(timeout: 10))
        let close = app.buttons["brief-close-button"]
        XCTAssertTrue(close.waitForStableFrame(timeout: 5))
        close.click()
    }

    @MainActor
    func testWhoSpokeTodayLeadsTheDayAxisAndOpensItsMeetings() throws {
        let app = try XCUIApplication.portavoz(seedDemo: true, seedBrief: true)
        app.launchArguments += ["-seed-today-voices", "-seed-wide-window", "-AppleInterfaceStyle", "Light"]
        app.launchPortavoz()
        defer { finishUITestApplication(app) }

        XCTAssertTrue(app.waitForSeededLibraryToSettle())
        let section = app.descendants(matching: .any)["home-who-spoke"]
        XCTAssertTrue(section.waitForExistenceFast(timeout: 15), "today's meetings fill the section")
        let summary = app.staticTexts["home-who-spoke-summary"]
        XCTAssertTrue(summary.waitForExistenceFast(timeout: 5))
        XCTAssertTrue(
            waitForUITestCondition(timeout: 10) {
                let text = renderedText(of: summary)
                return text.hasPrefix("2 meetings recorded · ") && text.hasSuffix(" · 1 to go")
            },
            "recorded meetings, their length and what is still ahead")
        let you = app.descendants(matching: .any)["home-talker-me"]
        let marta = app.descendants(matching: .any)["home-talker-name-marta"]
        XCTAssertTrue(you.waitForExistenceFast(timeout: 5), "you lead the talkers")
        XCTAssertTrue(marta.exists)
        XCTAssertTrue(marta.label.contains("2 meetings"), marta.label)
        let unnamed = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'home-talker-speaker-'"))
        XCTAssertEqual(unnamed.count, 1, "a voice nobody named keeps its own column")
        XCTAssertTrue(unnamed.firstMatch.label.contains("not named yet"))
        XCTAssertLessThanOrEqual(you.frame.minX, marta.frame.minX)

        let axis = app.descendants(matching: .any)["home-day-axis"]
        let meetings = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'home-day-meeting-'"))
        let upcoming = app.descendants(matching: .any)["home-day-upcoming-ui-test-upcoming-rollout"]
        let now = app.descendants(matching: .any)["home-day-now"]
        XCTAssertTrue(axis.waitForExistenceFast(timeout: 5))
        XCTAssertEqual(meetings.count, 2, "each recorded meeting sits on the axis")
        XCTAssertTrue(upcoming.exists, "the next meeting waits on the axis")
        XCTAssertTrue(now.exists)
        XCTAssertGreaterThan(upcoming.frame.minX, now.frame.minX, "what is ahead sits after the now line")
        XCTAssertGreaterThan(axis.frame.minY, marta.frame.maxY, "talk time leads, the axis follows")

        // A 1024 pt screen only has room for the wide layout without the sidebar.
        setSidebar(visible: false, in: app)
        let scroll = app.scrollViews.containing(.staticText, identifier: "home-title").element
        XCTAssertTrue(axis.revealVertically(in: scroll))
        XCTAssertTrue(axis.waitForStableFrame(timeout: 5))
        attachScreenshot(of: app, named: "pr-home-who-spoke-today")

        // A meeting on the axis opens its detail.
        let demo = meetings.matching(NSPredicate(format: "label BEGINSWITH 'Sprint demo'")).firstMatch
        XCTAssertTrue(demo.waitForStableFrame(timeout: 5))
        demo.click()
        XCTAssertTrue(
            app.staticTexts.matching(NSPredicate(format: "value CONTAINS 'Turn 1 of Sprint demo' OR label CONTAINS 'Turn 1 of Sprint demo'"))
                .firstMatch.waitForExistenceFast(timeout: 10),
            "the axis opens that meeting")
        XCTAssertFalse(section.exists)
        setSidebar(visible: true, in: app)
    }

    @MainActor
    func testWorkRowsSayWhoSaidItAndWhereListeningStopped() throws {
        let app = try XCUIApplication.portavoz(seedDemo: true, seedBrief: true)
        app.launchArguments += ["-seed-pick-up", "-seed-wide-window", "-AppleInterfaceStyle", "Light"]
        app.launchPortavoz()
        defer { finishUITestApplication(app) }

        XCTAssertTrue(app.waitForSeededLibraryToSettle())
        let todo = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'home-todo-' AND NOT identifier BEGINSWITH 'home-todo-toggle-'"))
            .firstMatch
        XCTAssertTrue(todo.waitForExistenceFast(timeout: 10))
        XCTAssertTrue(
            waitForUITestCondition(timeout: 10) { todo.label.contains("Ana said it") },
            "the to-do names who said it: \(todo.label)")
        XCTAssertTrue(todo.label.contains("Test meeting · 00:03"), todo.label)
        let recent = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'home-recent-'"))
            .firstMatch
        XCTAssertTrue(recent.waitForExistenceFast(timeout: 10))
        XCTAssertTrue(
            waitForUITestCondition(timeout: 10) { recent.label.contains("stopped at 03:20") },
            "the row shows where listening stopped: \(recent.label)")
        XCTAssertTrue(recent.label.contains("1 open"), recent.label)
        XCTAssertFalse(
            app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier BEGINSWITH 'library-upcoming-'")).firstMatch.exists,
            "the sidebar lists past meetings only")

        // A 1024 pt screen only has room for the wide layout without the sidebar.
        setSidebar(visible: false, in: app)
        let scroll = app.scrollViews.containing(.staticText, identifier: "home-title").element
        XCTAssertTrue(recent.revealVertically(in: scroll))
        XCTAssertTrue(recent.waitForStableFrame(timeout: 5))
        attachScreenshot(of: app, named: "pr-home-pick-up-and-todos")
        setSidebar(visible: true, in: app)

        recent.click()
        XCTAssertTrue(app.control(withIdentifier: "player-current-time").waitForExistenceFast(timeout: 15))
    }

    @MainActor
    func testPendingAutomationsOpenTheirSettings() throws {
        let app = try XCUIApplication.portavoz(seedDemo: true, seedBrief: true)
        app.launchArguments += ["-seed-duplicate-skill-proposals", "-seed-wide-window", "-AppleInterfaceStyle", "Light"]
        app.launchPortavoz()
        defer { finishUITestApplication(app) }

        XCTAssertTrue(app.waitForSeededLibraryToSettle())
        // Returning to Today re-reads the count after the fixture has seeded.
        let ask = app.buttons["library-ask-button"]
        XCTAssertTrue(ask.waitForStableFrame(timeout: 5))
        ask.click()
        let today = app.buttons["library-home-button"]
        XCTAssertTrue(today.waitForStableFrame(timeout: 5))
        today.click()

        let pill = app.buttons["home-automations"]
        XCTAssertTrue(pill.waitForStableFrame(timeout: 10), "pending suggestions show in Today's header")
        let countdown = app.descendants(matching: .any)["home-upcoming-countdown"]
        XCTAssertTrue(countdown.waitForExistenceFast(timeout: 5))
        XCTAssertLessThan(
            countdown.frame.maxY, app.buttons["home-upcoming-record-ui-test-upcoming-rollout"].frame.minY,
            "the countdown leads the hero, the actions close it")
        // Without an earlier occurrence the brief card says so, beside the countdown.
        // A 1024 pt screen only has room for the wide layout without the sidebar.
        setSidebar(visible: false, in: app)
        let empty = app.descendants(matching: .any)["home-brief-empty"]
        XCTAssertTrue(empty.waitForExistenceFast(timeout: 10), "a first meeting has nothing said last time")
        XCTAssertTrue(empty.waitForStableFrame(timeout: 5))
        XCTAssertGreaterThan(empty.frame.minX, countdown.frame.maxX, "the brief sits beside the hero when wide")
        attachScreenshot(of: app, named: "pr-home-wide-header")
        pill.click()
        XCTAssertTrue(
            app.control(withIdentifier: "settings-skills-pause-all").waitForExistenceFast(timeout: 10),
            "the pill opens Settings on Automations")
    }

    /// The split view's own toggle carries only a localized label, so it is
    /// addressed as the window toolbar's leading button and checked by its effect.
    @MainActor
    private func setSidebar(visible: Bool, in app: XCUIApplication) {
        let today = app.buttons["library-home-button"]
        guard today.exists != visible else { return }
        let toggle = app.windows.firstMatch.toolbars.buttons.firstMatch
        XCTAssertTrue(toggle.waitForStableFrame(timeout: 5))
        toggle.click()
        XCTAssertTrue(
            waitForUITestCondition(timeout: 5) { today.exists == visible },
            "the sidebar must end \(visible ? "shown" : "hidden")")
    }
}
