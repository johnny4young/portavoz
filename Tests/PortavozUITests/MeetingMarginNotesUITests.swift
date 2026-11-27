import XCTest

/// Decisions, commitments, notes and voice matches beside, or folded under, the transcript line
/// they belong to, and the margin's Marginalia, Apuntador and People tabs.
final class MeetingMarginNotesUITests: PortavozUITestCase {
    @MainActor
    func testMarginNotesSitBesideTheLineThatProducedThem() throws {
        let app = try launchOnSeededMeeting("-seed-wide-window", "-AppleInterfaceStyle", "Light")
        defer { finishUITestApplication(app) }

        app.setSidebar(visible: false)
        XCTAssertTrue(app.revealMeetingDetailSection(.transcript))
        let line = app.transcriptLine("El rollout del modelo queda para el viernes.")
        XCTAssertTrue(line.waitForExistenceFast(timeout: 10))
        XCTAssertTrue(app.control(withIdentifier: "detail-transcript-section").waitForStableFrame(timeout: 5))
        attachScreenshot(of: app, named: "pr-margin-notes-wide")

        let itemID = "B5E00000-0000-4000-8000-000000000001"
        let commitment = app.control(withIdentifier: "margin-commitment-\(itemID)")
        let decision = app.control(withIdentifier: "margin-decision-B5D40000-0000-4000-8000-000000000001")
        XCTAssertTrue(decision.waitForExistenceFast(timeout: 5), "a decision sits beside the line it came from")
        XCTAssertTrue(commitment.exists, "a commitment sits beside the line it came from")
        for card in [decision, commitment] {
            XCTAssertGreaterThan(card.frame.minX, line.frame.maxX, "the card sits in the margin, not over the line")
        }
        XCTAssertEqual(decision.frame.minY, line.frame.minY, accuracy: 20, "the first card starts level with its line")
        XCTAssertGreaterThan(commitment.frame.minY, decision.frame.maxY, "cards on one line stack, never overlap")
        XCTAssertFalse(
            app.control(withIdentifier: "detail-commitment-inbox").exists,
            "an anchored commitment is not repeated above the transcript")
        XCTAssertTrue(
            renderedText(of: app.control(withIdentifier: "margin-commitment-\(itemID)-attribution"))
                .contains("Ana"),
            "the card says who said it")

        let more = app.control(withIdentifier: "margin-commitment-\(itemID)-more")
        XCTAssertTrue(more.waitForHittable(timeout: 5))
        more.click()
        let later = app.menuItems["Review later"]
        XCTAssertTrue(later.waitForExistenceFast(timeout: 5))
        later.click()
        // macOS may expose a SwiftUI submenu's items by title rather than identifier.
        for (item, title) in [("defer-tomorrow", "Tomorrow"), ("defer-week", "Next week")] {
            XCTAssertTrue(
                waitForUITestCondition(timeout: 5) {
                    app.menuItems["margin-commitment-\(itemID)-\(item)"].exists || app.menuItems[title].exists
                },
                "review later offers \(item)")
        }
        typeKey(.escape, modifierFlags: [], in: app)
        typeKey(.escape, modifierFlags: [], in: app)

        let confirmDecision = app.control(withIdentifier: "margin-decision-B5D40000-0000-4000-8000-000000000001-confirm")
        XCTAssertTrue(confirmDecision.waitForHittable(timeout: 5))
        confirmDecision.click()
        let decisionSheet = app.control(withIdentifier: "decision-confirm-sheet")
        XCTAssertTrue(decisionSheet.waitForExistenceFast(timeout: 5), "a decision card confirms through the same sheet")
        decisionSheet.buttons["Cancel"].click()
        XCTAssertTrue(decisionSheet.waitForDisappearance(timeout: 5))

        let confirm = app.control(withIdentifier: "margin-commitment-\(itemID)-confirm")
        XCTAssertTrue(confirm.waitForHittable(timeout: 5))
        confirm.click()
        let editor = app.control(withIdentifier: "commitment-editor")
        XCTAssertTrue(editor.waitForExistenceFast(timeout: 5), "confirming from the margin opens the same review sheet")
        app.control(withIdentifier: "commitment-editor-cancel").click()
        XCTAssertTrue(editor.waitForDisappearance(timeout: 5))

        let done = app.control(withIdentifier: "margin-commitment-\(itemID)-done")
        XCTAssertTrue(done.waitForHittable(timeout: 5))
        done.click()
        XCTAssertTrue(
            waitForUITestCondition(timeout: 5) { (done.value as? Int) == 1 || (done.value as? String) == "1" },
            "the card's checkbox completes the to-do")
        attachScreenshot(of: app, named: "pr-margin-notes-done")
    }

    @MainActor
    func testNarrowMarginNotesFoldUnderTheirLine() throws {
        let app = try launchOnSeededMeeting("-seed-narrow-window", "-AppleInterfaceStyle", "Light")
        defer { finishUITestApplication(app) }

        XCTAssertTrue(app.revealMeetingDetailSection(.transcript))
        let line = app.transcriptLine("El rollout del modelo queda para el viernes.")
        XCTAssertTrue(line.waitForExistenceFast(timeout: 10))
        XCTAssertTrue(app.control(withIdentifier: "detail-transcript-section").waitForStableFrame(timeout: 5))
        attachScreenshot(of: app, named: "pr-margin-notes-narrow")

        let commitment = app.control(withIdentifier: "margin-commitment-B5E00000-0000-4000-8000-000000000001")
        XCTAssertTrue(commitment.waitForExistenceFast(timeout: 5))
        XCTAssertGreaterThanOrEqual(commitment.frame.minY, line.frame.maxY - 1, "a narrow page folds the card under its line")
        XCTAssertEqual(commitment.frame.minX, line.frame.minX, accuracy: 2, "the folded card shares the line's edge")
        XCTAssertLessThanOrEqual(
            commitment.frame.maxX, app.control(withIdentifier: "detail-transcript-section").frame.maxX,
            "the folded card stays in the column")
    }

