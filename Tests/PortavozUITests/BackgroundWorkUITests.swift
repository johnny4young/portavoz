import XCTest

final class BackgroundWorkUITests: PortavozUITestCase {
    @MainActor
    func testBackgroundWorkCenterShowsAllOwnersAndRecoversExactFailures() throws {
        let app = try XCUIApplication.portavoz(seedBackgroundWork: true)
        app.launchPortavoz()
        defer { finishUITestApplication(app) }

        let indicator = app.buttons["background-work-indicator"]
        XCTAssertTrue(
            indicator.waitForHittable(timeout: 15),
            "attention in a background owner must expose one compact app-level route")
        indicator.click()
        let settingsEntryDeadline = Date().addingTimeInterval(10)

        let settingsCategoryReady = app.control(withIdentifier: "settings-category-data")
            .waitForExistenceFast(timeout: max(0, settingsEntryDeadline.timeIntervalSinceNow))
        XCTAssertTrue(settingsCategoryReady,
                      "the compact indicator must expose the exact Settings category")
        let backgroundPaneReady = app.staticTexts["background-work-overview"].waitForExistenceFast(
            timeout: min(5, max(0, settingsEntryDeadline.timeIntervalSinceNow)))
        XCTAssertTrue(backgroundPaneReady,
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
            timeout: min(5, max(0, settingsEntryDeadline.timeIntervalSinceNow)),
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
        // A direct Settings route bypasses openSettingsWindow's editor
        // handoff. Observe the native owner and finish only the known search
        // editor before outside input; never dismiss an unknown interruption.
        _ = try XCTUnwrap(
            settingsCategoryReady && backgroundPaneReady && Date() <= settingsEntryDeadline ? app : nil,
            "the exact Settings destination must be ready within its original entry deadline")
        let nativeReady = app.prepareForInteraction(
            timeout: max(0, settingsEntryDeadline.timeIntervalSinceNow))
        _ = try XCTUnwrap(
            nativeReady && Date() <= settingsEntryDeadline ? app : nil,
            "the Settings route must own the native receiver within its original entry deadline")
        let editingHandoff = app.handOffTextFieldEditing(
            identifier: "settings-search-field",
            timeout: max(0, settingsEntryDeadline.timeIntervalSinceNow))
        _ = try XCTUnwrap(
            editingHandoff.succeeded && Date() <= settingsEntryDeadline ? app : nil,
            "the known Settings search editor must hand off before outside scrolling: \(editingHandoff.diagnosis)")
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
            try app.staticTexts["background-work-status-processing"]
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
            try app.staticTexts["background-work-status-memory-graph"]
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
        defer { finishUITestApplication(app) }

        let record = app.buttons["library-new-recording-button"]
        let recordEntryDeadline = Date().addingTimeInterval(15)
        let nativeRecordOwner = app.prepareForInteraction(
            timeout: max(0, recordEntryDeadline.timeIntervalSinceNow))
        _ = try XCTUnwrap(
            nativeRecordOwner && Date() <= recordEntryDeadline ? app : nil,
            "recording preparation must acknowledge the native receiver within its original deadline")
        let recordReady = record.waitForHittable(
            timeout: max(0, recordEntryDeadline.timeIntervalSinceNow))
        XCTAssertTrue(recordReady)
        _ = try XCTUnwrap(
            recordReady
                && record.waitForStableFrame(timeout: max(0, recordEntryDeadline.timeIntervalSinceNow))
                && app.hasObservedNativeReceiver(bundleIdentifier: keyboardReceiverBundleIdentifier)
                && Date() <= recordEntryDeadline ? record : nil,
            "the record target must be settled and the native receiver still owned before input")
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
                try app.staticTexts["background-work-status-\(owner)"]
                    .waitForLabelOrValue(waiting, timeout: 10),
                "\(owner) must not run through protected capture")
        }

        // Readable status rows do not prove Settings is the key window.
        // Close that exact destination rather than sending Command-W to an
        // independently reordered recording window.
        let closeDeadline = Date().addingTimeInterval(10)
        let settings = app.windows.containing(.button, identifier: "settings-category-data").element
        let closeSettings = settings.buttons["_XCUI:CloseWindow"]
        _ = try XCTUnwrap(
            app.prepareForInteraction(timeout: max(0, closeDeadline.timeIntervalSinceNow))
                && closeSettings.waitForStableFrame(timeout: max(0, closeDeadline.timeIntervalSinceNow))
                && app.hasObservedNativeReceiver(bundleIdentifier: keyboardReceiverBundleIdentifier)
                && Date() <= closeDeadline ? closeSettings : nil,
            "the exact Settings close target must be stable and natively owned before input")
        closeSettings.click()
        let returnedToRecording = app.prepareForInteraction(
            timeout: max(0, closeDeadline.timeIntervalSinceNow))
        XCTAssertTrue(returnedToRecording)
        _ = try XCTUnwrap(
            returnedToRecording && Date() <= closeDeadline ? app : nil,
            "returning from the exact Settings window must retain the original preparation deadline")
        let stop = app.buttons["recording-stop-after-remote-outage"]
        let stopReady = stop.waitForHittable(timeout: 10)
        XCTAssertTrue(stopReady)
        _ = try XCTUnwrap(stopReady ? stop : nil,
                          "a missing outage Stop must refuse input after Settings closes")
        stop.click()

        XCTAssertTrue(
            indicator.waitForDisappearance(timeout: 15),
            "Stop must resume both bounded owners and remove the non-idle indicator")
    }
}
