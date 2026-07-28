import GRDB
import PortavozCore
@testable import StorageKit
import XCTest

/// v15 (NOTES-001/D135): the enhanced-note artifact — atomic provenance,
/// in-place replacement, tombstones, and its sync-journal behavior.
final class EnhancedNotesStorageTests: XCTestCase {
    func testEnhancedNoteRoundtripReplacesInPlacePreservingIdentityAndCreatedAt() async throws {
        let store = try MeetingStore.inMemory()
        let meeting = Meeting(title: "Notas", startedAt: Date())
        try await store.save(meeting)

        let firstFinish = Date(timeIntervalSince1970: 100)
        let first = EnhancedNote(
            meetingID: meeting.id,
            markdown: "**revisar budget** — the transcript confirms Q3.",
            language: "es",
            inputFingerprint: "fp-1")
        try await store.saveEnhancedNote(
            first, generationRun: makeRun(meeting.id, finishedAt: firstFinish))

        let stored = try await store.enhancedNote(for: meeting.id)
        XCTAssertEqual(stored?.markdown, first.markdown)
        XCTAssertEqual(stored?.language, "es")
        XCTAssertEqual(stored?.inputFingerprint, "fp-1")
        XCTAssertEqual(stored?.createdAt, firstFinish)

        let second = EnhancedNote(
            meetingID: meeting.id,
            markdown: "**revisar budget** — updated with the refined transcript.",
            language: "en",
            inputFingerprint: "fp-2")
        try await store.saveEnhancedNote(
            second,
            generationRun: makeRun(
                meeting.id, finishedAt: Date(timeIntervalSince1970: 200)))

        let replaced = try await store.enhancedNote(for: meeting.id)
        XCTAssertEqual(replaced?.markdown, second.markdown)
        XCTAssertEqual(replaced?.inputFingerprint, "fp-2")
        XCTAssertEqual(
            replaced?.id, stored?.id,
            "regenerating replaces the document in place, never a second row")
        XCTAssertEqual(
            replaced?.createdAt, firstFinish,
            "in-place replacement preserves the original createdAt")
        let rowCount = try await store.database.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM enhancedNote")
        }
        XCTAssertEqual(rowCount, 1)
    }

    func testAtomicOverloadRejectsNonSucceededAndStandaloneRejectsSucceeded() async throws {
        let store = try MeetingStore.inMemory()
        let meeting = Meeting(title: "Notas", startedAt: Date())
        try await store.save(meeting)
        let note = EnhancedNote(
            meetingID: meeting.id,
            markdown: "# doc",
            language: "en",
            inputFingerprint: "fp")

        do {
            try await store.saveEnhancedNote(
                note, generationRun: makeRun(meeting.id, outcome: .failed))
            XCTFail("a failed run must not commit an artifact")
        } catch {}
        do {
            try await store.saveGenerationRun(
                makeRun(meeting.id, outcome: .succeeded))
            XCTFail("a standalone succeeded run must be rejected")
        } catch {}
        let runCount = try await store.database.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM generationRun")
        }
        XCTAssertEqual(
            runCount, 0,
            "rejected envelopes must leave no provenance rows behind")
        let stored = try await store.enhancedNote(for: meeting.id)
        XCTAssertNil(stored)
    }

    func testTombstoneHidesTheDocumentAndRegenerationResurrectsTheRow() async throws {
        let store = try MeetingStore.inMemory()
        let meeting = Meeting(title: "Notas", startedAt: Date())
        try await store.save(meeting)
        let note = EnhancedNote(
            meetingID: meeting.id,
            markdown: "# doc",
            language: "en",
            inputFingerprint: "fp-1")
        try await store.saveEnhancedNote(note, generationRun: makeRun(meeting.id))

        try await store.deleteEnhancedNote(for: meeting.id)
        let hidden = try await store.enhancedNote(for: meeting.id)
        XCTAssertNil(hidden, "a tombstoned document must not load")
        let rowCount = try await store.database.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM enhancedNote")
        }
        XCTAssertEqual(rowCount, 1, "the tombstone survives as a row for future sync")

        let regenerated = EnhancedNote(
            meetingID: meeting.id,
            markdown: "# doc v2",
            language: "en",
            inputFingerprint: "fp-2")
        try await store.saveEnhancedNote(regenerated, generationRun: makeRun(meeting.id))
        let restored = try await store.enhancedNote(for: meeting.id)
        XCTAssertEqual(
            restored?.markdown, "# doc v2",
            "regenerating after delete must resurrect the unique row")
    }

    func testRunPruningSeversProvenanceWithoutTouchingTheDocument() async throws {
        let store = try MeetingStore.inMemory()
        let meeting = Meeting(title: "Notas", startedAt: Date())
        try await store.save(meeting)
        let run = makeRun(meeting.id)
        let note = EnhancedNote(
            meetingID: meeting.id,
            markdown: "# doc",
            language: "en",
            inputFingerprint: "fp")
        try await store.saveEnhancedNote(note, generationRun: run)

        try await store.database.write { db in
            _ = try GenerationRunRecord.deleteAll(db)
        }
        let severedRunID = try await store.database.read { db in
            try String.fetchOne(db, sql: "SELECT generationRunID FROM enhancedNote")
        }
        XCTAssertNil(severedRunID, "run pruning must sever provenance, not fail")
        let markdown = try await store.database.read { db in
            try String.fetchOne(db, sql: "SELECT markdown FROM enhancedNote")
        }
        XCTAssertEqual(markdown, "# doc", "the document itself must survive pruning")
    }

    func testSyncTriggersQueuePortableChangesButNotDeviceLocalProvenance() async throws {
        let store = try MeetingStore.inMemory()
        let meeting = Meeting(title: "Notas", startedAt: Date())
        try await store.save(meeting)
        try await acknowledgeAll(in: store)

        let note = EnhancedNote(
            meetingID: meeting.id,
            markdown: "# doc",
            language: "en",
            inputFingerprint: "fp")
        try await store.saveEnhancedNote(note, generationRun: makeRun(meeting.id))
        var pending = try await store.pendingMeetingSyncChanges()
        XCTAssertEqual(
            pending.count, 1,
            "inserting the enhanced note must queue its owning meeting")
        try await acknowledgeAll(in: store)

        try await store.database.write { db in
            try db.execute(sql: "UPDATE enhancedNote SET generationRunID = NULL")
        }
        pending = try await store.pendingMeetingSyncChanges()
        XCTAssertTrue(
            pending.isEmpty,
            "generation provenance is device-local and must not schedule sync")

        try await store.database.write { db in
            try db.execute(sql: "UPDATE enhancedNote SET markdown = '# edited'")
        }
        pending = try await store.pendingMeetingSyncChanges()
        XCTAssertEqual(pending.count, 1, "portable content changes must queue sync")
        try await acknowledgeAll(in: store)

        try await store.deleteEnhancedNote(for: meeting.id)
        pending = try await store.pendingMeetingSyncChanges()
        XCTAssertEqual(pending.count, 1, "the tombstone itself is a portable change")
    }

    func testReviewNotesProjectionKeepsOnlyTypedNotes() async throws {
        let store = try MeetingStore.inMemory()
        let meeting = Meeting(title: "Notas", startedAt: Date())
        try await store.save(meeting)
        try await store.save([
            ContextItem(
                meetingID: meeting.id, kind: .note,
                content: "revisar budget", timestamp: 10),
            ContextItem(
                meetingID: meeting.id, kind: .link,
                content: "https://example.com", timestamp: 20)
        ])

        let projected = try await store.database.read { db in
            try MeetingStore.fetchMeetingReviewNotes(meeting.id, in: db)
        }
        XCTAssertEqual(
            projected.items.map(\.content), ["revisar budget"],
            "links and other kinds have their own surfaces, not My notes")
        XCTAssertNil(projected.enhanced)
    }

    func testV15SchemaShapeColumnsTriggersAndConstraints() throws {
        let database = try DatabaseQueue()
        let migrator = StorageSchema.migrator()
        try migrator.migrate(database)

        try database.read { db in
            XCTAssertEqual(
                try Set(db.columns(in: "enhancedNote").map(\.name)),
                [
                    "id", "meetingID", "markdown", "language", "inputFingerprint",
                    "generationRunID", "createdAt", "updatedAt", "deletedAt",
                ])
            let triggers = try String.fetchAll(
                db,
                sql: """
                    SELECT name FROM sqlite_master
                     WHERE type = 'trigger' AND name LIKE 'enhancedNote_sync_%'
                     ORDER BY name
                    """)
            XCTAssertEqual(
                triggers,
                ["enhancedNote_sync_ad", "enhancedNote_sync_ai", "enhancedNote_sync_au"])
        }
        try database.write { db in
            XCTAssertThrowsError(try db.execute(
                sql: """
                    INSERT INTO enhancedNote
                        (id, meetingID, markdown, language, inputFingerprint,
                         createdAt, updatedAt)
                    VALUES ('x', 'missing-meeting', ' ', 'en', 'fp',
                            CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
                    """),
                "blank markdown and a dangling meeting must both be rejected")
        }
    }

    private func makeRun(
        _ meetingID: MeetingID,
        outcome: GenerationRunOutcome = .succeeded,
        finishedAt: Date = Date(timeIntervalSince1970: 100)
    ) -> GenerationRun {
        GenerationRun(
            id: GenerationRunID(),
            meetingID: meetingID,
            kind: .enhancedNotes,
            providerID: "test-provider",
            modelID: "test-model",
            modelRevision: nil,
            inputFingerprint: "fp",
            configJSON: "{}",
            outputLanguage: "en",
            startedAt: Date(timeIntervalSince1970: 90),
            finishedAt: finishedAt,
            outcome: outcome,
            metricsJSON: nil)
    }

    private func acknowledgeAll(in store: MeetingStore) async throws {
        for change in try await store.pendingMeetingSyncChanges() {
            try await store.acknowledgeMeetingSync(change)
        }
    }
}