    @MainActor
    func testMarginTabsHoldMarginaliaApuntadorAndPeople() throws {
        let app = try launchOnSeededMeeting("-seed-wide-window", "-AppleInterfaceStyle", "Light")
        defer { finishUITestApplication(app) }

        app.setSidebar(visible: false)
        let rail = app.control(withIdentifier: "detail-secondary-rail")
        XCTAssertTrue(rail.waitForExistenceFast(timeout: 10))
        XCTAssertTrue(rail.waitForStableFrame(timeout: 5))
        attachScreenshot(of: app, named: "pr-margin-tabs-wide")

        let marginalia = rail.buttons["detail-rail-tab-marginalia"]
        XCTAssertTrue(marginalia.exists)
        XCTAssertTrue(marginalia.isSelected, "Marginalia is the margin's first lens")
        XCTAssertTrue(rail.descendants(matching: .any)["chapter-200"].exists, "chapters still jump from the margin")
        let notes = rail.descendants(matching: .any)["detail-notes-section"]
        XCTAssertTrue(notes.exists, "My notes and Tidy up live in the margin")
        XCTAssertTrue(notes.descendants(matching: .any)["detail-enhance-notes"].exists)
        XCTAssertFalse(notes.staticTexts["revisar budget Q3"].exists, "an anchored note shows in one place")

        let noteCard = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'margin-note-'")).firstMatch
        XCTAssertTrue(noteCard.waitForExistenceFast(timeout: 5), "your note becomes a card anchored to its time")
        XCTAssertTrue(noteCard.staticTexts["revisar budget Q3"].exists)
        XCTAssertEqual(noteCard.frame.minX, rail.frame.minX, accuracy: 4, "the note card sits in the margin column")

        rail.buttons["detail-rail-tab-apuntador"].click()
        XCTAssertTrue(
            rail.descendants(matching: .any)["apuntador-card-6"].waitForExistenceFast(timeout: 5),
            "Apuntador answers keep their lens")
        rail.buttons["detail-rail-tab-people"].click()
        XCTAssertTrue(
            rail.descendants(matching: .any)["detail-rail-empty-people"].waitForExistenceFast(timeout: 5),
            "with every voice named, People has nothing to confirm")

        XCTAssertTrue(app.revealMeetingDetailSection(.transcript))
        XCTAssertTrue(noteCard.revealVertically(
            in: app.control(withIdentifier: "detail-page-scroll"), maxScrolls: 12, maximumStep: 600))
        attachScreenshot(of: app, named: "pr-margin-tabs-note")
    }

    @MainActor
    func testNarrowMarginTabsSitBetweenMaterialAndTranscript() throws {
        // Without the commitment seed, whose canonical person keeps Ana from a voice match.
        let app = try launchOnSeededMeeting(
            "-seed-narrow-window", "-seed-voice-match", "-AppleInterfaceStyle", "Light", commitments: false)
        defer { finishUITestApplication(app) }

        let rail = app.control(withIdentifier: "detail-secondary-rail")
        XCTAssertTrue(rail.waitForExistenceFast(timeout: 10))
        XCTAssertTrue(rail.waitForStableFrame(timeout: 5))
        attachScreenshot(of: app, named: "pr-margin-tabs-narrow")

        let transcript = app.control(withIdentifier: "detail-transcript-section")
        XCTAssertTrue(transcript.waitForExistenceFast(timeout: 5))
        XCTAssertLessThanOrEqual(rail.frame.maxY, transcript.frame.minY + 1, "one column: the margin precedes the transcript")
        for tab in ["marginalia", "apuntador", "people"] {
            let button = rail.buttons["detail-rail-tab-\(tab)"]
            XCTAssertTrue(button.exists)
            XCTAssertLessThanOrEqual(button.frame.maxX, rail.frame.maxX + 1, "\(tab) is never cut off")
        }

        XCTAssertTrue(app.revealMeetingDetailSection(.transcript))
        let voice = app.control(withIdentifier: "detail-voice-auto-S1")
        XCTAssertTrue(voice.waitForExistenceFast(timeout: 20), "a voice match becomes a card at that voice's first line")
        XCTAssertTrue(voice.revealVertically(
            in: app.control(withIdentifier: "detail-page-scroll"), maxScrolls: 12, maximumStep: 600))
        let line = app.transcriptLine("El rollout del modelo queda para el viernes.")
        XCTAssertGreaterThanOrEqual(voice.frame.minY, line.frame.maxY - 1, "a narrow page folds the card under its line")
        attachScreenshot(of: app, named: "pr-margin-tabs-voice")
        XCTAssertTrue(app.control(withIdentifier: "detail-voice-auto-keep-S1").exists)
        let undo = app.control(withIdentifier: "detail-voice-auto-undo-S1")
        XCTAssertTrue(undo.waitForHittable(timeout: 5))
        undo.click()
        XCTAssertTrue(voice.waitForDisappearance(timeout: 10), "Undo clears the card")
    }

    @MainActor
    private func launchOnSeededMeeting(_ arguments: String..., commitments: Bool = true) throws -> XCUIApplication {
        let app = try XCUIApplication.portavoz(seedDemo: true, seedCommitmentInbox: commitments)
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
