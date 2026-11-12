import Foundation
import GRDB
import PortavozCore
import XCTest

@testable import StorageKit

// Libraries that hold dictation data, from the first dictation schema (v54) to the
// current one. Dictation rows are written and read with SQL only, so these tests
// name no dictation type and stay the upgrade criterion while that code leaves.
extension StorageUpgradeTests {
    func testEveryDictationSchemaUpgradesWithNotesSearchKeysAndEgressIntact() async throws {
        for base in 54...StorageSchema.version {
            try await assertDictationLibraryUpgrade(from: base)
        }
    }

    func testRemovingLegacyDictationRowsLeavesCopiedMeetingNotesIntact() async throws {
        // From v57 on a library holds note links; bases before v59 also pass through its table rebuild.
        for base in 57...StorageSchema.version {
            try await assertLegacyDictationPurgeKeepsNotes(from: base)
        }
    }

    private func assertLegacyDictationPurgeKeepsNotes(from base: Int) async throws {
        let url = try legacyDictationDatabaseURL(named: "dictation-purge-v\(base)")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let fixture = try seedLegacyDictationLibrary(at: url, upTo: base)
        let store = try MeetingStore(databaseURL: url)

        try await store.database.write { database in
            for table in ["dictationStatsCounted", "dictationStatsDay", "dictationRecord"] {
                try database.execute(sql: "DELETE FROM \(table)")
            }
        }

        let notes = try await store.contextItems(for: fixture.meetingID).filter { $0.kind == .note }
        XCTAssertEqual(Set(notes.map(\.content)), [fixture.ownNote, fixture.copiedNote], "v\(base)")
        // An FTS5 integrity check is issued as a write, though it changes nothing.
        try await store.database.write { database in
            XCTAssertEqual(try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM dictationMeetingNote"), 0, "v\(base)")
            XCTAssertTrue(try Row.fetchAll(database, sql: "PRAGMA foreign_key_check").isEmpty, "v\(base)")
            try Self.assertSearchIndexesHealthy(in: database)
        }
        let journal = try await store.globalDataEgressEvents()
        XCTAssertEqual(
            journal.map(\.operation.rawValue),
            base >= 59 ? ["ask-answer-generation", "dictation-polish"] : ["ask-answer-generation"], "v\(base)")
    }

    private struct LegacyDictationFixture {
        let base: Int
        let meetingID: MeetingID
        let ownNote: String
        let copiedNote: String
        let copiedNoteID: UUID
        let rows: [String: [String]]
        let seededAt: Date
        let copiedDictationID: String
    }

    private func assertDictationLibraryUpgrade(from base: Int) async throws {
        let url = try legacyDictationDatabaseURL(named: "dictation-v\(base)")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let fixture = try seedLegacyDictationLibrary(at: url, upTo: base)

        var store: MeetingStore? = try MeetingStore(databaseURL: url)
        try await assertLegacyDictationLibrary(fixture, in: try XCTUnwrap(store))
        store = nil
        store = try MeetingStore(databaseURL: url)
        try await assertLegacyDictationLibrary(fixture, in: try XCTUnwrap(store))
    }

    private func legacyDictationDatabaseURL(named name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("portavoz-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.appendingPathComponent("portavoz.sqlite")
    }

    // Recent dates, so a retention purge at open, once one exists, keeps every row.
    private func seedLegacyDictationLibrary(at url: URL, upTo base: Int) throws -> LegacyDictationFixture {
        let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970)).addingTimeInterval(-3_600)
        let meeting = Meeting(title: "Planning v\(base)", startedAt: now.addingTimeInterval(-1_800), endedAt: now)
        let ownNote = ContextItem(meetingID: meeting.id, kind: .note, content: "Nota propia v\(base).", timestamp: 30)
        let copiedNote = ContextItem(
            meetingID: meeting.id, kind: .note, content: "Revisar el presupuesto antes del viernes.", timestamp: 600)
        var dictations = [
            UUID().uuidString: "Revisar el presupuesto antes del viernes.",
            UUID().uuidString: "Send the quarterly report to Ana.",
        ]
        let polished = UUID().uuidString
        if base >= 59 { dictations[polished] = "Agenda the design review for Monday." }
        let copiedID = dictations.first { $0.value == copiedNote.content }!.key

        var rows: [String: [String]] = [:]
        let legacy = try DatabaseQueue(path: url.path)
        try StorageSchema.migrator().migrate(legacy, upTo: "v\(base)")
        try legacy.write { db in
            // Only columns that exist at v54, so a later schema cannot break the seed.
            try db.execute(
                sql: """
                    INSERT INTO meeting (
                        id, title, startedAt, endedAt, language, audioDirectory, retention, visibility,
                        lifecycleState, transcriptRevision, createdAt, updatedAt)
                    VALUES (?, ?, ?, ?, 'es', NULL, ?, ?, ?, 0, ?, ?)
                    """,
                arguments: [meeting.id.rawValue.uuidString, meeting.title, meeting.startedAt, meeting.endedAt,
                            try MeetingRecord.encode(.keep), meeting.visibility, meeting.lifecycleState.rawValue,
                            now, now])
            for note in [ownNote, copiedNote] {
                try db.execute(
                    sql: """
                        INSERT INTO contextItem (id, meetingID, kind, content, timestamp, createdAt, updatedAt)
                        VALUES (?, ?, 'note', ?, ?, ?, ?)
                        """,
                    arguments: [note.id.uuidString, meeting.id.rawValue.uuidString, note.content, note.timestamp,
                                now, now])
            }
            try db.execute(
                sql: """
                    INSERT INTO globalDataEgressEvent (
                        id, operation, destinationScope, destinationHost, dataClassification,
                        consentSource, providerID, modelID, attemptedAt)
                    VALUES (?, 'ask-answer-generation', 'local-device', 'localhost', 'meeting-answer-material',
                        'summary-engine-settings', 'localhost', 'qwen-local', ?)
                    """,
                arguments: [UUID().uuidString, now])
            try db.execute(sql: "UPDATE dictationHistoryPolicy SET isEnabled = 1, keepsOriginal = 1, retentionDays = 90")
            if base >= 56 { try db.execute(sql: "UPDATE dictationHistoryPolicy SET exposesToAgents = 1") }
            for (offset, entry) in dictations.sorted(by: { $0.key < $1.key }).enumerated() {
                let mode = entry.key == polished ? "polish" : offset.isMultiple(of: 2) ? "clean" : "literal"
                let original = mode == "literal" ? nil : "eh \(entry.value)"
                rows[entry.key] = [entry.value, original ?? "<null>", mode, String(-offset * 60), "2400", "es",
                                   "parakeet-v3", "Notes", "com.apple.Notes", "verified"]
                try db.execute(
                    sql: """
                        INSERT INTO dictationRecord (
                            id, createdAt, durationMs, text, originalText, mode, language,
                            engine, applicationName, applicationBundleID, delivery)
                        VALUES (?, ?, 2400, ?, ?, ?, 'es', 'parakeet-v3', 'Notes', 'com.apple.Notes', 'verified')
                        """,
                    arguments: [entry.key, now.addingTimeInterval(Double(-offset * 60)), entry.value, original, mode])
            }
            if base >= 57 {
                try db.execute(
                    sql: "INSERT INTO dictationMeetingNote (dictationID, meetingID, contextItemID, createdAt) VALUES (?, ?, ?, ?)",
                    arguments: [copiedID, meeting.id.rawValue.uuidString, copiedNote.id.uuidString, now])
            }
            if base >= 58 {
                let parts = Calendar.current.dateComponents([.year, .month, .day], from: now)
                let day = String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
                try db.execute(sql: "UPDATE dictationStatsPolicy SET isEnabled = 1")
                try db.execute(
                    sql: """
                        INSERT INTO dictationStatsDay (day, applicationName, dictations, words, spokenMs, notDelivered)
                        VALUES (?, 'Notes', 2, 12, 4800, 0)
                        """,
                    arguments: [day])
                try db.execute(
                    sql: """
                        INSERT INTO dictationStatsCounted (dictationID, day, applicationName, delivered, countedAt)
                        VALUES (?, ?, 'Notes', 1, ?)
                        """,
                    arguments: [copiedID, day, now])
            }
            if base >= 59 {
                try db.execute(
                    sql: """
                        INSERT INTO globalDataEgressEvent (
                            id, operation, destinationScope, destinationHost, dataClassification,
                            consentSource, providerID, modelID, attemptedAt)
                        VALUES (?, 'dictation-polish', 'local-device', 'localhost', 'dictation-text',
                            'dictation-polish-mode', 'localhost', 'qwen-local', ?)
                        """,
                    arguments: [UUID().uuidString, now.addingTimeInterval(1)])
            }
        }
        try legacy.close()
        return LegacyDictationFixture(
            base: base, meetingID: meeting.id, ownNote: ownNote.content, copiedNote: copiedNote.content,
            copiedNoteID: copiedNote.id, rows: rows, seededAt: now, copiedDictationID: copiedID)
    }

