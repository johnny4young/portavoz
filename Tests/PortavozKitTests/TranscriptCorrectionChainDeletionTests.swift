import Foundation
import GRDB
import PortavozCore
import XCTest

@testable import StorageKit

/// Correcting the same line twice makes the second correction supersede the
/// first, and `transcriptCorrection.supersedesCorrectionID` is a
/// self-referencing RESTRICT foreign key. SQLite checks RESTRICT per row, so a
/// whole-meeting delete would otherwise remove the superseded parent before its
/// successor inside the same statement and fail with a constraint error,
/// leaving the meeting in place.
final class TranscriptCorrectionChainDeletionTests: XCTestCase {
    private let device = UUID(uuidString: "9E0D0000-0000-4000-8000-000000000001")!

    func testFileBackedReplayAndPurgeKeepOtherChainsAndForeignKeysIntact() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("library.sqlite")
        let destination = try MeetingStore(databaseURL: url)
        let unrelated = try await seedCorrectionChain(in: destination)
        let source = try MeetingStore.inMemory()
        let meeting = try await seedCorrectionChain(in: source)
        let changes = try await source.pendingMeetingSyncChanges()
        let change = try XCTUnwrap(changes.first)
        let envelope = try await source.meetingSyncEnvelope(for: change, sourceDeviceID: device)
        let first = try await destination.applyRemoteMeetingSyncEnvelope(envelope)
        XCTAssertEqual(first, .applied)

        let history = try await source.transcriptCorrectionHistory(for: meeting.id)
        let previous = try XCTUnwrap(history.last)
        let third = TranscriptCorrectionEvent(
            id: UUID(), meetingID: meeting.id, baseTranscriptRevision: meeting.transcriptRevision,
            targetSegmentIDs: previous.targetSegmentIDs,
            kind: .replaceText(text: "Tercera corrección — it’s final.", language: "es"),
            sourceDeviceID: device, createdAt: previous.createdAt.addingTimeInterval(1),
            supersedesCorrectionID: previous.id)
        _ = try await source.appendTranscriptCorrection(third)
        let nextChanges = try await source.pendingMeetingSyncChanges()
        let nextChange = try XCTUnwrap(nextChanges.first)
        let nextEnvelope = try await source.meetingSyncEnvelope(for: nextChange, sourceDeviceID: device)
        let replayed = try await destination.applyRemoteMeetingSyncEnvelope(nextEnvelope)
        XCTAssertEqual(replayed, .applied)
        let replayedHistory = try await destination.transcriptCorrectionHistory(for: meeting.id)
        XCTAssertEqual(replayedHistory, history + [third])

