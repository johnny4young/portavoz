import XCTest

/// A disposable launch translates through a tagging fixture; Apple's translator is never reached.
final class MeetingTranscriptTranslationUITests: PortavozUITestCase {
    @MainActor
    func testATranscriptIsTranslatedOnRequestAndTheOriginalStaysOneClickAway() throws {
        let app = try launchOnSeededMeeting()
        defer { finishUITestApplication(app) }
        requestTranslation(into: "en", in: app)
        let language = app.control(withIdentifier: "detail-transcript-language")
        XCTAssertTrue(language.waitForExistenceFast(timeout: 20), "A finished translation offers the reading choice")
        // Clearly Spanish lines are translated; a mixed line stays as spoken.
        let tagged = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "[en] ", "[en] "))
        let translated = { tagged.count > 0 }
        XCTAssertTrue(waitForUITestCondition(timeout: 10, translated), "The translated reading opens once it is ready")
        XCTAssertFalse(app.control(withIdentifier: "detail-transcript-translation-stale").exists)
        let original = language.radioButtons.count > 0
            ? language.radioButtons.element(boundBy: 0) : language.buttons.element(boundBy: 0)
        original.click()
        XCTAssertTrue(waitForUITestCondition(timeout: 5) { !translated() }, "Original shows the untouched transcript")
    }

    @MainActor
    func testAnExportCanUseTheCurrentTranslation() throws {
        let app = try launchOnSeededMeeting()
        defer { finishUITestApplication(app) }
        let menu = app.control(withIdentifier: "detail-export-menu")
        XCTAssertTrue(menu.waitForExistenceFast(timeout: 10))
        menu.click()
        XCTAssertTrue(app.menuItems["detail-export-srt"].waitForExistenceFast(timeout: 5))
        XCTAssertFalse(app.menuItems["detail-export-translation-original"].exists,
                       "Without a translation, the export offers no transcript language")
        typeKey(.escape, modifierFlags: [], in: app)

        requestTranslation(into: "en", in: app)
        XCTAssertTrue(app.control(withIdentifier: "detail-transcript-language").waitForExistenceFast(timeout: 20))
        menu.click()
        let languages = app.menuItems["detail-export-translation"]
        XCTAssertTrue(languages.waitForExistenceFast(timeout: 5))
        languages.hover()
        XCTAssertTrue(app.menuItems["detail-export-translation-original"].waitForExistenceFast(timeout: 5))
        let english = app.menuItems["detail-export-translation-en"]
        // Submenu items exist before the submenu opens, and hover alone sometimes leaves it closed.
        if !english.waitForHittable(timeout: 2) { languages.click() }
        XCTAssertTrue(english.waitForHittable(timeout: 5))
        english.click()
        // The save panel is native UI; the use case tests own the exported bytes.
    }

    @MainActor
    func testMissingLanguagesPointToTheirDownload() throws {
        let app = try launchOnSeededMeeting("-seed-meeting-translation-missing")
        defer { finishUITestApplication(app) }
        requestTranslation(into: "en", in: app)
        XCTAssertTrue(
            app.control(withIdentifier: "detail-transcript-translation-settings").waitForExistenceFast(timeout: 20))
        XCTAssertFalse(app.control(withIdentifier: "detail-transcript-language").exists)
    }

    @MainActor
    private func requestTranslation(into language: String, in app: XCUIApplication) {
        XCTAssertTrue(app.openMeetingDetailReadingPane("transcript"))
        let menu = app.control(withIdentifier: "detail-transcript-translate")
        XCTAssertTrue(menu.waitForHittable(timeout: 10))
        menu.click()
        let item = app.menuItems["detail-transcript-translate-\(language)"]
        XCTAssertTrue(item.waitForExistenceFast(timeout: 5))
        item.click()
    }

    @MainActor
    private func launchOnSeededMeeting(_ arguments: String...) throws -> XCUIApplication {
        let app = try XCUIApplication.portavoz(seedDemo: true)
        app.launchArguments += arguments
        app.launchPortavoz()
        XCTAssertTrue(app.waitForSeededLibraryToSettle())
        let meeting = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'library-meeting-'"))
            .firstMatch
        XCTAssertTrue(app.prepareForInteraction())
        XCTAssertTrue(meeting.waitForStableFrame(timeout: 10))
        meeting.click()
        return app
    }
}
