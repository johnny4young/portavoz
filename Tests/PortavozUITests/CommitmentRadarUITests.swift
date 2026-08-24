import XCTest

final class CommitmentRadarUITests: PortavozUITestCase {
    @MainActor
    func testReminderAlertOpensCommitmentRadar() {
        let app = XCUIApplication.portavoz(
            seedDemo: true,
            seedCommitmentRadar: true)
        app.launchArguments.append("-simulate-reminder-open")
        app.launchPortavoz()
        defer { app.terminate() }

        XCTAssertTrue(app.waitForSeededLibraryToSettle())
        XCTAssertTrue(
            app.control(withIdentifier: "commitment-radar-title")
                .waitForExistenceFast(timeout: 10),
            "opening a commitment reminder must route to the private Radar")
        attachScreenshot(of: app, named: "commitment-reminder-open-radar")
    }

    @MainActor
    func testRadarFiltersConfirmedWorkAndOpensItsExactSourceMeeting() {
        let app = XCUIApplication.portavoz(
            seedDemo: true,
            seedCommitmentRadar: true)
        app.launchPortavoz()
        defer { app.terminate() }

        XCTAssertTrue(app.waitForSeededLibraryToSettle())
        let radar = app.buttons["library-commitment-radar-button"]
        XCTAssertTrue(radar.waitForExistenceFast(timeout: 10))
        radar.click()

        XCTAssertTrue(
            app.control(withIdentifier: "commitment-radar-title")
                .waitForExistenceFast(timeout: 10))
        let enableReminders = app.control(
            withIdentifier: "commitment-reminder-enable")
        XCTAssertTrue(
            enableReminders.waitForExistenceFast(timeout: 10),
            "launch inspection must not prompt before the explicit Radar action")
        enableReminders.click()
        XCTAssertTrue(
            app.control(withIdentifier: "commitment-reminder-enabled")
                .waitForExistenceFast(timeout: 10),
            "explicit permission should reconcile confirmed due work")
        XCTAssertFalse(enableReminders.exists)
        attachScreenshot(of: app, named: "commitment-radar-reminders-enabled")

        let mineID = "B5D10000-0000-4000-8000-000000000002"
        let otherID = "B5D10000-0000-4000-8000-000000000001"
        XCTAssertTrue(
            app.control(withIdentifier: "commitment-radar-item-\(mineID)")
                .waitForExistenceFast(timeout: 10))
        XCTAssertTrue(
            app.control(withIdentifier: "commitment-radar-item-\(otherID)").exists)

        let owner = app.control(withIdentifier: "commitment-radar-owner-filter")
        XCTAssertTrue(owner.waitForExistenceFast(timeout: 5))
        owner.click()
        let mine = app.menuItems["commitment-radar-owner-mine"]
        XCTAssertTrue(mine.waitForExistenceFast(timeout: 5))
        mine.click()

        XCTAssertTrue(
            app.control(withIdentifier: "commitment-radar-item-\(mineID)")
                .waitForExistenceFast(timeout: 10))
        XCTAssertFalse(
            app.control(withIdentifier: "commitment-radar-item-\(otherID)").exists,
            "the owner filter must not mix another person's confirmed work")
        attachScreenshot(of: app, named: "commitment-radar")

        let due = app.control(withIdentifier: "commitment-radar-due-\(mineID)")
        XCTAssertTrue(due.waitForExistenceFast(timeout: 5))
        due.click()
        XCTAssertTrue(
            app.control(withIdentifier: "commitment-radar-due-editor")
                .waitForExistenceFast(timeout: 5))
        attachScreenshot(of: app, named: "commitment-radar-due-date")
        app.control(withIdentifier: "commitment-radar-due-toggle").click()
        app.control(withIdentifier: "commitment-radar-due-save").click()
        XCTAssertTrue(
            app.control(
                withIdentifier: "commitment-radar-due-value-\(mineID)-none")
                .waitForExistenceFast(timeout: 10),
            "rescheduling must persist and reload the exact Radar item")
        attachScreenshot(of: app, named: "commitment-radar-rescheduled")

        let complete = app.control(
            withIdentifier: "commitment-radar-complete-\(mineID)")
        XCTAssertTrue(complete.waitForExistenceFast(timeout: 5))
        complete.click()
        XCTAssertTrue(
            app.control(withIdentifier: "commitment-radar-reopen-\(mineID)")
                .waitForExistenceFast(timeout: 10),
            "completion must persist and return as a durable Radar action")
        attachScreenshot(of: app, named: "commitment-radar-completed")

        let source = app.control(
            withIdentifier: "commitment-radar-source-B5D20000-0000-4000-8000-000000000002")
        XCTAssertTrue(source.waitForExistenceFast(timeout: 5))
        source.click()
        XCTAssertTrue(
            app.control(withIdentifier: "detail-header-section")
                .waitForExistenceFast(timeout: 10),
            "a Radar source must open its exact durable meeting")
        XCTAssertTrue(app.staticTexts["Test meeting"].exists)
    }

