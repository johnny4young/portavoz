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
        let folder = try makeAudioSelection(count: 21)
        let app = try fixtureApp()
        // The entire queue must still finish when optional model preparation
        // fails, not merely when an already prepared diarizer returns no turns.
        app.launchArguments.append("-audio-import-diarizer-unavailable")
        app.launchPortavoz()
        defer { app.terminate() }
        guard chooseAudio(in: folder.appendingPathComponent("selection"), app: app) else { return }
        let panel = app.control(withIdentifier: "import-queue-panel")
        XCTAssertTrue(panel.waitForExistenceFast(timeout: 15))
        let expected = UITestLocale.environmentLocale == "es"
            ? "21 importaciones · 0 sin terminar" : "21 imports · 0 unfinished"
        XCTAssertTrue(queueCount(expected, in: panel).waitForExistenceFast(timeout: 30))
        let completed = panel.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "import-queue-open-"))
        XCTAssertEqual(completed.count, 20, "Every first-page import must publish a readable meeting")
        let next = panel.buttons["import-queue-next"]
        let previous = panel.buttons["import-queue-previous"]
        XCTAssertFalse(previous.isEnabled)
        XCTAssertTrue(next.isEnabled)
        next.click()
        XCTAssertTrue(previous.waitForEnabled(timeout: 5))
        XCTAssertFalse(next.isEnabled)
        XCTAssertEqual(completed.count, 1, "The last import must also publish without speaker models")
        previous.click()
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
        let folder = try makeAudioSelection(count: 2)
        let app = try fixtureApp(holdFirst: true)
        app.launchArguments.append("-audio-import-fail-mutations-once")
        app.launchPortavoz()
        defer { app.terminate() }
        guard chooseAudio(in: folder.appendingPathComponent("selection"), app: app) else { return }
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
        XCTAssertFalse(retry.exists)
        XCTAssertFalse(panel.staticTexts["import-queue-error"].exists)
        panel.buttons["import-queue-close"].click()
        verifyRejectedLibraryDeletion(id: id, app: app)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.appendingPathComponent("selection").path).count, 2)
    }

    @MainActor
    func testRelaunchResumesPublishedAudioWithoutTheSelectedOriginals() throws {
        let folder = try makeAudioSelection(count: 1)
        let app = try fixtureApp(holdFirst: true)
        app.launchPortavoz()
        defer { app.terminate() }
        guard chooseAudio(in: folder.appendingPathComponent("selection"), app: app) else { return }
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
        app.launchArguments.append("-audio-import-ui-fixture")
        for key in ["TMPDIR", "PORTAVOZ_UI_TEST_DATABASE_PATH", "PORTAVOZ_AUDIO_ROOT"] {
            ownedArtifacts.append(URL(fileURLWithPath: try XCTUnwrap(app.launchEnvironment[key])))
        }
        if holdFirst { app.launchArguments.append("-audio-import-hold-first") }
        return app
    }

    @MainActor
    private func chooseAudio(in folder: URL, app: XCUIApplication) -> Bool {
        app.buttons["library-import-audio-button"].click()
        app.typeKey("g", modifierFlags: [.command, .shift])
        let path = app.textFields.firstMatch
        XCTAssertTrue(path.waitForExistenceFast(timeout: 5))
        app.typeText(folder.path + "/")
        app.typeKey(.return, modifierFlags: [])
        // List view avoids NSOpenPanel's offscreen column frames for deep paths.
        app.typeKey("2", modifierFlags: .command)
        let first = app.textFields.matching(NSPredicate(format: "value == %@", "Audio 00.wav")).firstMatch
        guard first.waitForExistenceFast(timeout: 5) else {
            XCTFail("The native picker did not reach the selected synthetic audio folder")
            return false
        }
        // The modal panel already owns keyboard focus after Go to Folder.
        // Select its files with the native command; read-only AX name fields
        // are not clickable controls even when their frames are visible.
        app.typeKey("a", modifierFlags: .command)
        let picker = app.dialogs["open-panel"]
        guard picker.buttons["OKButton"].waitForEnabled(timeout: 5) else {
            XCTFail("The native picker did not enable import for its selected audio")
            return false
        }
        // Complete the keyboard-owned selection with its native default action.
        // An enabled XPC button can lack a usable click activation point; do not
        // repeat submission or mistake an open picker for worker progress.
        app.typeKey(.return, modifierFlags: [])
        guard picker.waitForDisappearance(timeout: 5) else {
            XCTFail("The native picker did not acknowledge the import selection")
            return false
        }
        return true
    }

    private func makeAudioSelection(count: Int) throws -> URL {
        // One owner joins app exit before removing originals and copied audio,
        // including interruption exits where a method's defer cannot run.
        let folder = try UITestStorage.makeDirectory()
        ownedArtifacts.append(folder)
        let selection = folder.appendingPathComponent("selection")
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