    private func assertLegacyDictationLibrary(
        _ fixture: LegacyDictationFixture, in store: MeetingStore,
        file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let base = fixture.base
        let notes = try await store.contextItems(for: fixture.meetingID).filter { $0.kind == .note }
        XCTAssertEqual(Set(notes.map(\.content)), [fixture.ownNote, fixture.copiedNote], "v\(base)", file: file, line: line)
        let journal = try await store.globalDataEgressEvents()
        XCTAssertEqual(
            journal.map(\.operation.rawValue),
            base >= 59 ? ["ask-answer-generation", "dictation-polish"] : ["ask-answer-generation"],
            "v\(base)", file: file, line: line)

        try await store.database.write { database in
            XCTAssertEqual(
                try String.fetchAll(database, sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid"),
                (1...StorageSchema.version).map { "v\($0)" }, "v\(base)", file: file, line: line)
            XCTAssertEqual(try String.fetchOne(database, sql: "PRAGMA integrity_check"), "ok", file: file, line: line)
            XCTAssertTrue(
                try Row.fetchAll(database, sql: "PRAGMA foreign_key_check").isEmpty, "v\(base)", file: file, line: line)
            try Self.assertSearchIndexesHealthy(in: database, file: file, line: line)

            // The v59 rebuild copies every column; compare whole rows, not just the text.
            let rows = try Row.fetchAll(
                database,
                sql: """
                    SELECT id, text, originalText, mode, createdAt, CAST(durationMs AS TEXT) AS durationMs, language, engine,
                           applicationName, applicationBundleID, delivery
                    FROM dictationRecord
                    """)
            XCTAssertEqual(
                Dictionary(uniqueKeysWithValues: rows.map { row in
                    let createdAt: Date = row["createdAt"]
                    let original: String? = row["originalText"]
                    let columns = ["durationMs", "language", "engine", "applicationName", "applicationBundleID", "delivery"]
                    return (row["id"] as String, [row["text"] as String, original ?? "<null>", row["mode"] as String,
                                                  String(Int(createdAt.timeIntervalSince(fixture.seededAt)))]
                                + columns.map { (row[$0] as String?) ?? "<null>" })
                }),
                fixture.rows, "v\(base)", file: file, line: line)
            let found = try String.fetchAll(
                database,
                sql: """
                    SELECT dictationRecord.id FROM dictationRecordSearch
                    JOIN dictationRecord ON dictationRecord.rowid = dictationRecordSearch.rowid
                    WHERE dictationRecordSearch MATCH 'presupuesto'
                    """)
            XCTAssertEqual(found.count, 1, "v\(base): the dictation index follows the upgrade", file: file, line: line)

            let policy = try XCTUnwrap(Row.fetchOne(database, sql: "SELECT * FROM dictationHistoryPolicy"))
            XCTAssertEqual(policy["isEnabled"] as Bool, true, file: file, line: line)
            XCTAssertEqual(policy["keepsOriginal"] as Bool, true, file: file, line: line)
            XCTAssertEqual(policy["retentionDays"] as Int, 90, file: file, line: line)
            XCTAssertEqual(policy["exposesToAgents"] as Bool, base >= 56, "v\(base)", file: file, line: line)

            // The v59 drop-and-rename must leave every link key pointing at its table with its cascade.
            let keys = try Row.fetchAll(
                database, sql: "SELECT \"table\", on_delete FROM pragma_foreign_key_list('dictationMeetingNote')")
            XCTAssertEqual(
                Set(keys.map { "\($0["table"] as String):\($0["on_delete"] as String)" }),
                ["dictationRecord:CASCADE", "meeting:CASCADE", "contextItem:CASCADE"], "v\(base)", file: file, line: line)
            let links = try Row.fetchAll(database, sql: "SELECT contextItemID FROM dictationMeetingNote")
            XCTAssertEqual(
                links.map { $0["contextItemID"] as String },
                base >= 57 ? [fixture.copiedNoteID.uuidString] : [], "v\(base)", file: file, line: line)
            XCTAssertEqual(
                try Int.fetchOne(database, sql: "SELECT COALESCE(SUM(dictations), 0) FROM dictationStatsDay"),
                base >= 58 ? 2 : 0, "v\(base)", file: file, line: line)
            XCTAssertEqual(
                try Bool.fetchOne(database, sql: "SELECT isEnabled FROM dictationStatsPolicy"),
                base >= 58, "v\(base)", file: file, line: line)
            XCTAssertEqual(
                try String.fetchAll(database, sql: "SELECT dictationID FROM dictationStatsCounted"),
                base >= 58 ? [fixture.copiedDictationID] : [], "v\(base)", file: file, line: line)
        }
    }

    private static func assertSearchIndexesHealthy(
        in database: Database, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let tables = try String.fetchAll(
            database,
            sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND sql LIKE 'CREATE VIRTUAL TABLE%USING fts5%'")
        XCTAssertTrue(tables.contains("dictationRecordSearch"), file: file, line: line)
        for table in tables {
            // rank 1 also compares an external-content index with its table; without it a stale index passes.
            XCTAssertNoThrow(
                try database.execute(sql: "INSERT INTO \(table)(\(table), rank) VALUES ('integrity-check', 1)"),
                table, file: file, line: line)
        }
    }
}