    @MainActor
    func testReminderDraftRequiresExplicitAccessAndLeavesDurableReceipt() {
        let app = XCUIApplication.portavoz(
            seedDemo: true,
            seedCommitmentRadar: true)
        app.launchPortavoz()
        defer { app.terminate() }

        XCTAssertTrue(app.waitForSeededLibraryToSettle())
        let radar = app.buttons["library-commitment-radar-button"]
        XCTAssertTrue(radar.waitForExistenceFast(timeout: 10))
        radar.click()

        let mineID = "B5D10000-0000-4000-8000-000000000002"
        let create = app.control(
            withIdentifier: "commitment-radar-reminder-create-\(mineID)")
        XCTAssertTrue(
            create.waitForExistenceFast(timeout: 10),
            "a confirmed commitment must expose its local reminder proposal")
        create.click()

        let sheet = app.control(withIdentifier: "reminder-draft-sheet")
        XCTAssertTrue(sheet.waitForExistenceFast(timeout: 5))
        XCTAssertTrue(
            app.control(withIdentifier: "reminder-draft-preview-title").exists)
        XCTAssertTrue(
            sheet.staticTexts["Recheck the launch checklist"]
                .waitForExistenceFast(timeout: 5),
            "the permission sheet must expose the exact commitment title")
        let allow = app.control(
            withIdentifier: "reminder-draft-allow-access")
        XCTAssertTrue(
            allow.waitForExistenceFast(timeout: 5),
            "opening a proposal must inspect permission without prompting")
        XCTAssertFalse(
            app.control(withIdentifier: "reminder-draft-confirm").exists,
            "no reminder may be created before the separate permission action")
        attachScreenshot(of: app, named: "reminder-draft-permission-moment")

        XCTAssertTrue(app.prepareForInteraction())
        allow.click()
        let target = app.control(withIdentifier: "reminder-draft-target-list")
        XCTAssertTrue(target.waitForExistenceFast(timeout: 10))
        XCTAssertTrue(
            sheet.staticTexts["Reminders"].waitForExistenceFast(timeout: 5),
            "the exact fake destination must be visible before confirmation")
        let refresh = app.control(withIdentifier: "reminder-draft-refresh-list")
        XCTAssertTrue(refresh.waitForExistenceFast(timeout: 5))
        XCTAssertTrue(app.prepareForInteraction())
        refresh.click()
        XCTAssertTrue(target.waitForExistenceFast(timeout: 10))
        XCTAssertTrue(sheet.staticTexts["Reminders"].exists)
        let confirm = app.control(withIdentifier: "reminder-draft-confirm")
        XCTAssertTrue(confirm.waitForExistenceFast(timeout: 5))
        XCTAssertTrue(app.prepareForInteraction())
        confirm.click()

        let created = app.control(
            withIdentifier: "commitment-radar-reminder-created-\(mineID)")
        XCTAssertTrue(
            created.waitForExistenceFast(timeout: 10),
            "the subject surface must rehydrate the durable succeeded receipt")
        XCTAssertFalse(create.exists)

        XCTAssertTrue(
            app.openSettingsWindow(),
            "the production Settings command must open its window")
        XCTAssertTrue(
            app.openSettingsCategory(
                "settings-category-skills",
                revealing: "settings-skill-receipt-reminder-draft"),
            "the global control center must project the same durable receipt")
        attachScreenshot(of: app, named: "reminder-draft-durable-receipt")
    }

