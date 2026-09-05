import XCTest

final class BackgroundWorkUITests: PortavozUITestCase {
    @MainActor
    func testBackgroundWorkCenterShowsAllOwnersAndRecoversExactFailures() {
        let app = XCUIApplication.portavoz(seedBackgroundWork: true)
        app.launchPortavoz()
        defer { app.terminate() }

        let indicator = app.buttons["background-work-indicator"]
        XCTAssertTrue(
            indicator.waitForHittable(timeout: 15),
            "attention in a background owner must expose one compact app-level route")
        indicator.click()

        XCTAssertTrue(
            app.control(withIdentifier: "settings-category-background-work")
                .waitForExistenceFast(timeout: 10),
            "the compact indicator must expose the exact Settings category")
        XCTAssertTrue(
            app.staticTexts["background-work-overview"].waitForExistenceFast(timeout: 5),
            "the compact indicator must deep-link to the Background Work pane")

        for owner in [
            "recovery", "processing", "spotlight", "semantic-index", "memory-graph",
        ] {
            XCTAssertTrue(
                app.control(withIdentifier: "background-work-row-\(owner)")
                    .waitForExistenceFast(timeout: 5),
                "missing owner row: \(owner)")
        }

        let recoveryDetail = UITestLocale.environmentLocale == "es"
            ? "Reconciliadas: 2 · concesiones recuperadas: 1 · diferidas: 0 · atención: 0"
            : "Reconciled: 2 · leases recovered: 1 · deferred: 0 · attention: 0"
        XCTAssertTrue(
            app.staticTexts["background-work-detail-recovery"]
                .waitForLabelOrValue(recoveryDetail, timeout: 5),
            "recovery must publish exact content-free aggregate counts")

        let semanticDetail = UITestLocale.environmentLocale == "es"
            ? "Indexados: 12 · excluidos: 3 · omitidos: 0"
            : "Indexed: 12 · excluded: 3 · skipped: 0"
        XCTAssertTrue(
            app.staticTexts["background-work-detail-semantic-index"]
                .waitForLabelOrValue(semanticDetail, timeout: 5),
            "semantic indexing must publish exact content-free aggregate counts")

        let processingAttempt = UITestLocale.environmentLocale == "es"
            ? "Intento: 2"
            : "Attempt: 2"
        XCTAssertTrue(
            app.staticTexts["background-work-attempt-processing"]
                .waitForLabelOrValue(processingAttempt, timeout: 5))
        XCTAssertTrue(
            app.staticTexts["background-work-retry-processing"]
                .waitForExistenceFast(timeout: 5),
            "retrying owners must disclose their exact scheduled wake")
        let processingFailure = UITestLocale.environmentLocale == "es"
            ? "Motivo: Evidencia de procesamiento"
            : "Reason: Processing evidence"
        XCTAssertTrue(
            app.staticTexts["background-work-failure-processing"]
                .waitForLabelOrValue(processingFailure, timeout: 5),
            "attention states must expose only a closed localized category")

        let idle = UITestLocale.environmentLocale == "es" ? "Inactivo" : "Idle"
        let processingRetry = app.buttons["background-work-action-processing"]
        XCTAssertTrue(processingRetry.waitForHittable(timeout: 5))
        processingRetry.click()
        XCTAssertTrue(
            app.staticTexts["background-work-status-processing"]
                .waitForLabelOrValue(idle, timeout: 5),
            "processing retry must route only to its owner and publish the new safe state")

        let settingsWindow = app.windows.containing(
            .any,
            identifier: "background-work-overview"
        ).firstMatch
        let settingsForm = settingsWindow.scrollViews.element(boundBy: 1)
        let graphRetry = app.buttons["background-work-action-memory-graph"]
        XCTAssertTrue(
            graphRetry.revealVertically(in: settingsForm),
            "the graph recovery action must be reachable in the bounded Settings form")
        graphRetry.click()
        XCTAssertTrue(
            app.staticTexts["background-work-status-memory-graph"]
                .waitForLabelOrValue(idle, timeout: 5),
            "graph retry must clear only the graph attention state")
        attachScreenshot(of: app, named: "background-work-center")
    }

    @MainActor
    func testRecordingDefersDerivedWorkAndStopResumesIt() {
        let app = XCUIApplication.portavoz(
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
            ? "Esperando a que termine la grabación"
            : "Waiting for recording to end"
        for owner in ["semantic-index", "memory-graph"] {
            XCTAssertTrue(
                app.staticTexts["background-work-status-\(owner)"]
                    .waitForLabelOrValue(waiting, timeout: 10),
                "\(owner) must not run through protected capture")
        }

        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(app.prepareForInteraction())
        let stop = app.buttons["recording-stop-after-remote-outage"]
        XCTAssertTrue(stop.waitForHittable(timeout: 10))
        stop.click()

        XCTAssertTrue(
            indicator.waitForDisappearance(timeout: 15),
            "Stop must resume both bounded owners and remove the non-idle indicator")
    }
}
