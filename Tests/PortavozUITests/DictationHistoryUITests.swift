import XCTest

/// The history lives in the disposable store's database, so turning it on or
/// deleting rows never touches the user's library or preferences.
final class DictationHistoryUITests: PortavozUITestCase {
    private var spanish: Bool { UITestLocale.environmentLocale == "es" }

    @MainActor
    func testHistoryStartsOffAndTurnsOnFromTheDictationsPage() throws {
        let app = try XCUIApplication.portavoz()
        app.launchPortavoz()
        defer { finishUITestApplication(app) }

        openDictations(in: app)
        let status = app.staticTexts["dictation-history-status"]
        XCTAssertEqual(
            renderedText(of: status),
            spanish ? "El historial está apagado. Los dictados nuevos no se guardan."
                : "History is off. New dictations are not saved.")
        app.buttons["dictation-history-enable"].click()
        let enabled = spanish ? "Se guardan en este Mac durante 30 días." : "Kept on this Mac for 30 days."
        XCTAssertTrue(waitForUITestCondition(timeout: 5) { renderedText(of: status) == enabled })
        XCTAssertTrue(app.control(withIdentifier: "dictation-history-empty").waitForExistenceFast(timeout: 5))
        attachScreenshot(of: app, named: "dictation-history-empty")
    }

    @MainActor
    func testSavedDictationsCanBeDeletedOneByOneOrAll() throws {
        let app = try XCUIApplication.portavoz()
        app.launchArguments += ["-seed-dictation-history", "-seed-dictation-history-records"]
        app.launchPortavoz()
        defer { finishUITestApplication(app) }

        openDictations(in: app)
        let newest = app.control(withIdentifier: "dictation-history-text-0")
        XCTAssertTrue(waitForUITestCondition(timeout: 5) { renderedText(of: newest) == "No borres estas notas." })
        XCTAssertTrue(renderedText(of: app.control(withIdentifier: "dictation-history-details-0")).contains("Notes"))
        XCTAssertTrue(app.control(withIdentifier: "dictation-history-original-0").exists)
        XCTAssertTrue(app.buttons["dictation-history-copy-0"].exists)
        let older = renderedText(of: app.control(withIdentifier: "dictation-history-details-1"))
        XCTAssertTrue(older.contains(spanish ? "No entregado" : "Not delivered"), older)
        attachScreenshot(of: app, named: "dictation-history-list")

        app.buttons["dictation-history-delete-0"].click()
        XCTAssertTrue(waitForUITestCondition(timeout: 5) {
            renderedText(of: newest) == "Send the report on Friday."
        })
        app.buttons["dictation-history-delete-all"].click()
        let confirm = app.buttons["dictation-history-delete-all-confirm"]
        XCTAssertTrue(confirm.waitForExistenceFast(timeout: 5))
        confirm.click()
        XCTAssertTrue(app.control(withIdentifier: "dictation-history-empty").waitForExistenceFast(timeout: 5))
        XCTAssertFalse(app.buttons["dictation-history-delete-all"].exists)
    }

    @MainActor
    func testSearchAndFiltersNarrowTheHistory() throws {
        let app = try XCUIApplication.portavoz()
        app.launchArguments += ["-seed-dictation-history", "-seed-dictation-history-records"]
        app.launchPortavoz()
        defer { finishUITestApplication(app) }

        openDictations(in: app)
        let first = app.control(withIdentifier: "dictation-history-text-0")
        let second = app.control(withIdentifier: "dictation-history-text-1")
        XCTAssertTrue(second.waitForExistenceFast(timeout: 5))

        app.control(withIdentifier: "dictation-history-search").click()
        typeText("repor", in: app)
        XCTAssertTrue(waitForUITestCondition(timeout: 5) {
            renderedText(of: first) == "Send the report on Friday." && !second.exists
        })
        typeText("tzz", in: app)
        XCTAssertTrue(app.control(withIdentifier: "dictation-history-no-results").waitForExistenceFast(timeout: 5))
        app.buttons["dictation-history-search-clear"].click()
        XCTAssertTrue(second.waitForExistenceFast(timeout: 5))

        app.control(withIdentifier: "dictation-history-app-filter").click()
        let notes = app.menuItems["Notes"]
        XCTAssertTrue(notes.waitForExistenceFast(timeout: 5))
        notes.click()
        XCTAssertTrue(waitForUITestCondition(timeout: 5) {
            renderedText(of: first) == "No borres estas notas." && !second.exists
        })
        app.control(withIdentifier: "dictation-history-undelivered-filter").click()
        XCTAssertTrue(app.control(withIdentifier: "dictation-history-no-results").waitForExistenceFast(timeout: 5))
        attachScreenshot(of: app, named: "dictation-history-filters")
    }

