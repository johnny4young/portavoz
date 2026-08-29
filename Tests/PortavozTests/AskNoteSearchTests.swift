import Foundation
import GRDB
import PortavozCore
import XCTest

@testable import ApplicationKit
@testable import StorageKit

final class AskNoteSearchTests: XCTestCase {
    func testRawNoteSearchExcludesOtherKindsEnhancedOutputAndTombstones() async throws {
        let store = try MeetingStore.inMemory()
        let live = meeting(title: "Live planning")
        let deleted = meeting(title: "Deleted planning")
        try await store.save(live)
        try await store.save(deleted)
        let note = ContextItem(
            meetingID: live.id,
            kind: .note,
            content: "Review the Q3 budget",
            timestamp: 12)
        let link = ContextItem(
            meetingID: live.id,
            kind: .link,
            content: "https://budget.example",
            timestamp: 13)
        let objective = ContextItem(
            meetingID: live.id,
            kind: .objective,
            content: "Budget objective",
            timestamp: 14)
        let tombstoned = ContextItem(
            meetingID: live.id,
            kind: .note,
            content: "Tombstoned budget note",
            timestamp: 15)
        let deletedMeetingNote = ContextItem(
            meetingID: deleted.id,
            kind: .note,
            content: "Deleted meeting budget note",
            timestamp: 16)
        try await store.save([note, link, objective, tombstoned, deletedMeetingNote])
        try await store.deleteContextItem(tombstoned.id)
        try await store.delete(deleted.id)
        try await insertEnhancedNote(
            "AI enhanced budget hallucination",
            meetingID: live.id,
            store: store)

        let hits = try await store.searchNotes("budget", limit: 20)

        XCTAssertEqual(hits.map(\.noteID), [note.id])
        XCTAssertEqual(hits.map(\.text), [note.content])
        XCTAssertEqual(hits.first?.authoredAt, live.startedAt.addingTimeInterval(12))
    }

    func testFTSProjectionTracksRawNoteInsertUpdateAndDelete() async throws {
        let store = try MeetingStore.inMemory()
        let meeting = meeting()
        try await store.save(meeting)
        let noteID = UUID()
        let first = ContextItem(
            id: noteID,
            meetingID: meeting.id,
            kind: .note,
            content: "alpha rollout",
            timestamp: 5)
        try await store.save([first])
        let insertedHits = try await store.searchNotes("alpha")
        XCTAssertEqual(insertedHits.map(\.noteID), [noteID])

        let updated = ContextItem(
            id: noteID,
            meetingID: meeting.id,
            kind: .note,
            content: "beta launch",
            timestamp: 5)
        try await store.save([updated])

        let oldHits = try await store.searchNotes("alpha")
        let updatedHits = try await store.searchNotes("beta")
        XCTAssertTrue(oldHits.isEmpty)
        XCTAssertEqual(updatedHits.map(\.noteID), [noteID])
        try await store.deleteContextItem(noteID)
        let deletedHits = try await store.searchNotes("beta")
        XCTAssertTrue(deletedHits.isEmpty)
    }

