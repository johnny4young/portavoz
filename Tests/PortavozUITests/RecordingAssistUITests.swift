import XCTest

final class RecordingAssistUITests: PortavozUITestCase {
    @MainActor
    func testCompanionActionsKeepIdentityAndSeenStateAfterReentry() {
        let app = XCUIApplication.portavoz(
            seedDemo: true,
            simulateSequoiaCapabilities: true,
            simulateLiveTranscriptBrowsing: true)
        app.launchEnvironment["PORTAVOZ_UI_TEST_DEFAULTS"] = #"{"companionEnabled":true}"#
        app.launchArguments.append("-seed-live-companion-ui")
        app.launchPortavoz()
        defer { app.terminate() }
        XCTAssertTrue(app.waitForSeededLibraryToSettle())
        app.buttons["library-new-recording-button"].click()
        XCTAssertTrue(app.waitForLiveTranscriptFrontier())

        let retainedQuestion = "Seeded live question 5?"
        let retained = companionCard(in: app, question: retainedQuestion)
        XCTAssertTrue(retained.waitForExistenceFast(timeout: 5))
        let retainedIdentifier = retained.identifier
        XCTAssertTrue(retained.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH 'recording-companion-copy-'"))
            .firstMatch.exists)
        let newest = companionCard(in: app, question: "Seeded live question 6?")
        newest.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH 'recording-companion-dismiss-'"))
            .firstMatch.click()
        XCTAssertTrue(
            app.control(withIdentifier: retainedIdentifier).staticTexts[retainedQuestion]
                .waitForExistenceFast(timeout: 3),
            "removing another card must not retarget an existing accessibility identifier")

        let meeting = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'library-meeting-'"))
            .firstMatch
        XCTAssertTrue(app.prepareForInteraction())
        XCTAssertTrue(meeting.waitForStableFrame(timeout: 5))
        meeting.click()
        XCTAssertTrue(app.control(withIdentifier: "detail-transcript-title").waitForExistenceFast(timeout: 8))
        app.buttons["library-return-to-recording"].click()
        let companion = app.buttons["recording-assist-tab-companion"]
        XCTAssertTrue(companion.waitForExistenceFast(timeout: 8))
        XCTAssertNil(
            companion.label.rangeOfCharacter(from: .decimalDigits),
            "the already visible Companion tab must not show an unread count on reentry: \(companion.label)")
        XCTAssertTrue(companionCard(in: app, question: retainedQuestion).exists)
    }

    @MainActor
    private func companionCard(in app: XCUIApplication, question: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'recording-companion-card-'"))
            .containing(.staticText, identifier: question)
            .firstMatch
    }

    /// No closed captions are released: both requests must expose their honest
    /// unavailable state, without model assets, network or a generated answer.
    @MainActor
    func testLatestManualAssistRequestOwnsTheFocusSlot() {
        let app = XCUIApplication.portavoz(simulateLiveTranscriptionAttach: true)
        app.launchPortavoz()
        defer { app.terminate() }
        let record = app.buttons["library-new-recording-button"]
        XCTAssertTrue(record.waitForExistenceFast(timeout: 15))
        record.click()
        XCTAssertTrue(app.waitForLiveTranscriptionAttachPreparing())
        let catchUp = app.control(withIdentifier: "recording-catch-up-panel")
        let nextQuestion = app.control(withIdentifier: "recording-next-question-panel")
        app.buttons["recording-catch-up"].click()
        XCTAssertTrue(catchUp.waitForExistenceFast(timeout: 3))
        app.buttons["recording-next-question"].click()
        XCTAssertTrue(nextQuestion.waitForExistenceFast(timeout: 3))
        XCTAssertFalse(catchUp.exists, "the previous request cannot occupy the only render site")
        app.buttons["recording-catch-up"].click()
        XCTAssertTrue(catchUp.waitForExistenceFast(timeout: 3))
        XCTAssertFalse(nextQuestion.exists)
        app.buttons["recording-catch-up-dismiss"].click()
        XCTAssertFalse(catchUp.exists)
        XCTAssertFalse(nextQuestion.exists, "dismissal must not resurrect a superseded request")
    }