        // A transaction after replay may not inherit weakened FK enforcement.
        let unrelatedHistory = try await destination.transcriptCorrectionHistory(for: unrelated.id)
        let parent = try XCTUnwrap(unrelatedHistory.first)
        do {
            try await destination.database.write { database in
                try database.execute(
                    sql: "DELETE FROM transcriptCorrection WHERE id = ?", arguments: [parent.id.uuidString])
            }
            XCTFail("Deleting only a superseded parent must still fail")
        } catch let error as DatabaseError {
            XCTAssertEqual(error.resultCode, .SQLITE_CONSTRAINT)
        }
        try await destination.delete(meeting.id)
        try await destination.purge(meeting.id)
        let reopened = try MeetingStore(databaseURL: url)
        let survivors = try await reopened.meetings(includeDeleted: true)
        XCTAssertEqual(survivors.map(\.id), [unrelated.id])
        let survivingHistory = try await reopened.transcriptCorrectionHistory(for: unrelated.id)
        XCTAssertEqual(survivingHistory, unrelatedHistory)
        try await reopened.database.read { database in
            XCTAssertTrue(try Row.fetchAll(database, sql: "PRAGMA foreign_key_check").isEmpty)
            XCTAssertEqual(try String.fetchOne(database, sql: "PRAGMA integrity_check"), "ok")
        }
    }

    func testPurgingATwiceCorrectedMeetingRemovesItAndItsHistory() async throws {
        let store = try MeetingStore.inMemory()
        let meeting = try await seedCorrectionChain(in: store)

        try await store.delete(meeting.id)
        try await store.purge(meeting.id)

        let survivors = try await store.meetings(includeDeleted: true)
        XCTAssertTrue(survivors.isEmpty)
        let remainingCorrections = try await store.database.read { database in
            try Int.fetchOne(
                database,
                sql: "SELECT COUNT(*) FROM transcriptCorrection") ?? -1
        }
        XCTAssertEqual(remainingCorrections, 0, "the chain must not outlive its meeting")
    }

    func testReplacingCorrectionsDuringReplayClearsTheWholeChain() async throws {
        let store = try MeetingStore.inMemory()
        let meeting = try await seedCorrectionChain(in: store)

        try await store.database.write { database in
            try MeetingStore.deletePortableMeetingChildren(
                meetingKey: meeting.id.rawValue.uuidString,
                includingTranscriptCorrections: true,
                in: database)
        }

        let remainingCorrections = try await store.database.read { database in
            try Int.fetchOne(
                database,
                sql: "SELECT COUNT(*) FROM transcriptCorrection") ?? -1
        }
        XCTAssertEqual(remainingCorrections, 0)
        let roots = try await store.meetings(includeDeleted: true)
        XCTAssertFalse(roots.isEmpty, "replay clears children, never the meeting root")
    }

    /// One meeting whose only segment carries two corrections, the second
    /// superseding the first — the shape ordinary editing produces.
    private func seedCorrectionChain(in store: MeetingStore) async throws -> Meeting {
        let meeting = Meeting(
            title: "Twice corrected",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000))
        try await store.save(meeting)
        let segment = TranscriptSegment(
            meetingID: meeting.id,
            speakerID: nil,
            channel: .microphone,
            text: "original",
            startTime: 0,
            endTime: 1,
            isFinal: true)
        try await store.save([segment])

        let first = TranscriptCorrectionEvent(
            id: UUID(),
            meetingID: meeting.id,
            baseTranscriptRevision: meeting.transcriptRevision,
            targetSegmentIDs: [segment.id],
            kind: .replaceText(text: "first", language: "en"),
            sourceDeviceID: device,
            createdAt: Date(timeIntervalSince1970: 1_700_000_100))
        _ = try await store.appendTranscriptCorrection(first)

        let second = TranscriptCorrectionEvent(
            id: UUID(),
            meetingID: meeting.id,
            baseTranscriptRevision: meeting.transcriptRevision,
            targetSegmentIDs: [segment.id],
            kind: .replaceText(text: "second", language: "en"),
            sourceDeviceID: device,
            createdAt: Date(timeIntervalSince1970: 1_700_000_200),
            supersedesCorrectionID: first.id)
        _ = try await store.appendTranscriptCorrection(second)

        let persisted = try await store.database.read { database in
            try Int.fetchOne(
                database,
                sql: "SELECT COUNT(*) FROM transcriptCorrection WHERE supersedesCorrectionID IS NOT NULL") ?? 0
        }
        XCTAssertEqual(persisted, 1, "the fixture must persist a real supersession chain")
        return meeting
    }
}

/// Merge provenance is decoded positionally, so its order is load-bearing.
/// SQLite does not promise `GROUP_CONCAT` follows a subquery's `ORDER BY`, and
/// the deployment floor predates `ORDER BY` inside aggregates, so each element
/// carries its ordinal and the decoder restores the order.
final class StructuralSearchProvenanceOrderTests: XCTestCase {
    func testProvenanceOrderComesFromTheOrdinalNotTheConcatenationOrder() throws {
        let first = "11111111-1111-4111-8111-111111111111"
        let second = "22222222-2222-4222-8222-222222222222"
        let third = "33333333-3333-4333-8333-333333333333"

        let inOrder = try MeetingStore.sourceSegmentIDs(
            "0:\(first),1:\(second),2:\(third)",
            resultID: first)
        let shuffled = try MeetingStore.sourceSegmentIDs(
            "2:\(third),0:\(first),1:\(second)",
            resultID: first)

        XCTAssertEqual(inOrder.map { $0.uuidString.lowercased() }, [first, second, third])
        XCTAssertEqual(shuffled, inOrder, "the ordinal decides, not the concatenation")
    }

    func testMalformedOrDuplicatedProvenanceFailsClosed() {
        let value = "11111111-1111-4111-8111-111111111111"
        for persisted in [
            "\(value)",                       // missing ordinal
            "x:\(value)",                     // non-numeric ordinal
            "0:\(value),0:\(value)",          // duplicated ordinal
            ""                                // empty
        ] {
            XCTAssertThrowsError(
                try MeetingStore.sourceSegmentIDs(persisted, resultID: value),
                "must reject \(persisted)")
        }
    }
}
