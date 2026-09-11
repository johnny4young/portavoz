import AppKit
import XCTest

final class RecordingInputUITests: PortavozUITestCase {
    @MainActor
    func testAcceptedNotesAndObjectivesSurviveTerminationAndRecovery() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let app = fixture.app
        try start(fixture)
        let note = "Confirmar responsable antes de publicar"
        addNote(note, in: app)
        XCTAssertEqual(try fixture.query("SELECT count(*) FROM contextItem WHERE kind = 'note'"), "1")
        let meetingID = try fixture.query("SELECT meetingID FROM contextItem WHERE kind = 'note'")
        app.openAssistTab("objectives")
        let field = app.control(withIdentifier: "recording-objective-field")
        field.click()
        app.typeText("Check the owner's approval")
        app.buttons["recording-objective-add"].click()
        let toggle = app.buttons["recording-objective-toggle"].firstMatch
        XCTAssertTrue(toggle.waitForExistenceFast(timeout: 5))
        XCTAssertTrue(waitForUITestCondition(timeout: 3) { toggle.isEnabled })
        toggle.click()
        XCTAssertTrue(waitForUITestCondition(timeout: 3) { toggle.isEnabled })
        XCTAssertEqual(try fixture.query("SELECT count(*) FROM contextItem WHERE kind = 'objective' AND timestamp > 0"), "1")
        let objectiveID = try fixture.query("SELECT id FROM contextItem WHERE kind = 'objective'")
        field.click()
        app.typeText("Remove this temporary objective")
        app.buttons["recording-objective-add"].click()
        XCTAssertTrue(waitForUITestCondition(timeout: 3) { field.isEnabled })
        let removedID = try fixture.query("SELECT id FROM contextItem WHERE content = 'Remove this temporary objective'")
        let remove = app.buttons["recording-objective-remove-\(removedID)"]
        remove.click()
        XCTAssertTrue(waitForUITestCondition(timeout: 3) { !remove.exists })
        XCTAssertEqual(try fixture.query("SELECT count(*) FROM contextItem WHERE deletedAt IS NOT NULL"), "1")

