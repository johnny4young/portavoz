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
