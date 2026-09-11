import XCTest

/// Today: the default destination for someone who lives in calls. The agenda,
/// open work, recent meetings, and one-click questions must all be reachable
/// from one screen without scrolling or typing.
final class HomeUITests: PortavozUITestCase {
    @MainActor
    func testTodayShowsAgendaOpenWorkAndRecentMeetingsAboveTheFold() {
        let app = XCUIApplication.portavoz(seedDemo: true, seedBrief: true)
        app.launchPortavoz()
        defer { app.terminate() }

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
        for element in [upcoming, todo, recent, app.buttons["home-ask-chip-0"], app.control(withIdentifier: "home-stat-open")] {
            XCTAssertTrue(element.exists, "\(element) must render")
            XCTAssertTrue(window.contains(element.frame), "\(element) must sit above the fold")
        }
        XCTAssertTrue(app.staticTexts["Presupuesto rollout"].exists)
        XCTAssertTrue(app.staticTexts["Prepare the rollout"].exists)
        attachScreenshot(of: app, named: "home-today")

        // Checking a to-do here is the same durable action as in the sidebar:
        // the open row leaves Today once the Library observation confirms it.
        let toggle = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'home-todo-toggle-'"))
            .firstMatch
        XCTAssertTrue(toggle.waitForStableFrame(timeout: 5))
        toggle.click()
        XCTAssertTrue(
            waitForUITestCondition(timeout: 10) { !app.staticTexts["Prepare the rollout"].exists },
            "a completed to-do must leave the open list")

        // A recent meeting opens its detail; Today remains one click away.
        XCTAssertTrue(recent.waitForStableFrame(timeout: 5))
        recent.click()
        XCTAssertTrue(app.staticTexts["Test meeting"].waitForExistenceFast(timeout: 10))
        XCTAssertTrue(app.control(withIdentifier: "player-clear-playback").waitForExistenceFast(timeout: 10))
        let home = app.buttons["library-home-button"]
        XCTAssertTrue(home.waitForStableFrame(timeout: 5))
        home.click()
        XCTAssertTrue(title.waitForExistenceFast(timeout: 10))
    }

    @MainActor
    func testTodayAsksAndRecordsWithoutTyping() {
        let app = XCUIApplication.portavoz(
            seedDemo: true,
            seedBrief: true,
            simulateLiveTranscriptBrowsing: true)
        app.launchPortavoz()
        defer { app.terminate() }

        XCTAssertTrue(app.waitForSeededLibraryToSettle())
        XCTAssertTrue(app.staticTexts["home-title"].waitForExistenceFast(timeout: 10))

        // A suggested question reaches Ask already submitted.
        let chip = app.buttons["home-ask-chip-0"]
        XCTAssertTrue(chip.waitForStableFrame(timeout: 5))
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

        // Back on Today, the agenda offers a brief and a linked recording.
        let home = app.buttons["library-home-button"]
        XCTAssertTrue(home.waitForStableFrame(timeout: 5))
        home.click()
        let brief = app.buttons["home-upcoming-brief-ui-test-upcoming-rollout"]
        XCTAssertTrue(brief.waitForStableFrame(timeout: 10))
        brief.click()
        XCTAssertTrue(app.control(withIdentifier: "brief-title").waitForExistenceFast(timeout: 10))
        XCTAssertTrue(app.staticTexts["Presupuesto rollout"].exists)
        let close = app.buttons["brief-close-button"]
        XCTAssertTrue(close.waitForStableFrame(timeout: 5))
        close.click()

        let record = app.buttons["home-upcoming-record-ui-test-upcoming-rollout"]
        XCTAssertTrue(record.waitForStableFrame(timeout: 10))
        record.click()
        // The event-linked recording starts like the brief's own Record action;
        // the real title is assigned when the meeting is saved at Stop.
        XCTAssertTrue(app.control(withIdentifier: "recording-live-transcript").waitForExistenceFast(timeout: 10))
        XCTAssertTrue(app.buttons["library-return-to-recording"].waitForExistenceFast(timeout: 5))
    }
}