    @MainActor
    func testBatchedObjectivesRevealLastArrivalAndReplacementCountsAsUnread() {
        let app = XCUIApplication.portavoz(simulateLiveTranscriptBrowsing: true)
        app.launchArguments += ["-seed-live-companion-ui", "-seed-live-assist-arrivals-ui"]
        app.launchPortavoz()
        defer { app.terminate() }
        let record = app.buttons["library-new-recording-button"]
        XCTAssertTrue(record.waitForExistenceFast(timeout: 15))
        record.click()
        XCTAssertTrue(app.waitForLiveTranscriptFrontier())
        app.openAssistTab("objectives")
        XCTAssertTrue(app.resumeLiveTranscriptFixture())
        XCTAssertTrue(app.waitForLiveTranscriptFixtureToFinish())
        let objective = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH 'recording-objective-text-' AND label == %@",
            "Revisar la evidencia con el equipo y registrar los riesgos pendientes antes de aprobar la versión."))
            .firstMatch
        XCTAssertTrue(objective.waitForExistenceFast(timeout: 5))
        XCTAssertTrue(objective.revealVertically(
            in: app.control(withIdentifier: "recording-assist-panel"), maxScrolls: 0),
            "the last of two additions in one callback must appear without test-owned scrolling")
        let companion = app.buttons["recording-assist-tab-companion"]
        XCTAssertTrue(waitForUITestCondition(timeout: 3) {
            companion.label.hasSuffix("1")
        }, "a replacement is unread even when the number of cards stays unchanged")
        app.openAssistTab("companion")
        XCTAssertTrue(companionCard(in: app, question: "Seeded live question 6? Please.").exists)
        XCTAssertNil(companion.label.rangeOfCharacter(from: .decimalDigits))
    }

    @MainActor
    func testUnsubmittedNotesAndObjectivesSurviveTabsAndLibraryBrowsing() {
        let app = XCUIApplication.portavoz(
            seedDemo: true, simulateSequoiaCapabilities: true,
            simulateLiveTranscriptBrowsing: true)
        app.launchPortavoz()
        defer { app.terminate() }
        XCTAssertTrue(app.waitForSeededLibraryToSettle())
        app.buttons["library-new-recording-button"].click()
        XCTAssertTrue(app.waitForLiveTranscriptFrontier())
        let noteText = "Confirmar responsable del informe"
        let objectiveText = "Check deployment readiness"
        app.openAssistTab("notes")
        let note = app.control(withIdentifier: "recording-note-field")
        note.click()
        app.typeText(noteText)
        XCTAssertTrue(note.waitForLabelOrValue(noteText, timeout: 3))
        app.openAssistTab("objectives")
        let objective = app.control(withIdentifier: "recording-objective-field")
        objective.click()
        app.typeText(objectiveText)
        XCTAssertTrue(objective.waitForLabelOrValue(objectiveText, timeout: 3))
        app.openAssistTab("notes")
        XCTAssertTrue(note.waitForLabelOrValue(noteText, timeout: 3))
        app.openAssistTab("objectives")
        XCTAssertTrue(objective.waitForLabelOrValue(objectiveText, timeout: 3),
                      "changing tabs must not discard an unsubmitted objective")
        let meeting = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'library-meeting-'"))
            .firstMatch
        XCTAssertTrue(app.prepareForInteraction())
        XCTAssertTrue(meeting.waitForStableFrame(timeout: 5))
        meeting.click()
        XCTAssertTrue(app.control(withIdentifier: "detail-transcript-title").waitForExistenceFast(timeout: 8))
        app.buttons["library-return-to-recording"].click()
        app.openAssistTab("objectives")
        XCTAssertTrue(objective.waitForLabelOrValue(objectiveText, timeout: 3),
                      "library browsing must not discard the objective draft")
        app.openAssistTab("notes")
        let restored = note.waitForLabelOrValue(noteText, timeout: 3)
        XCTAssertTrue(restored, "library browsing must not discard the note draft")
        guard restored else { return }
        app.buttons["recording-note-add"].click()
        let saved = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'recording-note-'"))
            .containing(.staticText, identifier: noteText).firstMatch
        XCTAssertTrue(saved.waitForExistenceFast(timeout: 3))
        saved.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH 'recording-note-remove-'"))
            .firstMatch.click()
        XCTAssertTrue(saved.waitForDisappearance(timeout: 3),
                      "removal is acknowledged only after its asynchronous storage commit")
    }

    /// The live assist area stacked eight panels inside a 260 pt scroll with an
    /// unbounded card list: one real 18-minute meeting produced 23 cards and
    /// roughly seven screens of scrolling. This proves the replacement (D504):
    /// one open panel at a time, the newest cards open, older ones folded to a
    /// single line, and the question addressed to the user in its own slot.
    @MainActor
    func testLiveAssistKeepsOnePanelOpenAndABoundedCardList() {
        let app = XCUIApplication.portavoz(
            seedDemo: true,
            simulateSequoiaCapabilities: true,
            simulateLiveTranscriptBrowsing: true)
        app.launchEnvironment["PORTAVOZ_UI_TEST_DEFAULTS"] =
            #"{"companionEnabled":true}"#
        app.launchArguments.append("-seed-live-companion-ui")
        app.launchPortavoz()
        defer { app.terminate() }

        let record = app.buttons["library-new-recording-button"]
        XCTAssertTrue(record.waitForExistenceFast(timeout: 15))
        record.click()
        XCTAssertTrue(
            app.waitForLiveTranscriptFrontier(),
            "the assist assertions require closed captions")

        let assist = app.control(withIdentifier: "recording-assist-panel")
        XCTAssertTrue(assist.waitForExistenceFast(timeout: 10))
        XCTAssertTrue(
            app.control(withIdentifier: "recording-assist-divider").exists,
            "the captions/assist split must be adjustable instead of pinned")

        XCTAssertTrue(
            app.control(withIdentifier: "recording-focus-card")
                .waitForExistenceFast(timeout: 10),
            "the one question addressed to the user must sit above the tabs")

        let newestID = String(companionCard(in: app, question: "Seeded live question 6?")
            .identifier.dropFirst("recording-companion-card-".count))
        let thirdID = String(companionCard(in: app, question: "Seeded live question 4?")
            .identifier.dropFirst("recording-companion-card-".count))
        let fourth = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH 'recording-companion-folded-' AND label CONTAINS %@",
            "Seeded live question 3?"))
            .firstMatch
        XCTAssertTrue(fourth.exists)
        let fourthID = String(fourth.identifier.dropFirst("recording-companion-folded-".count))

        // The newest three stay open; everything older folds to one line and
        // stays reachable.
        XCTAssertTrue(
            app.control(withIdentifier: "recording-companion-card-\(thirdID)")
                .waitForExistenceFast(timeout: 5))
        XCTAssertFalse(
            app.control(withIdentifier: "recording-companion-card-\(fourthID)").exists,
            "the recency window must fold everything past the newest few")
        let folded = app.control(withIdentifier: "recording-companion-folded-\(fourthID)")
        XCTAssertTrue(folded.exists, "older cards stay reachable as one-line rows")
        XCTAssertTrue(
            app.control(withIdentifier: "recording-companion-show-all-\(newestID)").exists,
            "a clamped answer must offer to open fully rather than run long")

        // Reaching back for an older card folds the oldest recency-open one,
        // so the panel keeps its size instead of growing.
        let list = app.scrollViews["recording-companion-list"]
        guard folded.revealVertically(in: list, maximumStep: list.frame.height) else {
            return XCTFail(
                "Older Companion card was not reachable: control=\(folded.frame), "
                    + "viewport=\(list.frame), enabled=\(folded.isEnabled)")
        }
        folded.click()
        XCTAssertTrue(
            app.control(withIdentifier: "recording-companion-card-\(fourthID)")
                .waitForExistenceFast(timeout: 3))
        XCTAssertFalse(
            app.control(withIdentifier: "recording-companion-card-\(thirdID)").exists,
            "opening an older card must close the oldest card open by recency")
        XCTAssertTrue(app.control(withIdentifier: "recording-companion-folded-\(thirdID)").exists)

        // The fold chevron is what writes .collapsed; without a journey the
        // recency window's own direction is unproven end to end.
        let fold = app.control(withIdentifier: "recording-companion-fold-\(newestID)")
        XCTAssertTrue(fold.exists)
        guard fold.revealVertically(in: list, maximumStep: list.frame.height) else {
            return XCTFail(
                "Newest Companion fold was not reachable: control=\(fold.frame), "
                    + "viewport=\(list.frame), enabled=\(fold.isEnabled)")
        }
        fold.click()
        XCTAssertTrue(
            app.control(withIdentifier: "recording-companion-folded-\(newestID)")
                .waitForExistenceFast(timeout: 3),
            "folding an open card must leave it reachable as a one-line row")


        // One panel at a time: the Companion list leaves when Notes opens.
        app.openAssistTab("notes")
        XCTAssertFalse(
            app.control(withIdentifier: "recording-companion-card-\(newestID)")
                .waitForExistenceFast(timeout: 2),
            "only the selected panel may occupy the assist area")
        XCTAssertTrue(
            app.control(withIdentifier: "recording-focus-card").exists,
            "the focus slot survives a tab switch — it is what cannot wait")

        // Back on Companion the card folded earlier is still folded: what the
        // user opened and closed is held by the panel, not by the list, so a
        // tab switch cannot reset it.
        app.openAssistTab("companion")
        XCTAssertTrue(
            app.control(withIdentifier: "recording-companion-folded-\(newestID)")
                .waitForExistenceFast(timeout: 5))

        // Last, because it empties the slot: the focus card is sticky until
        // dismissed, so dismissal is the only thing that frees it.
        let focusDismiss = app.control(withIdentifier: "recording-focus-dismiss")
        XCTAssertTrue(focusDismiss.exists)
        focusDismiss.click()
        XCTAssertFalse(
            app.control(withIdentifier: "recording-focus-card")
                .waitForExistenceFast(timeout: 3),
            "a dismissed focus card must free the slot")
    }

}
