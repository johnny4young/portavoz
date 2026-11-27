import XCTest

/// Decisions and commitments beside, or folded under, the transcript line that produced them.
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
    private func launchOnSeededMeeting(_ arguments: String...) throws -> XCUIApplication {
        let app = try XCUIApplication.portavoz(seedDemo: true, seedCommitmentInbox: true)
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
