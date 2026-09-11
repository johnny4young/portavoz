import Foundation
import GRDB
import PortavozCore
import XCTest

@testable import StorageKit

final class SkillDisablementUpgradeTests: XCTestCase {
    func testPreviouslyCompletedV51StillOpensAndRejectsInvalidNewWrites() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("library.sqlite")
        do {
            let legacy = try DatabaseQueue(path: url.path)
            try StorageSchema.migrator().migrate(legacy, upTo: "v50")
            try await legacy.write { database in
                // Exact successful pre-repair v51 schema: it already enforces new writes.
                try database.execute(sql: "INSERT INTO skillDisablement VALUES ('recap-draft', 0)")
                try database.rename(table: "skillDisablement", to: "skillDisablement_v35")
                try database.create(table: "skillDisablement") { table in
                    table.primaryKey("skillID", .text).check(sql: """
                        length(CAST(skillID AS BLOB)) BETWEEN 1 AND 80 AND trim(skillID) = skillID
                        """)
                    table.column("disabledAt", .datetime).notNull()
                }
                try database.execute(sql: """
                    INSERT INTO skillDisablement SELECT * FROM skillDisablement_v35;
                    DROP TABLE skillDisablement_v35;
                    INSERT INTO grdb_migrations (identifier) VALUES ('v51');
                    """)
            }
        }
        let store = try MeetingStore(databaseURL: url)
        let policy = try await store.skillExecutionPolicy()
        XCTAssertEqual(policy.disabledSkillIDs, ["recap-draft"])
        try await assertNewWritesAreBounded(in: store)
    }

    func testOpeningPopulatedV50PreservesLegacyDenialsAndEnforcesNewWrites() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("library.sqlite")
        let meeting = Meeting(title: "Synthetic upgrade", startedAt: Date(timeIntervalSince1970: 100))
        let timestamp = Date(timeIntervalSince1970: 200)
        let keys = [
            "recap-draft", String(repeating: "a", count: 80), String(repeating: "é", count: 40),
            String(repeating: "é", count: 41), String(repeating: "💬", count: 21),
            String(repeating: "e\u{301}", count: 27)
        ]
        do {
            let legacy = try DatabaseQueue(path: url.path)
            try StorageSchema.migrator().migrate(legacy, upTo: "v50")
            try await legacy.write { database in
                try MeetingRecord(meeting, createdAt: timestamp, updatedAt: timestamp).insert(database)
                for key in keys {
                    // The pre-v51 writer admitted character counts, not byte counts.
                    XCTAssertLessThanOrEqual(key.count, 80)
                    try database.execute(
                        sql: "INSERT INTO skillDisablement (skillID, disabledAt) VALUES (?, ?)",
                        arguments: [key, timestamp])
                }
            }
        }

        for _ in 0..<2 {
            // Exercise the real library-open migration, including an idempotent reopen.
            let store = try MeetingStore(databaseURL: url)
            let policy = try await store.skillExecutionPolicy()
            XCTAssertEqual(policy.disabledSkillIDs, Set(keys))
            XCTAssertFalse(policy.isPaused)
            let detail = try await store.detail(meeting.id)
            XCTAssertEqual(detail?.meeting.title, meeting.title)
            try await store.database.read { database in
                XCTAssertEqual(try String.fetchOne(database, sql: "PRAGMA integrity_check"), "ok")
                XCTAssertTrue(try Row.fetchAll(database, sql: "PRAGMA foreign_key_check").isEmpty)
                XCTAssertEqual(
                    try Date.fetchAll(database, sql: "SELECT disabledAt FROM skillDisablement"),
                    Array(repeating: timestamp, count: keys.count))
            }
            try await assertNewWritesAreBounded(in: store)
        }
    }

    private func assertNewWritesAreBounded(in store: MeetingStore) async throws {
        let invalid = String(repeating: "界", count: 27)
        for sql in [
            "INSERT INTO skillDisablement (skillID, disabledAt) VALUES (?, 0)",
            "UPDATE skillDisablement SET skillID = ? WHERE skillID = 'recap-draft'"
        ] {
            do {
                try await store.database.write { database in
                    try database.execute(sql: sql, arguments: [invalid])
                }
                XCTFail("New identifiers must respect the byte bound, including UPDATE")
            } catch let error as DatabaseError {
                XCTAssertEqual(error.resultCode, .SQLITE_CONSTRAINT)
            }
        }
        let boundary = String(repeating: "界", count: 26) + "ab"
        try await store.setSkill(boundary, isEnabled: false)
        try await store.setSkill(boundary, isEnabled: true)
    }
}