    @MainActor
    func testReviewQueueKeepsSuggestionsSeparateAndOpensExactEvidence() {
        let app = XCUIApplication.portavoz(
            seedDemo: true,
            seedCommitmentRadar: true)
        app.launchPortavoz()
        defer { app.terminate() }

        XCTAssertTrue(app.waitForSeededLibraryToSettle())
        let radar = app.buttons["library-commitment-radar-button"]
        XCTAssertTrue(radar.waitForExistenceFast(timeout: 10))
        radar.click()

        let reviewMode = app.control(
            withIdentifier: "commitment-radar-mode-review")
        XCTAssertTrue(reviewMode.waitForExistenceFast(timeout: 10))
        reviewMode.click()

        let reviewID = "B5E00000-0000-4000-8000-000000000002"
        let reviewPage = app.control(withIdentifier: "commitment-review-page")
        XCTAssertTrue(
            reviewPage.waitForExistenceFast(timeout: 10),
            "generated work must appear in the separate review mode")
        XCTAssertFalse(
            app.control(withIdentifier: "commitment-radar-owner-filter").exists,
            "confirmed filters must not leak into generated review")
        let open = app.control(
            withIdentifier: "commitment-review-open-\(reviewID)")
        XCTAssertTrue(
            open.waitForExistenceFast(timeout: 5),
            "a suggestion must offer complete evidence review, not confirmation")
        attachScreenshot(of: app, named: "commitment-review-queue")

        open.click()

        XCTAssertTrue(
            app.control(withIdentifier: "detail-header-section")
                .waitForExistenceFast(timeout: 10),
            "review must reopen the complete source meeting")
        let citedSegment = app.control(
            withIdentifier: "transcript-segment-B5B00000-0000-4000-8000-000000000002")
        XCTAssertTrue(citedSegment.waitForExistenceFast(timeout: 10))
        XCTAssertTrue(
            citedSegment.waitForSelection(timeout: 10),
            "current evidence must focus the exact transcript source")
        let currentTime = app.control(withIdentifier: "player-current-time")
        XCTAssertTrue(
            currentTime.waitForValue("0:03", timeout: 10),
            "evidence review must seek to the persisted citation timestamp")
        attachScreenshot(of: app, named: "commitment-review-exact-source")
    }

    @MainActor
    func testFieldQualityObservesARealReviewWithoutAutomatingDecisions() {
        let app = XCUIApplication.portavoz(
            seedDemo: true,
            seedCommitmentRadar: true)
        app.launchPortavoz()
        defer { app.terminate() }

        XCTAssertTrue(app.waitForSeededLibraryToSettle())
        let radar = app.buttons["library-commitment-radar-button"]
        XCTAssertTrue(radar.waitForExistenceFast(timeout: 10))
        radar.click()

        let reviewMode = app.control(
            withIdentifier: "commitment-radar-mode-review")
        XCTAssertTrue(reviewMode.waitForExistenceFast(timeout: 10))
        reviewMode.click()

        let reviewID = "B5E00000-0000-4000-8000-000000000002"
        let dismiss = app.control(
            withIdentifier: "commitment-review-dismiss-\(reviewID)")
        XCTAssertTrue(
            dismiss.waitForExistenceFast(timeout: 10),
            "the card must be visibly presented before field evidence is recorded")
        dismiss.click()
        XCTAssertTrue(
            app.control(withIdentifier: "commitment-review-empty")
                .waitForExistenceFast(timeout: 10),
            "review remains the user's explicit decision")

        let qualityMode = app.control(
            withIdentifier: "commitment-radar-mode-quality")
        XCTAssertTrue(qualityMode.waitForExistenceFast(timeout: 5))
        qualityMode.click()

        XCTAssertTrue(
            app.control(withIdentifier: "commitment-quality-scorecard")
                .waitForExistenceFast(timeout: 10))
        let keptValue = app.control(withIdentifier: "commitment-quality-kept").value
            as? String
        XCTAssertTrue(
            keptValue?.contains("0%") == true,
            "the dismissed suggestion must not count as kept")
        let ownerValue = app.control(withIdentifier: "commitment-quality-owner").value
            as? String
        XCTAssertTrue(
            ownerValue?.contains("0%") == true,
            "the dismissed suggestion must not count as owner-accurate")
        let advisoryNotice = app.control(withIdentifier: "commitment-quality-advisory")
        XCTAssertTrue(advisoryNotice.exists, "field quality must stay visibly advisory")
        XCTAssertTrue(
            [
                "Advisory only — no threshold or automation uses these numbers.",
                "Solo orientativo: ningún umbral ni automatización usa estas cifras.",
            ].contains(advisoryNotice.label),
            "quality advisory must stay exact and visible in the active locale")
        attachScreenshot(of: app, named: "commitment-field-quality")
    }
}
