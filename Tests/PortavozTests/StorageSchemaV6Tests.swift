import Foundation
import GRDB
import PortavozCore
import XCTest

@testable import StorageKit

final class StorageSchemaV6Tests: XCTestCase {
    func testV5FixtureMigratesToCompleteV6WithoutChangingMeetingTruth() throws {
        let database = try DatabaseQueue()
        let migrator = StorageSchema.migrator()
        try migrator.migrate(database, upTo: "v5")

        let meetingID = UUID().uuidString
        let timestamp = Date(timeIntervalSince1970: 1_783_695_600)
        try database.write { db in
            try db.execute(
                sql: """
                    INSERT INTO meeting (
                        id, title, startedAt, endedAt, language, audioDirectory,
                        retention, visibility, createdAt, updatedAt, deletedAt
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL)
                    """,
                arguments: [
                    meetingID, "Legacy planning", timestamp, timestamp.addingTimeInterval(900),
                    "es", "Audio/legacy-planning", try MeetingRecord.encode(.keep),
                    "private", timestamp, timestamp,
                ])
        }

        try migrator.migrate(database, upTo: "v6")

        try database.read { db in
            XCTAssertEqual(StorageSchema.version, 6)
            let meeting = try XCTUnwrap(Row.fetchOne(
                db, sql: "SELECT * FROM meeting WHERE id = ?", arguments: [meetingID]))
            XCTAssertEqual(meeting["title"] as String, "Legacy planning")
            XCTAssertEqual(meeting["audioDirectory"] as String?, "Audio/legacy-planning")
            XCTAssertEqual(meeting["lifecycleState"] as String, "ready")
            XCTAssertEqual(meeting["transcriptRevision"] as Int, 0)
            XCTAssertNil(meeting["lastProcessingError"] as String?)

            let expectedColumns: [String: Set<String>] = [
                "audioAsset": [
                    "id", "meetingID", "channel", "role", "relativePath", "container", "codec",
                    "sampleRate", "channelCount", "durationSeconds", "byteCount", "sha256",
                    "healthStatus", "peakDBFS", "rmsDBFS", "sourceAssetID", "createdAt",
                    "updatedAt", "supersededAt", "deletedAt",
                ],
                "processingJob": [
                    "id", "meetingID", "kind", "inputFingerprint", "state", "priority", "progress",
                    "attempt", "maxAttempts", "notBefore", "leaseOwner", "leaseExpiresAt",
                    "errorCode", "errorMessage", "createdAt", "startedAt", "finishedAt", "updatedAt",
                ],
                "generationRun": [
                    "id", "meetingID", "kind", "providerID", "modelID", "modelRevision",
                    "inputFingerprint", "configJSON", "outputLanguage", "startedAt", "finishedAt",
                    "outcome", "metricsJSON",
                ],
                "outboxEvent": [
                    "id", "aggregateID", "kind", "idempotencyKey", "payloadJSON", "state",
                    "attempts", "nextAttemptAt", "createdAt", "deliveredAt",
                ],
                "meetingPreference": [
                    "meetingID", "transcriptLanguageMode", "transcriptLanguage",
                    "summaryLanguageMode", "summaryLanguage", "recipeID", "summaryEngineID",
                    "refineEngineID", "updatedAt",
                ],
            ]
            for (table, columns) in expectedColumns {
                XCTAssertTrue(try db.tableExists(table), "missing v6 table: \(table)")
                XCTAssertEqual(try Set(db.columns(in: table).map(\.name)), columns)
            }
            for table in ["segment", "summary", "companionCard"] {
                let columns = try Set(db.columns(in: table).map(\.name))
                XCTAssertTrue(
                    columns.contains("generationRunID"),
                    "\(table) must reference generation provenance")
            }
            let expectedForeignKeys: [String: Set<String>] = [
                "audioAsset": ["meeting", "audioAsset"],
                "processingJob": ["meeting"],
                "generationRun": ["meeting"],
                "meetingPreference": ["meeting"],
                "segment": ["meeting", "generationRun"],
                "summary": ["meeting", "generationRun"],
                "companionCard": ["meeting", "generationRun"],
            ]
            for (table, destinations) in expectedForeignKeys {
                let foreignKeys = try Row.fetchAll(
                    db, sql: "PRAGMA foreign_key_list(\(table))")
                XCTAssertEqual(
                    Set(foreignKeys.map { $0["table"] as String }), destinations,
                    "unexpected foreign-key contract for \(table)")
            }

            let applied = try String.fetchAll(
                db, sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid")
            XCTAssertEqual(applied, ["v1", "v2", "v3", "v4", "v5", "v6"])
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM audioAsset"), 0)
            XCTAssertTrue(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
        }

        // GRDB treats v6 as an unknown, already-applied identifier when an
        // older binary registers only v1-v5. None of these bodies may run.
        var legacyMigrator = DatabaseMigrator()
        for identifier in ["v1", "v2", "v3", "v4", "v5"] {
            legacyMigrator.registerMigration(identifier) { db in
                try db.execute(sql: "SELECT unknown_legacy_migration_body")
            }
        }
        try legacyMigrator.migrate(database)
    }

    func testV6RejectsInvalidLifecyclePathsPreferencesAndDuplicateJobs() throws {
        let database = try DatabaseQueue()
        try StorageSchema.migrator().migrate(database)

        let meetingID = UUID().uuidString
        let timestamp = Date(timeIntervalSince1970: 1_783_695_600)
        try database.write { db in
            let assetID = UUID().uuidString
            try db.execute(
                sql: """
                    INSERT INTO meeting (
                        id, title, startedAt, retention, visibility, createdAt, updatedAt
                    ) VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    meetingID, "Constraint fixture", timestamp,
                    try MeetingRecord.encode(.keep), "private", timestamp, timestamp,
                ])

            XCTAssertThrowsError(try db.execute(
                sql: "UPDATE meeting SET lifecycleState = 'unknown' WHERE id = ?",
                arguments: [meetingID]))

            try db.execute(
                sql: """
                    INSERT INTO audioAsset (
                        id, meetingID, channel, role, relativePath, createdAt, updatedAt
                    ) VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    assetID, meetingID, "microphone", "capture",
                    "Audio/fixture/microphone.partial", timestamp, timestamp,
                ])
            XCTAssertThrowsError(try db.execute(
                sql: """
                    INSERT INTO audioAsset (
                        id, meetingID, channel, role, relativePath, createdAt, updatedAt
                    ) VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    UUID().uuidString, meetingID, "system", "capture",
                    "/tmp/system.partial", timestamp, timestamp,
                ]))
            XCTAssertThrowsError(try db.execute(
                sql: "UPDATE audioAsset SET relativePath = ? WHERE meetingID = ?",
                arguments: ["Audio/fixture/../escape.caf", meetingID]))
            XCTAssertThrowsError(try db.execute(
                sql: "UPDATE audioAsset SET healthStatus = 'unknown' WHERE id = ?",
                arguments: [assetID]))
            XCTAssertThrowsError(try db.execute(
                sql: "UPDATE audioAsset SET sha256 = 'short' WHERE id = ?",
                arguments: [assetID]))

            let jobID = UUID().uuidString
            let jobArguments: StatementArguments = [
                jobID, meetingID, "refine", "revision-0", timestamp, timestamp,
            ]
            try db.execute(
                sql: """
                    INSERT INTO processingJob (
                        id, meetingID, kind, inputFingerprint, createdAt, updatedAt
                    ) VALUES (?, ?, ?, ?, ?, ?)
                    """,
                arguments: jobArguments)
            XCTAssertThrowsError(try db.execute(
                sql: """
                    INSERT INTO processingJob (
                        id, meetingID, kind, inputFingerprint, createdAt, updatedAt
                    ) VALUES (?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    UUID().uuidString, meetingID, "refine", "revision-0", timestamp, timestamp,
                ]))
            XCTAssertThrowsError(try db.execute(
                sql: "UPDATE processingJob SET progress = 1.1 WHERE id = ?",
                arguments: [jobID]))
            XCTAssertThrowsError(try db.execute(
                sql: "UPDATE processingJob SET state = 'unknown' WHERE id = ?",
                arguments: [jobID]))

            let runID = UUID().uuidString
            try db.execute(
                sql: """
                    INSERT INTO generationRun (
                        id, meetingID, kind, providerID, modelID, inputFingerprint,
                        configJSON, startedAt
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    runID, meetingID, "summary", "foundation-models", "system",
                    "revision-0", "{}", timestamp,
                ])
            XCTAssertThrowsError(try db.execute(
                sql: "UPDATE generationRun SET outcome = 'unknown' WHERE id = ?",
                arguments: [runID]))

            let eventID = UUID().uuidString
            try db.execute(
                sql: """
                    INSERT INTO outboxEvent (
                        id, aggregateID, kind, idempotencyKey, payloadJSON, createdAt
                    ) VALUES (?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    eventID, meetingID, "spotlight.index", "meeting:\(meetingID)",
                    "{}", timestamp,
                ])
            XCTAssertThrowsError(try db.execute(
                sql: "UPDATE outboxEvent SET state = 'unknown' WHERE id = ?",
                arguments: [eventID]))

            XCTAssertThrowsError(try db.execute(
                sql: """
                    INSERT INTO meetingPreference (
                        meetingID, transcriptLanguageMode, updatedAt
                    ) VALUES (?, 'fixed', ?)
                    """,
                arguments: [meetingID, timestamp]))
            XCTAssertThrowsError(try db.execute(
                sql: """
                    INSERT INTO meetingPreference (
                        meetingID, summaryLanguageMode, updatedAt
                    ) VALUES (?, 'fixed', ?)
                    """,
                arguments: [meetingID, timestamp]))
            try db.execute(
                sql: "INSERT INTO meetingPreference (meetingID, updatedAt) VALUES (?, ?)",
                arguments: [meetingID, timestamp])
            try db.execute(
                sql: """
                    UPDATE meetingPreference SET
                        transcriptLanguageMode = 'fixed', transcriptLanguage = 'es',
                        summaryLanguageMode = 'fixed', summaryLanguage = 'en'
                    WHERE meetingID = ?
                    """,
                arguments: [meetingID])
            XCTAssertThrowsError(try db.execute(
                sql: "UPDATE meetingPreference SET summaryLanguage = NULL WHERE meetingID = ?",
                arguments: [meetingID]))
        }
    }
}
