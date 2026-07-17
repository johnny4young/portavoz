import Foundation
import GRDB
import PortavozCore
import XCTest

@testable import StorageKit

final class MeetingSyncStateTests: XCTestCase {
    func testV13MigrationAddsAnEmptyContentFreeJournalAndTransactionalTriggers() throws {
        let database = try DatabaseQueue()
        let migrator = StorageSchema.migrator()
        try migrator.migrate(database, upTo: "v13")
        let meeting = Meeting(
            title: "Legacy sync",
            startedAt: Date(timeIntervalSince1970: 1_784_282_400))
        let timestamp = Date(timeIntervalSince1970: 1_784_282_401)
        try database.write { db in
            try MeetingRecord(meeting, createdAt: timestamp, updatedAt: timestamp).insert(db)
        }

        try migrator.migrate(database)

        try database.write { db in
            XCTAssertEqual(StorageSchema.version, 14)
            XCTAssertEqual(
                try Set(db.columns(in: "meetingSyncState").map(\.name)),
                [
                    "meetingID", "localGeneration", "acknowledgedGeneration",
                    "changedAt", "isDeleted",
                ])
            XCTAssertTrue(
                try db.foreignKeys(on: "meetingSyncState").isEmpty,
                "purge-surviving sync tombstones must not reference meeting")
            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM meetingSyncState"),
                0,
                "migration must not opt an existing offline library into sync")
            let triggers = try String.fetchAll(
                db,
                sql: """
                    SELECT name FROM sqlite_master
                     WHERE type = 'trigger' AND name LIKE '%_sync_%'
                     ORDER BY name
                    """)
            XCTAssertEqual(triggers.count, 48)
            XCTAssertTrue(triggers.contains("meeting_sync_au"))
            XCTAssertTrue(triggers.contains("companionCardEvidenceSegment_sync_au"))
            XCTAssertTrue(triggers.contains("summaryClaimFeedback_sync_au"))

            try db.execute(
                sql: "UPDATE meeting SET title = ?, updatedAt = ? WHERE id = ?",
                arguments: ["Changed after migration", timestamp, meeting.id.rawValue.uuidString])
            let row = try XCTUnwrap(MeetingSyncStateRecord.fetchOne(
                db,
                key: meeting.id.rawValue.uuidString))
            XCTAssertEqual(row.localGeneration, 1)
            XCTAssertEqual(row.acknowledgedGeneration, 0)
            XCTAssertFalse(row.isDeleted)
        }
    }

    func testAcknowledgingAnInFlightGenerationNeverHidesANewerEdit() async throws {
        let store = try MeetingStore.inMemory()
        var meeting = Meeting(title: "Planning", startedAt: Date())
        try await store.save(meeting)
        let initialPending = try await store.pendingMeetingSyncChanges()
        let first = try XCTUnwrap(initialPending.first)

        meeting.title = "Planning renamed while sending"
        try await store.save(meeting)
        try await store.acknowledgeMeetingSync(first)

        let pending = try await store.pendingMeetingSyncChanges()
        let second = try XCTUnwrap(pending.first)
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(second.meetingID, meeting.id)
        XCTAssertGreaterThan(second.generation, first.generation)

        try await store.acknowledgeMeetingSync(second)
        let remaining = try await store.pendingMeetingSyncChanges()
        XCTAssertTrue(remaining.isEmpty)
    }

    func testSyncVisibleChildrenQueueAggregateButDeviceLocalDerivationsDoNot() async throws {
        let store = try MeetingStore.inMemory()
        var meeting = Meeting(
            title: "Portable aggregate",
            startedAt: Date(),
            audioDirectory: "Audio/local-only")
        try await store.save(meeting)
        try await acknowledgeAll(in: store)

        meeting.audioDirectory = "Audio/another-local-path"
        try await store.save(meeting)
        var pending = try await store.pendingMeetingSyncChanges()
        XCTAssertTrue(pending.isEmpty)

        let speaker = Speaker(meetingID: meeting.id, label: "S1", displayName: "Ana")
        try await store.save([speaker])
        pending = try await store.pendingMeetingSyncChanges()
        XCTAssertEqual(pending.count, 1)
        try await acknowledgeAll(in: store)

        try await store.database.write { db in
            let now = Date()
            let person = Person(preferredName: "Ana")
            try PersonRecord(person, createdAt: now, updatedAt: now).insert(db)
            try db.execute(
                sql: "UPDATE speaker SET personID = ? WHERE id = ?",
                arguments: [person.id.rawValue.uuidString, speaker.id.rawValue.uuidString])
        }
        pending = try await store.pendingMeetingSyncChanges()
        XCTAssertTrue(
            pending.isEmpty,
            "canonical person links are device-local and must not schedule sync")

        let segment = TranscriptSegment(
            meetingID: meeting.id,
            speakerID: speaker.id,
            channel: .system,
            text: "The portable transcript changed.",
            startTime: 0,
            endTime: 3,
            isFinal: true)
        try await store.save([segment])
        try await acknowledgeAll(in: store)

        try await store.database.write { db in
            try db.execute(
                sql: "UPDATE segment SET embedding = ? WHERE id = ?",
                arguments: [Data([0, 0, 0, 0]), segment.id.uuidString])
        }
        pending = try await store.pendingMeetingSyncChanges()
        XCTAssertTrue(
            pending.isEmpty,
            "derived embeddings are device-local and must not schedule sync")

        try await store.save([ContextItem(
            meetingID: meeting.id,
            kind: .note,
            content: "Ship the portable journal",
            timestamp: 2)])
        pending = try await store.pendingMeetingSyncChanges()
        XCTAssertEqual(pending.count, 1)
    }

    func testEvidenceOnlyReplacementQueuesItsOwningMeeting() async throws {
        let store = try MeetingStore.inMemory()
        let meeting = Meeting(title: "Evidence journal", startedAt: Date())
        try await store.save(meeting)
        let speaker = Speaker(meetingID: meeting.id, label: "S1")
        let segment = TranscriptSegment(
            meetingID: meeting.id,
            speakerID: speaker.id,
            channel: .system,
            text: "Ship the evidence.",
            startTime: 0,
            endTime: 2,
            isFinal: true)
        try await store.save([speaker])
        try await store.save([segment])
        let cardID = UUID()
        let card = CompanionCard(
            id: cardID,
            question: "What should ship?",
            answer: "The evidence.",
            kind: .context,
            source: "on-device",
            askedAt: 2,
            evidence: CompanionCardEvidence(
                cardID: cardID,
                questionSegmentIDs: [segment.id]))
        try await store.save([card], for: meeting.id)
        try await acknowledgeAll(in: store)

        try await store.save([card.withEvidence(nil)], for: meeting.id)

        let pending = try await store.pendingMeetingSyncChanges()
        XCTAssertEqual(pending.map(\.meetingID), [meeting.id])
        let cards = try await store.companionCards(for: meeting.id)
        XCTAssertNil(cards.first?.evidence)
    }

    func testJournalMutationRollsBackWithItsAggregateWrite() async throws {
        enum Expected: Error { case rollback }

        let store = try MeetingStore.inMemory()
        let meeting = Meeting(title: "Before transaction", startedAt: Date())
        try await store.save(meeting)
        try await acknowledgeAll(in: store)

        do {
            try await store.database.write { db in
                try db.execute(
                    sql: "UPDATE meeting SET title = ? WHERE id = ?",
                    arguments: ["Must roll back", meeting.id.rawValue.uuidString])
                throw Expected.rollback
            }
            XCTFail("Expected transaction rollback")
        } catch Expected.rollback {
            // Expected.
        }

        let pending = try await store.pendingMeetingSyncChanges()
        XCTAssertTrue(pending.isEmpty)
        let storedDetail = try await store.detail(meeting.id)
        let detail = try XCTUnwrap(storedDetail)
        XCTAssertEqual(detail.meeting.title, "Before transaction")
    }

    func testDeleteRestoreAndPurgeKeepAnExplicitSyncTombstone() async throws {
        let store = try MeetingStore.inMemory()
        let meeting = Meeting(title: "Deletion", startedAt: Date())
        try await store.save(meeting)
        try await acknowledgeAll(in: store)

        try await store.delete(meeting.id)
        var pending = try await store.pendingMeetingSyncChanges()
        let deletion = try XCTUnwrap(pending.first)
        XCTAssertTrue(deletion.isDeleted)
        try await store.acknowledgeMeetingSync(deletion)

        try await store.restore(meeting.id)
        pending = try await store.pendingMeetingSyncChanges()
        let restoration = try XCTUnwrap(pending.first)
        XCTAssertFalse(restoration.isDeleted)
        try await store.acknowledgeMeetingSync(restoration)

        try await store.delete(meeting.id)
        try await acknowledgeAll(in: store)
        try await store.purge(meeting.id)

        pending = try await store.pendingMeetingSyncChanges()
        let purge = try XCTUnwrap(pending.first)
        XCTAssertTrue(purge.isDeleted)
        let detail = try await store.detail(meeting.id)
        XCTAssertNil(detail)
        let durableState = try await store.database.read { db in
            try MeetingSyncStateRecord.fetchOne(db, key: meeting.id.rawValue.uuidString)
        }
        XCTAssertNotNil(durableState, "physical purge must retain cloud deletion evidence")
    }

    func testInitialSyncExplicitlySeedsLiveAndDeletedMeetings() async throws {
        let store = try MeetingStore.inMemory()
        let live = Meeting(title: "Live", startedAt: Date())
        let deleted = Meeting(title: "Deleted", startedAt: Date().addingTimeInterval(1))
        try await store.save(live)
        try await store.save(deleted)
        try await store.delete(deleted.id)
        try await acknowledgeAll(in: store)

        let seeded = try await store.markAllMeetingsForInitialSync()
        XCTAssertEqual(seeded, 2)
        let pending = try await store.pendingMeetingSyncChanges()
        XCTAssertEqual(Set(pending.map(\.meetingID)), [live.id, deleted.id])
        XCTAssertFalse(try XCTUnwrap(pending.first(where: { $0.meetingID == live.id })).isDeleted)
        XCTAssertTrue(try XCTUnwrap(pending.first(where: { $0.meetingID == deleted.id })).isDeleted)
    }

    func testInvalidLimitsAndAcknowledgementsFailClosed() async throws {
        let store = try MeetingStore.inMemory()
        let meeting = Meeting(title: "Fence", startedAt: Date())
        try await store.save(meeting)
        let pending = try await store.pendingMeetingSyncChanges()
        let current = try XCTUnwrap(pending.first)

        await XCTAssertThrowsErrorAsync {
            _ = try await store.pendingMeetingSyncChanges(limit: 0)
        }
        await XCTAssertThrowsErrorAsync {
            try await store.acknowledgeMeetingSync(MeetingSyncChange(
                meetingID: meeting.id,
                generation: current.generation + 1,
                changedAt: current.changedAt,
                isDeleted: false))
        }
        await XCTAssertThrowsErrorAsync {
            try await store.acknowledgeMeetingSync(MeetingSyncChange(
                meetingID: MeetingID(),
                generation: 1,
                changedAt: current.changedAt,
                isDeleted: false))
        }
    }

    private func acknowledgeAll(in store: MeetingStore) async throws {
        for change in try await store.pendingMeetingSyncChanges() {
            try await store.acknowledgeMeetingSync(change)
        }
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected error", file: file, line: line)
    } catch {
        // Expected.
    }
}
