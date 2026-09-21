import AVFoundation
import XCTest

/// Synthetic PCM is decoded and copied for real, but recognition is scripted.
/// This exercises the native picker → admission → worker → queue → meeting route.
final class AudioImportUITests: PortavozUITestCase {
    private var ownedArtifacts: [URL] = []

    override func tearDown() async throws {
        try await super.tearDown()
        for artifact in ownedArtifacts {
            XCTAssertFalse(FileManager.default.fileExists(atPath: artifact.path),
                           "Synthetic import files must leave with their test owner")
        }
    }

    @MainActor
    func testMultipleAudioFilesReachPagedQueueAndOpenTheirMeeting() throws {
        let app = try fixtureApp()
        let folder = try makeAudioSelection(count: 21, app: app)
        // The entire queue must still finish when optional model preparation
        // fails, not merely when an already prepared diarizer returns no turns.
        app.launchArguments.append("-audio-import-diarizer-unavailable")
        app.launchPortavoz()
        defer { app.terminate() }
        guard chooseAudio(app: app) else { return }
        let panel = app.control(withIdentifier: "import-queue-panel")
        XCTAssertTrue(panel.waitForExistenceFast(timeout: 15))
        let expected = UITestLocale.environmentLocale == "es"
            ? "21 importaciones · 0 sin terminar" : "21 imports · 0 unfinished"
        // This is an asynchronous batch, not an already-rendered control.
        // Pace snapshots while the main actor publishes progress, rather than
        // repeatedly rebuilding the changing twenty-row AX tree every 50 ms.
        let finished = queueCount(expected, in: panel)
        XCTAssertTrue(waitForUITestCondition(timeout: 30, pollInterval: 1) { finished.exists })
        let completed = panel.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "import-queue-open-"))
        let next = panel.buttons["import-queue-next"]
        let previous = panel.buttons["import-queue-previous"]
        try assertReadyPage(panel, count: 20, previousEnabled: false, nextEnabled: true)
        next.click()
        XCTAssertTrue(previous.waitForEnabled(timeout: 5))
        try assertReadyPage(panel, count: 1, previousEnabled: true, nextEnabled: false)
        previous.click()
        XCTAssertTrue(next.waitForEnabled(timeout: 5))
        try assertReadyPage(panel, count: 20, previousEnabled: false, nextEnabled: true)
        panel.buttons["import-queue-close"].click()
        app.buttons["library-import-queue-open"].click()
        let open = completed.firstMatch
        XCTAssertTrue(open.waitForExistenceFast(timeout: 5))
        open.click()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "value CONTAINS %@", "No envíes 2.")).firstMatch
            .waitForExistenceFast(timeout: 10))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.appendingPathComponent("selection").path).count, 21)
    }

    @MainActor
    func testCancelOneImportContinuesTheNextAndExplicitRetryReusesTheQueue() throws {
        let app = try fixtureApp(holdFirst: true)
        let folder = try makeAudioSelection(count: 2, app: app)
        app.launchArguments.append("-audio-import-fail-mutations-once")
        app.launchPortavoz()
        defer { app.terminate() }
        guard chooseAudio(app: app) else { return }
        let panel = app.control(withIdentifier: "import-queue-panel")
        XCTAssertTrue(panel.waitForExistenceFast(timeout: 15))
        let state = panel.staticTexts.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND (value == %@ OR value == %@)",
            "import-queue-state-", "Transcribing…", "Transcribiendo…")).firstMatch
        XCTAssertTrue(state.waitForExistenceFast(timeout: 15))
        let id = String(state.identifier.dropFirst("import-queue-state-".count))
        let cancel = panel.buttons["import-queue-cancel-\(id)"]
        cancel.click()
        let error = panel.staticTexts["import-queue-error"]
        XCTAssertTrue(error.waitForExistenceFast(timeout: 5))
        XCTAssertTrue(cancel.exists, "a rejected cancel must not retire the active job")
        panel.buttons["import-queue-error-dismiss"].click()
        XCTAssertTrue(error.waitForDisappearance(timeout: 3))
        cancel.click()
        let retry = panel.buttons["import-queue-retry-\(id)"]
        XCTAssertTrue(retry.waitForExistenceFast(timeout: 10))
        let other = panel.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "import-queue-open-")).firstMatch
        XCTAssertTrue(other.waitForExistenceFast(timeout: 10))
        retry.click()
        XCTAssertTrue(panel.buttons["import-queue-open-\(id)"].waitForExistenceFast(timeout: 15))
        try assertReadyPage(panel, count: 2, previousEnabled: false, nextEnabled: false)
        panel.buttons["import-queue-close"].click()
        verifyRejectedLibraryDeletion(id: id, app: app)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.appendingPathComponent("selection").path).count, 2)
    }

    @MainActor
    func testRelaunchResumesPublishedAudioWithoutTheSelectedOriginals() throws {
        let app = try fixtureApp(holdFirst: true)
        let folder = try makeAudioSelection(count: 1, app: app)
        app.launchPortavoz()
        defer { app.terminate() }
        guard chooseAudio(app: app) else { return }
        let panel = app.control(withIdentifier: "import-queue-panel")
        XCTAssertTrue(panel.waitForExistenceFast(timeout: 15))
        let state = panel.staticTexts.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND (value == %@ OR value == %@)",
            "import-queue-state-", "Transcribing…", "Transcribiendo…")).firstMatch
        XCTAssertTrue(state.waitForExistenceFast(timeout: 15))
        let id = String(state.identifier.dropFirst("import-queue-state-".count))
        app.terminate()
        // The fixture advances the worker's injected clock on the next launch,
        // not the production lease policy or the system clock.
        app.launchArguments.append("-audio-import-expired-owner")
        try FileManager.default.removeItem(at: folder.appendingPathComponent("selection"))
        app.launchArguments.removeAll { $0 == "-audio-import-hold-first" }
        app.launchPortavoz()
        let queue = app.buttons["library-import-queue-open"]
        XCTAssertTrue(queue.waitForExistenceFast(timeout: 10))
        queue.click()
        let open = panel.buttons["import-queue-open-\(id)"]
        XCTAssertTrue(open.waitForExistenceFast(timeout: 15))
        open.click()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "value CONTAINS %@", "Don’t send 2.")).firstMatch
            .waitForExistenceFast(timeout: 10))
        app.buttons["library-import-queue-open"].click()
        let expected = UITestLocale.environmentLocale == "es"
            ? "1 importaciones · 0 sin terminar" : "1 imports · 0 unfinished"
        XCTAssertTrue(queueCount(expected, in: panel).waitForExistenceFast(timeout: 5))
    }

    @MainActor
    private func queueCount(_ expected: String, in panel: XCUIElement) -> XCUIElement {
        // One native predicate replaces separate exists/label/value snapshots
        // while the queue is changing. Missing or nonmatching text still fails.
        panel.staticTexts.matching(NSPredicate(
            format: "identifier == %@ AND (label == %@ OR value == %@)",
            "import-queue-count", expected, expected)).firstMatch
    }

    @MainActor
    private func assertReadyPage(
        _ panel: XCUIElement, count: Int, previousEnabled: Bool, nextEnabled: Bool
    ) throws {
        // One coherent observation after each acknowledged state change. Never
        // reuse it across navigation, mutation, or input ownership decisions.
        var pending: [any XCUIElementSnapshot] = [try panel.snapshot()]
        var buttons: [any XCUIElementSnapshot] = []
        var statuses: [any XCUIElementSnapshot] = []
        while let element = pending.popLast() {
            if element.elementType == .button { buttons.append(element) }
            if element.elementType == .staticText {
                XCTAssertNotEqual(element.identifier, "import-queue-error")
                if element.identifier.hasPrefix("import-queue-state-") { statuses.append(element) }
            }
            pending.append(contentsOf: element.children)
        }
        let opens = buttons.filter { $0.identifier.hasPrefix("import-queue-open-") }
        XCTAssertEqual(opens.count, count, "Every page entry must publish a readable meeting")
        XCTAssertEqual(statuses.count, count)
        let meetingIDs = Set(opens.map { String($0.identifier.dropFirst("import-queue-open-".count)) })
        XCTAssertEqual(meetingIDs.count, count, "Duplicate rows cannot substitute for missing meetings")
        XCTAssertEqual(meetingIDs, Set(statuses.map { String($0.identifier.dropFirst("import-queue-state-".count)) }))
        XCTAssertFalse(buttons.contains {
            $0.identifier.hasPrefix("import-queue-retry-") || $0.identifier.hasPrefix("import-queue-cancel-")
        }, "A completed page must not retain failed or unfinished actions")
        let spanish = UITestLocale.environmentLocale == "es"
        for status in statuses {
            let expected = spanish ? "Listo" : "Ready"
            XCTAssertTrue(status.label == expected || status.value as? String == expected)
        }
        for (identifier, label, enabled) in [
            ("import-queue-next", spanish ? "Siguiente" : "Next", nextEnabled),
            ("import-queue-previous", spanish ? "Anterior" : "Previous", previousEnabled)
        ] {
            let matches = buttons.filter { $0.identifier == identifier }
            XCTAssertEqual(matches.count, 1)
            let button = try XCTUnwrap(matches.first)
            XCTAssertEqual(button.label, label)
            XCTAssertEqual(button.isEnabled, enabled)
        }
    }

    @MainActor
    private func verifyRejectedLibraryDeletion(id: String, app: XCUIApplication) {
        let row = app.control(withIdentifier: "library-meeting-\(id)").firstMatch
        XCTAssertTrue(row.waitForExistenceFast(timeout: 5))
        let delete = "library-meeting-delete-\(id)"
        row.rightClick()
        app.menuItems[delete].click()
        let error = app.staticTexts["library-action-error"]
        XCTAssertTrue(error.waitForExistenceFast(timeout: 5))
        XCTAssertTrue(row.exists)
        app.buttons["library-action-error-dismiss"].click()
        XCTAssertTrue(error.waitForDisappearance(timeout: 3))
        row.rightClick()
        app.menuItems[delete].click()
        XCTAssertTrue(row.waitForDisappearance(timeout: 5))
    }

    @MainActor
    private func fixtureApp(holdFirst: Bool = false) throws -> XCUIApplication {
        let app = try XCUIApplication.portavoz()
        app.launchArguments += ["-audio-import-ui-fixture", "-audio-import-picker-fixture"]
        for key in ["TMPDIR", "PORTAVOZ_UI_TEST_DATABASE_PATH", "PORTAVOZ_AUDIO_ROOT"] {
            ownedArtifacts.append(URL(fileURLWithPath: try XCTUnwrap(app.launchEnvironment[key])))
        }
        if holdFirst { app.launchArguments.append("-audio-import-hold-first") }
        return app
    }

    @MainActor
    private func chooseAudio(app: XCUIApplication) -> Bool {
        let menu = app.control(withIdentifier: "library-record-menu")
        guard menu.waitForHittable(timeout: 5) else {
            XCTFail("The Library must expose the import menu")
            return false
        }
        menu.click()
        let action = app.menuItems["library-import-audio-button"]
        guard action.waitForExistenceFast(timeout: 5) else {
            XCTFail("The import action must be available in the record menu")
            return false
        }
        action.click()
        let picker = app.dialogs["open-panel"]
        guard picker.waitForExistenceFast(timeout: 5) else {
            XCTFail("The import action must open the native audio picker")
            return false
        }
        // The disposable fixture sets only the initial directory, never the
        // selection. Go to Folder and nested-modal ownership remain exercised
        // by the mandatory native interruption controls instead of every batch.
        // List view avoids NSOpenPanel's offscreen column frames for deep paths.
        typeKey("2", modifierFlags: .command, in: app, modalAnchor: "open-panel")
        let first = app.textFields.matching(NSPredicate(format: "value == %@", "Audio 00.wav")).firstMatch
        guard first.waitForExistenceFast(timeout: 5) else {
            XCTFail("The native picker did not reach the selected synthetic audio folder")
            return false
        }
        // The modal panel owns keyboard focus after switching to List view.
        // Select its files with the native command; read-only AX name fields
        // are not clickable controls even when their frames are visible.
        typeKey("a", modifierFlags: .command, in: app, modalAnchor: "open-panel")
        guard picker.buttons["OKButton"].waitForEnabled(timeout: 5) else {
            XCTFail("The native picker did not enable import for its selected audio")
            return false
        }
        // Complete the keyboard-owned selection with its native default action.
        // An enabled XPC button can lack a usable click activation point; do not
        // repeat submission or mistake an open picker for worker progress.
        typeKey(.return, modifierFlags: [], in: app, modalAnchor: "open-panel")
        guard picker.waitForDisappearance(timeout: 5) else {
            XCTFail("The native picker did not acknowledge the import selection")
            return false
        }
        return true
    }

    @MainActor
    private func makeAudioSelection(count: Int, app: XCUIApplication) throws -> URL {
        // One owner joins app exit before removing originals and copied audio,
        // including interruption exits where a method's defer cannot run.
        let folder = URL(fileURLWithPath: try XCTUnwrap(app.launchEnvironment["TMPDIR"]), isDirectory: true)
        let selection = folder.appendingPathComponent("selection")
        ownedArtifacts.append(selection)
        try FileManager.default.createDirectory(at: selection, withIntermediateDirectories: true)
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_600))
        buffer.frameLength = 1_600
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        for index in 0..<1_600 { samples[index] = 0 }
        for index in 0..<count {
            let url = selection.appendingPathComponent(String(format: "Audio %02d.wav", index))
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
        }
        return folder
    }
}
