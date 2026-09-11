import ApplicationKit
import Foundation
import GRDB
import PortavozCore
import XCTest

@testable import StorageKit

final class RecordingInputPersistenceTests: XCTestCase {
    func testSnapshotPreservesAcceptedEditsAndDoesNotResurrectDeletedInput() async throws {
        let fixture = try await recording()
        let note = ContextItem(meetingID: fixture.meeting.id, kind: .note,
                               content: "La decisión aún no está tomada", timestamp: 1)
        let removed = ContextItem(meetingID: fixture.meeting.id, kind: .objective,
                                  content: "Confirm the owner's approval", timestamp: 0)
        try await fixture.store.save([note, removed])
        try await fixture.store.deleteContextItem(removed.id)
        let stale = ContextItem(id: note.id, meetingID: note.meetingID, kind: .note,
                                content: "stale snapshot", timestamp: 1)
        try await fixture.store.installCapturedSnapshot(snapshot(fixture, items: [stale, removed]))
        let items = try await fixture.store.contextItems(for: fixture.meeting.id)
        XCTAssertEqual(items.map(\.id), [note.id])
        XCTAssertEqual(items.map(\.content), [note.content])
    }

    func testRecoverySnapshotWithNoContextKeepsPreviouslyAcceptedInput() async throws {
        let fixture = try await recording()
        let note = ContextItem(meetingID: fixture.meeting.id, kind: .note,
                               content: "Don't send this yet — revisar mañana", timestamp: 0)
        try await fixture.store.save([note])
        try await fixture.store.installCapturedSnapshot(snapshot(fixture, items: []))
        let items = try await fixture.store.contextItems(for: fixture.meeting.id)
        XCTAssertEqual(items.map(\.id), [note.id])
    }