    @MainActor
    func testADictationCanBeAddedToAMeetingsNotes() throws {
        let app = try XCUIApplication.portavoz(seedDemo: true)
        app.launchArguments += ["-seed-dictation-history", "-seed-dictation-history-records"]
        app.launchPortavoz()
        defer { finishUITestApplication(app) }

        openDictations(in: app)
        let text = app.control(withIdentifier: "dictation-history-text-0")
        XCTAssertTrue(waitForUITestCondition(timeout: 5) { renderedText(of: text) == "No borres estas notas." })
        app.buttons["dictation-history-add-meeting-0"].click()
        XCTAssertTrue(app.control(withIdentifier: "dictation-meeting-picker-title").waitForExistenceFast(timeout: 5))
        XCTAssertTrue(app.control(withIdentifier: "dictation-meeting-picker-note").exists)
        let option = app.buttons["dictation-meeting-option-0"]
        XCTAssertTrue(option.waitForExistenceFast(timeout: 5))
        attachScreenshot(of: app, named: "dictation-meeting-picker")
        option.click()

        let linked = app.control(withIdentifier: "dictation-history-linked-0")
        XCTAssertTrue(waitForUITestCondition(timeout: 5) { renderedText(of: linked).contains("Test meeting") })
        XCTAssertFalse(app.control(withIdentifier: "dictation-history-tidy-hint-0").exists)

        // Adding the note re-renders the library; select its row only once it settles.
        XCTAssertTrue(app.waitForSeededLibraryToSettle())
        XCTAssertTrue(app.prepareForInteraction())
        let meeting = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'library-meeting-'"))
            .firstMatch
        XCTAssertTrue(meeting.waitForStableFrame(timeout: 10))
        meeting.click()
        // A compact window splits the detail into panes; the notes live in Summary.
        XCTAssertTrue(app.openMeetingDetailReadingPane("summary"), "the meeting detail must open")
        let notes = app.control(withIdentifier: "detail-notes-section")
        XCTAssertTrue(notes.waitForExistenceFast(timeout: 10))
        attachScreenshot(of: app, named: "dictation-meeting-notes")
        XCTAssertTrue(
            notes.staticTexts["No borres estas notas."].waitForExistenceFast(timeout: 10),
            "the dictation is now one of the meeting's notes")
    }

    @MainActor
    func testADictationSavedToHistorySaysSoInsteadOfNothingWasSaved() throws {
        let app = try XCUIApplication.portavoz(showMenuBarContent: true)
        app.launchArguments += [
            "-seed-dictation", "-seed-dictation-delivery", "-seed-dictation-verified", "-seed-dictation-history"
        ]
        app.launchEnvironment["PORTAVOZ_UI_TEST_DEFAULTS"] = #"{"globalDictationEnabled":true}"#
        app.launchPortavoz()
        defer { finishUITestApplication(app) }

        let dictate = app.buttons["menu-bar-dictate"]
        XCTAssertTrue(dictate.waitForStableFrame(timeout: 5))
        dictate.click()
        XCTAssertTrue(app.staticTexts["dictation-panel-transcript"].waitForExistenceFast(timeout: 5))
        dictate.click()
        let detail = app.staticTexts["dictation-panel-delivery-detail"]
        let saved = spanish ? "Guardado en tu historial de dictado." : "Saved to your dictation history."
        XCTAssertTrue(waitForUITestCondition(timeout: 5) { renderedText(of: detail) == saved })
        XCTAssertTrue(app.dialogs["dictation-panel"].waitForDisappearance(timeout: 5))
    }

    @MainActor
    func testSettingsAskForHistoryConsentWithEverySwitchOff() throws {
        let app = try XCUIApplication.portavoz(openSettings: true)
        app.launchPortavoz()
        defer { finishUITestApplication(app) }

        XCTAssertTrue(app.openSettingsCategory("settings-category-audio", revealing: "settings-dictation-history"))
        let toggle = app.control(withIdentifier: "settings-dictation-history")
        XCTAssertFalse(Self.isOn(toggle))
        XCTAssertTrue(app.control(withIdentifier: "settings-dictation-history-note").exists)
        XCTAssertFalse(app.control(withIdentifier: "settings-dictation-history-retention").exists)
        toggle.click()
        XCTAssertTrue(app.control(withIdentifier: "settings-dictation-history-retention").waitForExistenceFast(timeout: 5))
        XCTAssertFalse(Self.isOn(app.control(withIdentifier: "settings-dictation-history-original")))
        XCTAssertFalse(
            Self.isOn(app.control(withIdentifier: "settings-dictation-history-agents")),
            "agents never read the history until the user shares it")
        XCTAssertTrue(app.control(withIdentifier: "settings-dictation-history-agents-note").exists)
        attachScreenshot(of: app, named: "settings-dictation-history")
    }