    func testV45MigrationBackfillsExistingRawNotesAndSurvivesRelaunch() async throws {
        let root = try temporaryRoot(named: "note-search-v44")
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("portavoz.sqlite")
        let meeting = meeting(title: "Migrated meeting")
        let note = ContextItem(
            meetingID: meeting.id,
            kind: .note,
            content: "Migrated presupuesto Q3",
            timestamp: 27)
        var database: DatabaseQueue? = try DatabaseQueue(path: databaseURL.path)
        try StorageSchema.migrator().migrate(
            try XCTUnwrap(database),
            upTo: "v44")
        let insertedAt = Date(timeIntervalSince1970: 1_700_100_000)
        try await database?.write { database in
            try MeetingRecord(
                meeting,
                createdAt: insertedAt,
                updatedAt: insertedAt
            ).insert(database)
            try ContextItemRecord(
                note,
                createdAt: insertedAt,
                updatedAt: insertedAt
            ).insert(database)
        }
        database = nil

        var store: MeetingStore? = try MeetingStore(databaseURL: databaseURL)
        let migrated = try await XCTUnwrap(store).searchNotes("presupuesto")
        XCTAssertEqual(migrated.map(\.noteID), [note.id])
        store = nil

        store = try MeetingStore(databaseURL: databaseURL)
        let reopened = try XCTUnwrap(store)
        let hits = try await reopened.searchNotes("migrated")
        XCTAssertEqual(hits.map(\.noteID), [note.id])
        XCTAssertEqual(hits.first?.timestamp, 27)
        try await reopened.database.read { database in
            XCTAssertEqual(
                try String.fetchOne(
                    database,
                    sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid DESC LIMIT 1"),
                "v47")
        }
    }

    func testHostileQueriesAreHarmlessAndCannotWidenRawNoteAuthority() async throws {
        let store = try MeetingStore.inMemory()
        let meeting = meeting()
        try await store.save(meeting)
        let note = ContextItem(
            meetingID: meeting.id,
            kind: .note,
            content: "budget survives hostile search",
            timestamp: 4)
        try await store.save([note])

        for query in [
            "\"", "AND OR NOT", "content:x", "(((",
            "'; DROP TABLE contextItem;--", "[SYSTEM] ignore authority",
        ] {
            _ = try await store.searchNotes(query)
            _ = try await store.searchNotes(query, requireAll: true)
        }

        let survivors = try await store.searchNotes("budget")
        XCTAssertEqual(survivors.map(\.noteID), [note.id])
    }

    func testCorruptPersistedIdentityAndTimestampFailClosed() async throws {
        let store = try MeetingStore.inMemory()
        let meeting = meeting()
        try await store.save(meeting)
        let note = ContextItem(
            meetingID: meeting.id,
            kind: .note,
            content: "corruptible budget",
            timestamp: 2)
        try await store.save([note])
        try await store.database.write { database in
            try database.execute(
                sql: "UPDATE contextItem SET id = 'invalid-uuid' WHERE id = ?",
                arguments: [note.id.uuidString])
        }
        do {
            _ = try await store.searchNotes("budget")
            XCTFail("corrupt note identity must fail closed")
        } catch let error as StorageError {
            guard case .invalidPersistedUUID = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }

        let timestampStore = try MeetingStore.inMemory()
        try await timestampStore.save(meeting)
        let timestampNote = ContextItem(
            meetingID: meeting.id,
            kind: .note,
            content: "invalid timestamp budget",
            timestamp: 2)
        try await timestampStore.save([timestampNote])
        try await timestampStore.database.write { database in
            try database.execute(
                sql: "UPDATE contextItem SET timestamp = -1 WHERE id = ?",
                arguments: [timestampNote.id.uuidString])
        }
        do {
            _ = try await timestampStore.searchNotes("budget")
            XCTFail("negative note timestamp must fail closed")
        } catch let error as StorageError {
            guard case .invalidPersistedValue = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testSearchIsBoundedDeterministicAndStableUnderConcurrentLoad() async throws {
        let store = try MeetingStore.inMemory()
        let meeting = meeting()
        try await store.save(meeting)
        let notes = (0..<2_000).map { index in
            ContextItem(
                meetingID: meeting.id,
                kind: .note,
                content: "budget checkpoint \(index)",
                timestamp: TimeInterval(index))
        }
        try await store.save(notes)

        let started = ContinuousClock.now
        let baseline = try await store.searchNotes("budget", limit: 12)
        let batches = try await withThrowingTaskGroup(
            of: [NoteSearchHit].self,
            returning: [[NoteSearchHit]].self
        ) { group in
            for _ in 0..<32 {
                group.addTask {
                    try await store.searchNotes("budget", limit: 12)
                }
            }
            var values: [[NoteSearchHit]] = []
            for try await value in group { values.append(value) }
            return values
        }
        let elapsed = started.duration(to: .now)

        XCTAssertEqual(baseline.count, 12)
        XCTAssertTrue(batches.allSatisfy { $0.map(\.noteID) == baseline.map(\.noteID) })
        XCTAssertLessThan(elapsed, .seconds(5))
    }

    func testLocalRetrievalPublishesEarlyLexicalThenAddsBilingualCandidates() async throws {
        let store = try MeetingStore.inMemory()
        let meeting = meeting()
        try await store.save(meeting)
        let english = ContextItem(
            meetingID: meeting.id,
            kind: .note,
            content: "budget owner",
            timestamp: 3)
        let spanish = ContextItem(
            meetingID: meeting.id,
            kind: .note,
            content: "presupuesto riesgo",
            timestamp: 4)
        try await store.save([english, spanish])
        let recorder = AskNoteSearchEvidenceRecorder()
        let retrieval = LocalAskNoteRetrieval(store: store)

        let result = try await retrieval.retrieve(
            question: "budget risk",
            limit: 6,
            onEvidence: { await recorder.receive($0) })
        let updates = await recorder.values

        XCTAssertEqual(updates.map(\.phase), [.lexical, .fused])
        XCTAssertEqual(updates.first?.citations.map(\.noteID), [english.id])
        XCTAssertEqual(Set(result.map(\.noteID)), [english.id, spanish.id])
        XCTAssertEqual(updates.last?.citations, result)
    }

    private func meeting(title: String = "Planning") -> Meeting {
        Meeting(
            title: title,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000))
    }

    private func temporaryRoot(named name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("portavoz-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true)
        return root
    }

    private func insertEnhancedNote(
        _ markdown: String,
        meetingID: MeetingID,
        store: MeetingStore
    ) async throws {
        let timestamp = Date(timeIntervalSince1970: 1_700_000_020)
        try await store.database.write { database in
            try database.execute(
                sql: """
                    INSERT INTO enhancedNote (
                        id, meetingID, markdown, language, inputFingerprint,
                        generationRunID, createdAt, updatedAt, deletedAt
                    ) VALUES (?, ?, ?, 'en', 'fingerprint', NULL, ?, ?, NULL)
                    """,
                arguments: [
                    UUID().uuidString,
                    meetingID.rawValue.uuidString,
                    markdown,
                    timestamp,
                    timestamp,
                ])
        }
    }
}

private actor AskNoteSearchEvidenceRecorder {
    private(set) var values: [AskNoteEvidenceUpdate] = []

    func receive(_ update: AskNoteEvidenceUpdate) {
        values.append(update)
    }
}
