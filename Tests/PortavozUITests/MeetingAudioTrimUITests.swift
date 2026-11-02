import AVFoundation
import CryptoKit
import XCTest

/// Cuts only the generated channels under this app's disposable audio root.
final class MeetingAudioTrimUITests: PortavozUITestCase {
    @MainActor
    func testSilentTailRequiresConfirmationAndCutsOnlyAfterConfirmation() throws {
        let app = try XCUIApplication.portavoz(seedDemo: true)
        defer { finishUITestApplication(app) }
        let files = try prepareSilentTail(in: app)
        let originalHashes = try hashes(of: files)
        app.configureFeatureUITestHandshake(
            argument: "-simulate-audio-trim-handshake",
            name: "audio-trim",
            readyEnvironmentKey: "PORTAVOZ_UI_TEST_AUDIO_TRIM_READY_PATH",
            continueEnvironmentKey: "PORTAVOZ_UI_TEST_AUDIO_TRIM_CONTINUE_PATH")
        app.launchPortavoz()
        XCTAssertTrue(app.waitForSeededLibraryToSettle())
        let meeting = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'library-meeting-'"))
            .firstMatch
        XCTAssertTrue(app.prepareForInteraction())
        XCTAssertTrue(meeting.waitForStableFrame(timeout: 10))
        meeting.click()
        XCTAssertTrue(app.buttons["player-play-pause"].waitForExistenceFast(timeout: 10))
        XCTAssertTrue(app.staticTexts["/ 10:00"].exists)
        XCTAssertTrue(app.openMeetingDetailReadingPane("transcript"))
        assertTranscript(in: app)
        attachScreenshot(of: app, named: "audio-trim-before")

        openTrimConfirmation(in: app)
        attachScreenshot(of: app, named: "audio-trim-confirmation")
        let cancel = app.buttons["player-trim-silence-cancel"]
        XCTAssertTrue(cancel.waitForHittable(timeout: 5))
        cancel.click()
        XCTAssertTrue(waitForUITestCondition(timeout: 5) {
            !app.buttons["player-trim-silence-confirm"].exists
        })
        XCTAssertEqual(try hashes(of: files), originalHashes)
        try assertDurations(of: files, equalTo: 600)
        XCTAssertTrue(app.staticTexts["/ 10:00"].exists)
        XCTAssertFalse(app.control(withIdentifier: "detail-trim-message").exists)
        assertTranscript(in: app)

        openTrimConfirmation(in: app)
        app.buttons["player-trim-silence-confirm"].click()
        XCTAssertTrue(app.control(withIdentifier: "detail-trim-progress")
            .waitForExistenceFast(timeout: 5))
        XCTAssertEqual(try hashes(of: files), originalHashes,
                       "the handshake holds the real operation before changing either channel")
        attachScreenshot(of: app, named: "audio-trim-progress")
        XCTAssertTrue(app.continueFeatureUITestHandshake(
            readyEnvironmentKey: "PORTAVOZ_UI_TEST_AUDIO_TRIM_READY_PATH",
            continueEnvironmentKey: "PORTAVOZ_UI_TEST_AUDIO_TRIM_CONTINUE_PATH"))

        let result = app.control(withIdentifier: "detail-trim-message")
        XCTAssertTrue(result.waitForExistenceFast(timeout: 15))
        let expectedMessage = "Removed 6 min, 25 sec of silence."
        XCTAssertTrue(waitForUITestCondition(timeout: 5) {
            result.exists && (result.label == expectedMessage
                || result.value as? String == expectedMessage)
        }, "the completed cut must present its removed-duration message")
        print("AUDIO_TRIM_COMPLETION_TEXT labelMatches=\(result.label == expectedMessage) "
            + "valueMatches=\(result.value as? String == expectedMessage)")
        XCTAssertTrue(waitForUITestCondition(timeout: 5) {
            !app.control(withIdentifier: "detail-trim-progress").exists
        }, "completion must retire the progress presentation")
        try assertDurations(of: files, equalTo: 215)
        XCTAssertNotEqual(try hashes(of: files), originalHashes)
        XCTAssertTrue(app.staticTexts["/ 3:35"].waitForExistenceFast(timeout: 5))
        assertTranscript(in: app)
        app.control(withIdentifier: "player-options").click()
        XCTAssertFalse(app.menuItems["player-trim-silence"].exists,
                       "the shortened recording must no longer offer a long-tail cut")
        typeKey(.escape, modifierFlags: [], in: app)
        attachScreenshot(of: app, named: "audio-trim-after")
    }

    @MainActor
    private func openTrimConfirmation(in app: XCUIApplication) {
        let options = app.control(withIdentifier: "player-options")
        XCTAssertTrue(options.waitForHittable(timeout: 5))
        options.click()
        let trim = app.menuItems["player-trim-silence"]
        XCTAssertTrue(trim.waitForExistenceFast(timeout: 5))
        trim.click()
        XCTAssertTrue(app.buttons["player-trim-silence-confirm"].waitForHittable(timeout: 5))
        XCTAssertTrue(app.staticTexts[
            "The audio after the last phrase is deleted for good, and transcript edits are reset."].exists)
    }

    @MainActor
    private func assertTranscript(in app: XCUIApplication) {
        let viewport = app.control(withIdentifier: "detail-transcript-scroll")
        XCTAssertTrue(viewport.waitForExistenceFast(timeout: 5))
        let lines = [
            "Revisemos el presupuesto de transcripción.",
            "El rollout del modelo queda para el viernes.",
            "¿Cuándo es el rollout?",
            "Cerremos con los próximos pasos del rollout.",
        ]
        // An earlier pass leaves the first rows clipped above the viewport.
        let first = app.staticTexts[lines[0]]
        for _ in 0..<8 where !first.exists {
            viewport.scroll(byDeltaX: 0, deltaY: 96)
        }
        for text in lines {
            let line = app.staticTexts[text]
            // The playback carousel can omit fully clipped rows from AX.
            // Materialize each row through its own identified scroll boundary.
            for _ in 0..<4 where !line.exists {
                viewport.scroll(byDeltaX: 0, deltaY: -96)
            }
            XCTAssertTrue(line.waitForExistenceFast(timeout: 5), text)
        }
    }

    @MainActor
    private func prepareSilentTail(in app: XCUIApplication) throws -> [URL] {
        let root = URL(fileURLWithPath: try XCTUnwrap(app.launchEnvironment["PORTAVOZ_AUDIO_ROOT"]))
        let directory = root.appendingPathComponent("Audio").appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8_000))
        buffer.frameLength = 8_000
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        let files = ["microphone.wav", "system.wav"].map { directory.appendingPathComponent($0) }
        for (channel, url) in files.enumerated() {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            for second in 0..<600 {
                for index in 0..<8_000 {
                    samples[index] = second < 205
                        ? 0.1 * Float(sin(2 * .pi * Double(220 + channel * 220) * Double(index) / 8_000))
                        : 0
                }
                try file.write(from: buffer)
            }
        }
        return files
    }

    @MainActor
    private func hashes(of files: [URL]) throws -> [Data] {
        try files.map { Data(SHA256.hash(data: try Data(contentsOf: $0, options: .mappedIfSafe))) }
    }

    @MainActor
    private func assertDurations(of files: [URL], equalTo expected: Double) throws {
        for url in files {
            let file = try AVAudioFile(forReading: url)
            XCTAssertEqual(Double(file.length) / file.processingFormat.sampleRate, expected, accuracy: 0.01)
        }
    }
}
