import AVFoundation
import XCTest

/// Synthetic PCM is decoded and copied for real, but recognition is scripted.
/// This exercises the native picker → admission → worker → queue → meeting route.
final class AudioImportUITests: PortavozUITestCase {
    @MainActor
    func testMultipleAudioFilesReachPagedQueueAndOpenTheirMeeting() throws {
        let folder = try makeAudioSelection(count: 21)
        defer { try? FileManager.default.removeItem(at: folder) }
        let app = fixtureApp()
        app.launchPortavoz()
        defer { app.terminate() }
        chooseAudio(in: folder.appendingPathComponent("selection"), app: app)
        let panel = app.control(withIdentifier: "import-queue-panel")
        XCTAssertTrue(panel.waitForExistenceFast(timeout: 15))
        let count = app.staticTexts["import-queue-count"]
        let expected = UITestLocale.environmentLocale == "es"
            ? "21 importaciones · 0 sin terminar" : "21 imports · 0 unfinished"
        XCTAssertTrue(count.waitForLabelOrValue(expected, timeout: 30))
        let next = app.buttons["import-queue-next"]
        let previous = app.buttons["import-queue-previous"]
        XCTAssertFalse(previous.isEnabled)
        XCTAssertTrue(next.isEnabled)
        next.click()
        XCTAssertTrue(previous.waitForEnabled(timeout: 5))
        XCTAssertFalse(next.isEnabled)
        previous.click()
        app.buttons["import-queue-close"].click()
        app.buttons["library-import-queue-open"].click()
        let open = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "import-queue-open-")).firstMatch
        XCTAssertTrue(open.waitForExistenceFast(timeout: 5))
        open.click()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "value CONTAINS %@", "No envíes 2.")).firstMatch
            .waitForExistenceFast(timeout: 10))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.appendingPathComponent("selection").path).count, 21)
    }

    @MainActor
    func testCancelOneImportContinuesTheNextAndExplicitRetryReusesTheQueue() throws {
        let folder = try makeAudioSelection(count: 2)
        defer { try? FileManager.default.removeItem(at: folder) }
        let app = fixtureApp(holdFirst: true)
        app.launchArguments.append("-audio-import-fail-mutations-once")
        app.launchPortavoz()
        defer { app.terminate() }
        chooseAudio(in: folder.appendingPathComponent("selection"), app: app)
        let state = app.staticTexts.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND (value == %@ OR value == %@)",
            "import-queue-state-", "Transcribing…", "Transcribiendo…")).firstMatch
        XCTAssertTrue(state.waitForExistenceFast(timeout: 15))
        let id = String(state.identifier.dropFirst("import-queue-state-".count))
        let cancel = app.buttons["import-queue-cancel-\(id)"]
        cancel.click()
        let error = app.staticTexts["import-queue-error"]
        XCTAssertTrue(error.waitForExistenceFast(timeout: 5))
        XCTAssertTrue(cancel.exists, "a rejected cancel must not retire the active job")
        app.buttons["import-queue-error-dismiss"].click()
        XCTAssertTrue(error.waitForDisappearance(timeout: 3))
        cancel.click()
        let retry = app.buttons["import-queue-retry-\(id)"]
        XCTAssertTrue(retry.waitForExistenceFast(timeout: 10))
        let other = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "import-queue-open-")).firstMatch
        XCTAssertTrue(other.waitForExistenceFast(timeout: 10))
        retry.click()
        XCTAssertTrue(app.buttons["import-queue-open-\(id)"].waitForExistenceFast(timeout: 15))
        XCTAssertFalse(retry.exists)
        XCTAssertFalse(app.staticTexts["import-queue-error"].exists)
        app.buttons["import-queue-close"].click()
        verifyRejectedLibraryDeletion(id: id, app: app)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.appendingPathComponent("selection").path).count, 2)
    }

    @MainActor
    func testRelaunchResumesPublishedAudioWithoutTheSelectedOriginals() throws {
        let folder = try makeAudioSelection(count: 1)
        defer { try? FileManager.default.removeItem(at: folder) }
        let app = fixtureApp(holdFirst: true)
        app.launchPortavoz()
        defer { app.terminate() }
        chooseAudio(in: folder.appendingPathComponent("selection"), app: app)
        let state = app.staticTexts.matching(NSPredicate(
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
        let open = app.buttons["import-queue-open-\(id)"]
        XCTAssertTrue(open.waitForExistenceFast(timeout: 15))
        open.click()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "value CONTAINS %@", "Don’t send 2.")).firstMatch
            .waitForExistenceFast(timeout: 10))
        app.buttons["library-import-queue-open"].click()
        let expected = UITestLocale.environmentLocale == "es"
            ? "1 importaciones · 0 sin terminar" : "1 imports · 0 unfinished"
        XCTAssertTrue(app.staticTexts["import-queue-count"].waitForLabelOrValue(expected, timeout: 5))
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
    private func fixtureApp(holdFirst: Bool = false) -> XCUIApplication {
        let app = XCUIApplication.portavoz()
        app.launchArguments.append("-audio-import-ui-fixture")
        app.launchEnvironment["PORTAVOZ_UI_TEST_DATABASE_PATH"] =
            "/private/tmp/portavoz-import-db-" + UUID().uuidString + ".sqlite"
        // Only the nonsandboxed app creates this destination. The sandboxed
        // runner creates sources in its own container and grants selection.
        app.launchEnvironment["PORTAVOZ_AUDIO_ROOT"] = "/private/tmp/portavoz-import-owned-" + UUID().uuidString
        if holdFirst { app.launchArguments.append("-audio-import-hold-first") }
        return app
    }

    @MainActor
    private func chooseAudio(in folder: URL, app: XCUIApplication) {
        app.buttons["library-import-audio-button"].click()
        app.typeKey("g", modifierFlags: [.command, .shift])
        let path = app.textFields.firstMatch
        XCTAssertTrue(path.waitForExistenceFast(timeout: 5))
        app.typeText(folder.path + "/")
        app.typeKey(.return, modifierFlags: [])
        // List view avoids NSOpenPanel's offscreen column frames for deep paths.
        app.typeKey("2", modifierFlags: .command)
        let first = app.descendants(matching: .any)
            .matching(NSPredicate(format: "value == %@", "Audio 00.wav")).firstMatch
        guard first.waitForExistenceFast(timeout: 5) else {
            XCTFail("The native picker did not reach the selected synthetic audio folder")
            return
        }
        // The modal panel already owns keyboard focus after Go to Folder.
        // Select its files with the native command; read-only AX name fields
        // are not clickable controls even when their frames are visible.
        app.typeKey("a", modifierFlags: .command)
        let confirm = app.buttons["OKButton"]
        XCTAssertTrue(confirm.waitForEnabled(timeout: 5))
        confirm.click()
    }

    private func makeAudioSelection(count: Int) throws -> URL {
        // The sandboxed runner owns source files; NSOpenPanel grants their
        // explicit selection to the app. Only the app creates its destination.
        let folder = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("portavoz-import-ui-" + UUID().uuidString)
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