        // Terminate without Stop. Only the disposable test host is targeted;
        // launch recovery, not the live controller, must reconstruct the record.
        app.terminate()
        app.launchArguments.removeAll { $0 == "-simulate-live-transcript-browsing" }
        app.launchPortavoz()
        let meeting = app.control(withIdentifier: "library-meeting-\(meetingID)").firstMatch
        XCTAssertTrue(meeting.waitForExistenceFast(timeout: 10))
        meeting.click()
        XCTAssertTrue(app.control(withIdentifier: "detail-processing-status").waitForExistenceFast(timeout: 10))
        XCTAssertEqual(try fixture.query("SELECT lifecycleState FROM meeting WHERE id = '\(meetingID)'"), "needsAttention")
        XCTAssertEqual(try fixture.query("SELECT id FROM contextItem WHERE kind = 'objective' AND deletedAt IS NULL"), objectiveID)
        XCTAssertEqual(try fixture.query("SELECT count(*) FROM contextItem WHERE deletedAt IS NULL"), "2")
        XCTAssertTrue(app.control(withIdentifier: "detail-notes-section").waitForExistenceFast(timeout: 8))
        XCTAssertTrue(app.staticTexts[note].exists)
    }

    @MainActor
    func testFailedWriteRetainsInputAndStopWaitsForAnExplicitRetry() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try start(fixture)
        let app = fixture.app
        try fixture.failWrites()
        app.openAssistTab("notes")
        let text = "No enviar hasta revisar"
        let field = app.control(withIdentifier: "recording-note-field")
        field.click()
        app.typeText(text)
        app.buttons["recording-note-add"].click()
        XCTAssertTrue(app.control(withIdentifier: "recording-input-save-failure").waitForExistenceFast(timeout: 5))
        XCTAssertTrue(field.waitForLabelOrValue(text, timeout: 2))
        XCTAssertEqual(try fixture.query("SELECT count(*) FROM contextItem"), "0")
        app.buttons["recording-stop"].click()
        XCTAssertTrue(app.control(withIdentifier: "recording-failure").waitForExistenceFast(timeout: 5))
        XCTAssertTrue(app.control(withIdentifier: "recording-input-retained-text").exists)
        XCTAssertTrue(app.buttons["recording-input-discard"].exists)
        let meetingID = try fixture.query("SELECT id FROM meeting")
        app.control(withIdentifier: "library-meeting-\(meetingID)").firstMatch.click()
        let back = app.buttons["library-return-to-recording"]
        XCTAssertTrue(back.waitForExistenceFast(timeout: 5))
        back.click()
        XCTAssertTrue(app.buttons["recording-input-retry"].waitForExistenceFast(timeout: 5))
        XCTAssertEqual(try fixture.query("SELECT count(*) FROM meeting"), "1")
        _ = try fixture.query("DROP TRIGGER fail_live_input")
        app.buttons["recording-input-retry"].click()
        waitForStoppedCapture(in: app)
        XCTAssertEqual(try fixture.query("SELECT count(*) FROM contextItem"), "1")
        XCTAssertEqual(try fixture.query("SELECT count(*) FROM meeting WHERE lifecycleState = 'recording'"), "0")
        XCTAssertEqual(try fixture.query("SELECT content FROM contextItem"), text)
        XCTAssertFalse(app.control(withIdentifier: "recording-input-save-failure").exists)
    }

    @MainActor
    func testFailedRemovalKeepsTheAcceptedNoteUntilDiscardOrRetry() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try start(fixture)
        let app = fixture.app
        addNote("Keep this accepted note", in: app)
        let id = try fixture.query("SELECT id FROM contextItem")
        _ = try fixture.query("""
            CREATE TRIGGER fail_live_remove BEFORE UPDATE ON contextItem BEGIN
                SELECT RAISE(ABORT, 'injected removal failure'); END
            """)
        app.buttons["recording-note-remove-\(id)"].click()
        XCTAssertTrue(app.buttons["recording-input-discard"].waitForExistenceFast(timeout: 5))
        XCTAssertEqual(try fixture.query("SELECT count(*) FROM contextItem WHERE deletedAt IS NULL"), "1")
        app.buttons["recording-input-discard"].click()
        let remove = app.buttons["recording-note-remove-\(id)"]
        XCTAssertTrue(waitForUITestCondition(timeout: 3) { remove.isEnabled })
        XCTAssertTrue(remove.exists)
        _ = try fixture.query("DROP TRIGGER fail_live_remove")
        remove.click()
        XCTAssertTrue(waitForUITestCondition(timeout: 3) { !remove.exists })
        XCTAssertEqual(try fixture.query("SELECT count(*) FROM contextItem WHERE deletedAt IS NULL"), "0")
        XCTAssertEqual(try fixture.query("SELECT count(*) FROM contextItem"), "1", "removal must leave a tombstone")
    }

    @MainActor
    func testStopDrainsAnAdmittedWriteBeforeFinalizingTheRecording() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let entered = fixture.root.appendingPathComponent("write-entered")
        let release = fixture.root.appendingPathComponent("write-release")
        fixture.app.launchEnvironment["PORTAVOZ_UI_TEST_INPUT_ENTERED_PATH"] = entered.path
        fixture.app.launchEnvironment["PORTAVOZ_UI_TEST_INPUT_CONTINUE_PATH"] = release.path
        try start(fixture)
        let app = fixture.app
        app.openAssistTab("notes")
        app.control(withIdentifier: "recording-note-field").click()
        app.typeText("Keep the write admitted before Stop")
        app.buttons["recording-note-add"].click()
        XCTAssertTrue(waitForUITestCondition(timeout: 3) { FileManager.default.fileExists(atPath: entered.path) })
        XCTAssertTrue(app.control(withIdentifier: "recording-input-saving").exists)
        XCTAssertEqual(try fixture.query("SELECT count(*) FROM contextItem"), "0")
        app.buttons["recording-stop"].click()
        XCTAssertFalse(app.buttons["recording-stop"].exists, "audio controls must retire before the held write")
        XCTAssertEqual(try fixture.query("SELECT count(*) FROM meeting WHERE lifecycleState = 'recording'"), "1")
        try Data().write(to: release, options: .atomic)
        waitForStoppedCapture(in: app)
        XCTAssertEqual(try fixture.query("SELECT count(*) FROM meeting WHERE lifecycleState = 'needsAttention'"), "1")
        XCTAssertEqual(try fixture.query("SELECT content FROM contextItem"), "Keep the write admitted before Stop")
        XCTAssertFalse(app.control(withIdentifier: "recording-input-save-failure").exists)
    }

    @MainActor
    private func waitForStoppedCapture(in app: XCUIApplication) {
        // Observe the app's acknowledged transition first. Polling SQLite
        // from another process holds read locks and can itself reject Stop.
        let reference = app.control(withIdentifier: "recording-failure-reference")
        XCTAssertTrue(waitForUITestCondition(timeout: 5) {
            reference.exists && renderedText(of: reference).hasSuffix("capture.no-audio")
        }, reference.exists ? renderedText(of: reference) : "missing Stop outcome")
    }

    @MainActor
    private func start(_ fixture: Fixture) throws {
        fixture.app.launchPortavoz()
        let record = fixture.app.buttons["library-new-recording-button"]
        XCTAssertTrue(record.waitForExistenceFast(timeout: 15))
        record.click()
        XCTAssertTrue(fixture.app.waitForLiveTranscriptFrontier())
    }

    @MainActor
    private func addNote(_ text: String, in app: XCUIApplication) {
        app.openAssistTab("notes")
        let field = app.control(withIdentifier: "recording-note-field")
        field.click()
        app.typeText(text)
        app.buttons["recording-note-add"].click()
        XCTAssertTrue(app.staticTexts[text].waitForExistenceFast(timeout: 5))
        XCTAssertTrue(waitForUITestCondition(timeout: 3) { field.isEnabled })
    }

    @MainActor
    private struct Fixture {
        let root: URL
        let database: URL
        let app: XCUIApplication

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            database = root.appendingPathComponent("library.sqlite")
            app = XCUIApplication.portavoz(seedDemo: false, simulateLiveTranscriptBrowsing: true)
            app.launchEnvironment["PORTAVOZ_UI_TEST_DATABASE_PATH"] = database.path
            app.launchEnvironment["PORTAVOZ_AUDIO_ROOT"] = root.appendingPathComponent("audio").path
        }

        func failWrites() throws {
            _ = try query("""
                CREATE TRIGGER fail_live_input BEFORE INSERT ON contextItem BEGIN
                    SELECT RAISE(ABORT, 'injected write failure'); END
                """)
        }

        func query(_ sql: String) throws -> String {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
            process.arguments = ["-cmd", ".timeout 2000", database.path, sql]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = output
            try process.run()
            process.waitUntilExit()
            let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            XCTAssertEqual(process.terminationStatus, 0, text)
            return text
        }

        func remove() {
            app.terminate()
            try? FileManager.default.removeItem(at: root)
        }
    }
}