    @MainActor
    func testAskAboutDictationsCitesAndOpensTheDictation() throws {
        let app = try XCUIApplication.portavoz()
        app.launchArguments += ["-seed-dictation-history", "-seed-dictation-history-records"]
        app.launchPortavoz()
        defer { finishUITestApplication(app) }

        let ask = app.buttons["library-ask-button"]
        XCTAssertTrue(ask.waitForStableFrame(timeout: 15))
        ask.click()
        let source = app.descendants(matching: .any)["ask-source-dictations"]
        XCTAssertTrue(source.waitForExistenceFast(timeout: 5))
        source.click()
        XCTAssertTrue(
            app.descendants(matching: .any)["ask-source-status-dictations"].waitForExistenceFast(timeout: 5),
            "Dictations disclose that only the saved history is searched")
        let field = app.control(withIdentifier: "ask-question-field")
        let citations = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'ask-dictation-citation-'"))
        field.click()
        typeText("dame los dictados de hoy", in: app)
        XCTAssertTrue(field.waitForValue("dame los dictados de hoy", timeout: 5))
        app.buttons["ask-submit"].click()
        XCTAssertTrue(
            waitForUITestCondition(timeout: 10) { citations.count == 2 },
            "a question about today lists both of today's dictations")
        XCTAssertTrue(
            app.staticTexts[spanish ? "Tus dictados de hoy:" : "Your dictations from today:"].exists,
            "a listing names its period instead of a generic answer")

        field.click()
        typeText("report", in: app)
        XCTAssertTrue(field.waitForValue("report", timeout: 5))
        app.buttons["ask-submit"].click()
        XCTAssertTrue(waitForUITestCondition(timeout: 10) { citations.count == 3 })
        XCTAssertTrue(app.staticTexts["You said you would send the report on Friday."].exists)
        XCTAssertTrue(app.descendants(matching: .any)["ask-exchange-source-dictations"].exists)
        let citation = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH 'ask-dictation-citation-' AND label CONTAINS 'Slack'")).firstMatch
        XCTAssertTrue(citation.waitForExistenceFast(timeout: 5))
        attachScreenshot(of: app, named: "ask-dictations-answer")
        citation.click()

        XCTAssertTrue(app.control(withIdentifier: "dictation-history-focus").waitForExistenceFast(timeout: 5))
        let first = app.control(withIdentifier: "dictation-history-text-0")
        XCTAssertTrue(waitForUITestCondition(timeout: 5) { renderedText(of: first) == "Send the report on Friday." })
        XCTAssertFalse(app.control(withIdentifier: "dictation-history-text-1").exists)
        app.buttons["dictation-history-focus-clear"].click()
        XCTAssertTrue(app.control(withIdentifier: "dictation-history-text-1").waitForExistenceFast(timeout: 5))
    }

    @MainActor
    func testStatisticsSummarizeTheWeekWithoutTheHistory() throws {
        let app = try XCUIApplication.portavoz()
        app.launchArguments += ["-seed-dictation-stats"]
        app.launchPortavoz()
        defer { finishUITestApplication(app) }

        openDictations(in: app)
        XCTAssertTrue(app.control(withIdentifier: "dictation-stats").waitForExistenceFast(timeout: 5))
        let dictations = app.control(withIdentifier: "dictation-stats-dictations")
        XCTAssertTrue(waitForUITestCondition(timeout: 5) { renderedText(of: dictations).contains("4") })
        XCTAssertTrue(renderedText(of: app.control(withIdentifier: "dictation-stats-app-0")).contains("Slack"))
        XCTAssertTrue(app.control(withIdentifier: "dictation-stats-not-delivered").exists)
        XCTAssertTrue(app.control(withIdentifier: "dictation-history-enable").exists, "the history itself stays off")
        attachScreenshot(of: app, named: "dictation-stats")

        app.radioButtons[spanish ? "30 días" : "30 days"].click()
        XCTAssertTrue(waitForUITestCondition(timeout: 5) { renderedText(of: dictations).contains("4") })
    }

    @MainActor
    func testStatisticsStartOffAndTurnOnFromSettings() throws {
        let app = try XCUIApplication.portavoz(openSettings: true)
        app.launchPortavoz()
        defer { finishUITestApplication(app) }

        XCTAssertTrue(app.openSettingsCategory("settings-category-audio", revealing: "settings-dictation-stats"))
        let toggle = app.control(withIdentifier: "settings-dictation-stats")
        XCTAssertFalse(Self.isOn(toggle))
        XCTAssertTrue(app.control(withIdentifier: "settings-dictation-stats-note").exists)
        toggle.click()
        XCTAssertTrue(waitForUITestCondition(timeout: 5) { Self.isOn(toggle) })
        XCTAssertTrue(app.buttons["settings-dictation-stats-delete"].exists)
    }

    @MainActor
    private func openDictations(in app: XCUIApplication) {
        let button = app.buttons["library-dictations-button"]
        XCTAssertTrue(button.waitForStableFrame(timeout: 15))
        button.click()
        XCTAssertTrue(app.control(withIdentifier: "dictation-history-title").waitForExistenceFast(timeout: 5))
    }

    /// A macOS switch reports its state as "1"/1 through Accessibility.
    @MainActor
    private static func isOn(_ toggle: XCUIElement) -> Bool {
        (toggle.value as? Int) == 1 || (toggle.value as? String) == "1"
    }
}
