import XCTest

final class BackgroundWorkUITests: PortavozUITestCase {
    @MainActor
    func testBackgroundWorkCenterShowsAllOwnersAndRecoversExactFailures() throws {
        let app = try XCUIApplication.portavoz(seedBackgroundWork: true)
        app.launchPortavoz()
        defer { app.terminate() }

        let indicator = app.buttons["background-work-indicator"]
        XCTAssertTrue(
            indicator.waitForHittable(timeout: 15),
            "attention in a background owner must expose one compact app-level route")
        indicator.click()

        XCTAssertTrue(
            app.control(withIdentifier: "settings-category-data")
                .waitForExistenceFast(timeout: 10),
            "the compact indicator must expose the exact Settings category")
        XCTAssertTrue(
            app.staticTexts["background-work-overview"].waitForExistenceFast(timeout: 5),
            "the compact indicator must deep-link to the Background Work pane")

        let spanish = UITestLocale.environmentLocale == "es"
        let expectedDetails = [
            "background-work-detail-recovery": spanish
                ? "Reconciliadas: 2 · concesiones recuperadas: 1 · diferidas: 0 · atención: 0"
                : "Reconciled: 2 · leases recovered: 1 · deferred: 0 · attention: 0",
            "background-work-detail-semantic-index": spanish
                ? "Indexados: 12 · excluidos: 3 · omitidos: 0"
                : "Indexed: 12 · excluded: 3 · skipped: 0",
            "background-work-attempt-processing": spanish ? "Intento: 2" : "Attempt: 2",
            "background-work-failure-processing": spanish ? "Motivo: Procesamiento" : "Reason: Processing"
        ]
        let owners = try uiObservation(
            of: app,
            requiring: Set(["recovery", "processing", "spotlight", "semantic-index", "memory-graph"]
                .map { "background-work-row-\($0)" })
                .union(["background-work-retry-processing"]),
            types: Dictionary(uniqueKeysWithValues: expectedDetails.keys.map { ($0, .staticText) }),
            expectedText: expectedDetails,
            timeout: 5,
            message: "Every owner must publish exact counts, attempt, retry wake and closed failure category")
        for (identifier, expected) in expectedDetails {
            let detail = try uiSnapshotElement(identifier, type: .staticText, in: owners)
            XCTAssertTrue(detail.label == expected || detail.value as? String == expected)
        }
        let idle = UITestLocale.environmentLocale == "es" ? "Inactivo" : "Idle"
        let settingsWindow = app.windows.containing(
            .any,
            identifier: "background-work-overview"
        ).firstMatch
        let settingsForm = settingsWindow.scrollViews.element(boundBy: 1)
        // Scale the reveal to the actual form, not the shared conservative
        // 48-point transcript-row default. The helper still limits travel to
        // the missing distance and proves contained, stable hittability.
        let processingRetry = app.buttons["background-work-action-processing"]
        XCTAssertTrue(
            processingRetry.revealVertically(
                in: settingsForm,
                maximumStep: settingsForm.frame.height),
            "the processing recovery action must be reachable in the Your data pane")
        XCTAssertTrue(processingRetry.waitForHittable(timeout: 5))
        processingRetry.click()
        XCTAssertTrue(
            app.staticTexts["background-work-status-processing"]
                .waitForLabelOrValue(idle, timeout: 5),
            "processing retry must route only to its owner and publish the new safe state")

        let graphRetry = app.buttons["background-work-action-memory-graph"]
        XCTAssertTrue(
            graphRetry.revealVertically(
                in: settingsForm,
                maximumStep: settingsForm.frame.height),
            "the graph recovery action must be reachable in the bounded Settings form")
        graphRetry.click()
        XCTAssertTrue(
            app.staticTexts["background-work-status-memory-graph"]
                .waitForLabelOrValue(idle, timeout: 5),
            "graph retry must clear only the graph attention state")
        attachScreenshot(of: app, named: "background-work-center")
    }

    @MainActor
    func testRecordingDefersDerivedWorkAndStopResumesIt() throws {
        let app = try XCUIApplication.portavoz(
            enableBackgroundWorkFixture: true,
            simulateSystemCaptureStall: true)
        app.launchPortavoz()
        defer { app.terminate() }

        let record = app.buttons["library-new-recording-button"]
        XCTAssertTrue(record.waitForHittable(timeout: 15))
        record.click()

        let indicator = app.buttons["background-work-indicator"]
        XCTAssertTrue(
            indicator.waitForHittable(timeout: 10),
            "a protected recording must reveal derived work waiting behind it")
        indicator.click()

        let waiting = UITestLocale.environmentLocale == "es"
            ? "Esperando a que termine la captura"
            : "Waiting for capture to end"
        for owner in ["semantic-index", "memory-graph"] {
            XCTAssertTrue(
                app.staticTexts["background-work-status-\(owner)"]
                    .waitForLabelOrValue(waiting, timeout: 10),
                "\(owner) must not run through protected capture")
        }

        typeKey("w", modifierFlags: .command, in: app)
        XCTAssertTrue(app.prepareForInteraction())
        let stop = app.buttons["recording-stop-after-remote-outage"]
        XCTAssertTrue(stop.waitForHittable(timeout: 10))
        stop.click()

        XCTAssertTrue(
            indicator.waitForDisappearance(timeout: 15),
            "Stop must resume both bounded owners and remove the non-idle indicator")
    }
}