    func testLiveWritesCommitBeforeAcknowledgementAndSurviveReopen() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("library.sqlite")
        let fixture = try await recording(databaseURL: url)
        let writer = PersistRecordingInput(store: fixture.store)
        let objective = ContextItem(meetingID: fixture.meeting.id, kind: .objective,
                                    content: "Confirmar quién decide — don't assume", timestamp: 0)
        try await writer.execute(meetingID: fixture.meeting.id, items: [objective])
        let checked = ContextItem(id: objective.id, meetingID: objective.meetingID, kind: .objective,
                                  content: "✓ " + objective.content, timestamp: 2)
        try await writer.execute(meetingID: fixture.meeting.id, items: [checked])
        let reopened = try MeetingStore(databaseURL: url)
        let rows = try await reopened.contextItems(for: fixture.meeting.id)
        XCTAssertEqual(rows.map(\.id), [objective.id])
        XCTAssertEqual(rows.map(\.content), [checked.content])
        try await writer.execute(meetingID: fixture.meeting.id, removing: [objective.id])
        let removed = try await reopened.contextItems(for: fixture.meeting.id)
        XCTAssertTrue(removed.isEmpty)
        do {
            try await writer.execute(meetingID: fixture.meeting.id, items: [objective])
            XCTFail("a retired identity must not be reused")
        } catch { XCTAssertTrue(error is StorageError) }
    }

    func testRejectedBatchRollsBackAndCannotCrossMeetingOrStopBoundaries() async throws {
        let fixture = try await recording()
        let writer = PersistRecordingInput(store: fixture.store)
        let note = ContextItem(meetingID: fixture.meeting.id, kind: .note,
                               content: "keep the exact boundary", timestamp: 0)
        let foreign = ContextItem(meetingID: MeetingID(), kind: .note, content: "wrong owner", timestamp: 0)
        for invalid in [foreign, ContextItem(meetingID: fixture.meeting.id, kind: .note,
                                            content: "  ", timestamp: 0),
                        ContextItem(meetingID: fixture.meeting.id, kind: .note,
                                    content: "invalid clock", timestamp: .infinity)] {
            do {
                try await writer.execute(meetingID: fixture.meeting.id, items: [note, invalid])
                XCTFail("invalid batch was accepted")
            } catch { XCTAssertTrue(error is StorageError) }
            let rows = try await fixture.store.contextItems(for: fixture.meeting.id)
            XCTAssertTrue(rows.isEmpty)
        }
        try await fixture.store.database.write { db in
            try db.execute(sql: """
                CREATE TRIGGER fail_context_insert BEFORE INSERT ON contextItem
                WHEN NEW.content = 'reject second row' BEGIN
                    SELECT RAISE(ABORT, 'injected write failure'); END;
                """)
        }
        let rejected = ContextItem(meetingID: fixture.meeting.id, kind: .note,
                                   content: "reject second row", timestamp: 1)
        do {
            try await writer.execute(meetingID: fixture.meeting.id, items: [note, rejected])
            XCTFail("the second insert must abort the entire transaction")
        } catch { XCTAssertTrue(error is DatabaseError) }
        let rows = try await fixture.store.contextItems(for: fixture.meeting.id)
        XCTAssertTrue(rows.isEmpty)
        try await fixture.store.installCapturedSnapshot(snapshot(fixture, items: []))
        do {
            try await writer.execute(meetingID: fixture.meeting.id, items: [note])
            XCTFail("a stale live callback must not mutate a stopped meeting")
        } catch { XCTAssertTrue(error is StorageError) }
    }

    func testEmptyAudioStopPreservesAcceptedInputInsteadOfDiscardingTheMeeting() async throws {
        let fixture = try await recording()
        let note = ContextItem(meetingID: fixture.meeting.id, kind: .note,
                               content: "The microphone failed but I wrote this", timestamp: 0)
        try await PersistRecordingInput(store: fixture.store).execute(meetingID: fixture.meeting.id, items: [note])
        let dependencies = EmptyAudioDependencies()
        let result = await StopRecording(audioFiles: dependencies, store: fixture.store, lifecycle: dependencies)
            .execute(StopRecordingRequest(recordingShell: fixture.meeting, reservedAssets: [fixture.asset],
                                          captions: [], contextItems: [note], companionCards: [],
                                          capture: StopRecordingCapture(publishedFiles: [:]), voiceprint: nil))
        guard case .failedCapturePreserved = result else { return XCTFail("user input was not preserved") }
        let detail = try await fixture.store.detail(fixture.meeting.id)
        XCTAssertEqual(detail?.meeting.lifecycleState, .needsAttention)
        let rows = try await fixture.store.contextItems(for: fixture.meeting.id)
        XCTAssertEqual(rows.map(\.content), [note.content])
    }

    func testContextExceptionDoesNotPermitDuplicateSnapshotIDsOrExistingTranscriptReplacement() async throws {
        let fixture = try await recording()
        let note = ContextItem(meetingID: fixture.meeting.id, kind: .note, content: "Keep this", timestamp: 0)
        do {
            try await fixture.store.installCapturedSnapshot(snapshot(fixture, items: [note, note]))
            XCTFail("duplicate snapshot identities must still reject the aggregate")
        } catch { XCTAssertTrue(error is StorageError) }
        try await fixture.store.save([TranscriptSegment(meetingID: fixture.meeting.id, channel: .microphone,
                                                        text: "User-owned transcript", startTime: 0, endTime: 1,
                                                        isFinal: true)])
        do {
            try await fixture.store.installCapturedSnapshot(snapshot(fixture, items: [note]))
            XCTFail("the live-context exception must not allow replacement of transcript children")
        } catch { XCTAssertTrue(error is StorageError) }
        let detail = try await fixture.store.detail(fixture.meeting.id)
        XCTAssertEqual(detail?.segments.map(\.text), ["User-owned transcript"])
        let notes = try await fixture.store.contextItems(for: fixture.meeting.id)
        XCTAssertTrue(notes.isEmpty, "a rejected aggregate must not leak a context insert")
    }

    func testExternalReaderCollisionKeepsAcceptedInputAndTheSameStopCanCompleteAfterRelease() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("library.sqlite")
        let fixture = try await recording(databaseURL: url)
        let note = ContextItem(meetingID: fixture.meeting.id, kind: .note, content: "Keep the accepted input", timestamp: 0)
        try await PersistRecordingInput(store: fixture.store).execute(meetingID: fixture.meeting.id, items: [note])
        var configuration = Configuration()
        configuration.readonly = true
        configuration.allowsUnsafeTransactions = true
        let reader = try DatabaseQueue(path: url.path, configuration: configuration)
        try await reader.unsafeRead { db in
            try db.execute(sql: "BEGIN")
            _ = try Int.fetchOne(db, sql: "SELECT count(*) FROM contextItem")
        }
        defer { try? reader.unsafeRead { try $0.execute(sql: "ROLLBACK") } }
        do {
            try await fixture.store.markMeetingNeedsAttention(fixture.meeting.id, errorCode: "capture.no-audio")
            XCTFail("the external read transaction must hold the rollback journal lock")
        } catch let error as DatabaseError {
            // Apple SQLite can surface the same held-reader conflict as
            // IOERR_LOCK rather than BUSY. Do not admit unrelated I/O errors.
            XCTAssertTrue(error.resultCode == .SQLITE_BUSY || error.extendedResultCode == .SQLITE_IOERR_LOCK,
                          "unexpected SQLite failure: \(error.extendedResultCode)")
        }
        let dependencies = EmptyAudioDependencies()
        let stop = StopRecording(audioFiles: dependencies, store: fixture.store, lifecycle: dependencies)
        let request = StopRecordingRequest(recordingShell: fixture.meeting, reservedAssets: [fixture.asset],
                                           captions: [], contextItems: [note], companionCards: [],
                                           capture: StopRecordingCapture(publishedFiles: [:]), voiceprint: nil)
        let blocked = await stop.execute(request)
        guard case .processingFailed(let failure, nil) = blocked else { return XCTFail("expected the locked write") }
        XCTAssertEqual(failure, .recoveryPersistenceFailed)
        try await reader.unsafeRead { try $0.execute(sql: "ROLLBACK") }
        let result = await stop.execute(request)
        guard case .failedCapturePreserved = result else { return XCTFail("the same Stop must preserve input") }
        let rows = try await fixture.store.contextItems(for: fixture.meeting.id)
        XCTAssertEqual(rows.map(\.id), [note.id])
    }

    private struct Fixture {
        let store: MeetingStore
        let meeting: Meeting
        let asset: AudioAsset
    }

    private func recording(databaseURL: URL? = nil) async throws -> Fixture {
        let store = try databaseURL.map(MeetingStore.init(databaseURL:)) ?? MeetingStore.inMemory()
        let id = MeetingID()
        let meeting = Meeting(id: id, title: "Public input fixture",
                              startedAt: Date(timeIntervalSince1970: 1_783_695_600),
                              audioDirectory: "Audio/\(id.rawValue.uuidString)", lifecycleState: .recording)
        let asset = AudioAsset.pendingCapture(
            meetingID: id, channel: .microphone,
            relativePath: AudioCapturePath.stagingRelativePath(
                directory: meeting.audioDirectory!, channel: .microphone), at: meeting.startedAt)
        try await store.beginRecording(meeting, assets: [asset])
        return Fixture(store: store, meeting: meeting, asset: asset)
    }

    private func snapshot(_ fixture: Fixture, items: [ContextItem]) -> CapturedMeetingSnapshot {
        var meeting = fixture.meeting
        meeting.endedAt = meeting.startedAt.addingTimeInterval(2)
        meeting.lifecycleState = .needsAttention
        meeting.lastProcessingError = "transcription.empty"
        var asset = fixture.asset
        asset.relativePath = AudioCapturePath.publishedRelativePath(
            directory: meeting.audioDirectory!, channel: .microphone)
        asset.container = "caf"
        asset.codec = "pcm-s16le"
        asset.sampleRate = 48_000
        asset.channelCount = 1
        asset.durationSeconds = 2
        asset.byteCount = 192_128
        asset.sha256 = String(repeating: "a", count: 64)
        asset.healthStatus = .healthy
        asset.peakDBFS = -6
        asset.rmsDBFS = -18
        return CapturedMeetingSnapshot(meeting: meeting, assets: [asset], speakers: [], segments: [],
                                       contextItems: items, companionCards: [])
    }
}

private struct EmptyAudioDependencies: StopRecordingAudioFiles, StopRecordingLifecycle {
    func captureFileExists(relativePath: String) async -> Bool { false }
    func kickPostCaptureProcessing() async {}
    func scheduleRecordingEngineRelease() async {}
}
