import Foundation
import GRDB
import PortavozCore
import XCTest

@testable import StorageKit

// Legacy dictation rows are seeded with SQL only, like the upgrade fixtures, so these tests
// outlive the dictation types.
final class LegacyDictationRetentionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Bogota") ?? .current
        return calendar
    }

    func testPurgeKeepsEachStoredHistoryHorizonAndTheStatsYear() async throws {
        for days in [7, 30, 90] {
            let store = try MeetingStore.inMemory()
            try await store.database.write { db in
                try db.execute(sql: "UPDATE dictationHistoryPolicy SET retentionDays = ?", arguments: [days])
            }
            // Exactly at the cutoff stays: only older rows go, as today.
            let kept = try await insertDictation(store, at: now.addingTimeInterval(-Double(days) * 86_400))
            _ = try await insertDictation(store, at: now.addingTimeInterval(-Double(days) * 86_400 - 60))
            try await insertStatsDay(store, LegacyDictationRetentionTests.day(daysBefore: 365, from: now, calendar))
            try await insertStatsDay(store, LegacyDictationRetentionTests.day(daysBefore: 366, from: now, calendar))
            try await insertCounted(store, at: now.addingTimeInterval(-2 * 86_400))
            try await insertCounted(store, at: now.addingTimeInterval(-2 * 86_400 - 60))

            let removed = try await store.purgeExpiredLegacyDictationData(now: now, calendar: calendar)
            let left = try await store.legacyDictationRows()

            XCTAssertEqual(removed, LegacyDictationRows(history: 1, statsDays: 1, countedDictations: 1), "\(days)")
            XCTAssertEqual(left, LegacyDictationRows(history: 1, statsDays: 1, countedDictations: 1), "\(days)")
            let ids = try await store.database.read { try String.fetchAll($0, sql: "SELECT id FROM dictationRecord") }
            XCTAssertEqual(ids, [kept], "\(days)")
        }
    }

    func testTheStatsYearCountsLocalDaysAcrossDaylightSaving() async throws {
        // 00:30 EDT on 13 Mar 2028; 365 local days back is 14 Mar 2027, still EST. Counting
        // 365 x 24 h instead would land on the 13th and keep a day that has expired.
        var newYork = Calendar(identifier: .gregorian)
        newYork.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2028-03-13T04:30:00Z"))
        let store = try MeetingStore.inMemory()
        try await insertStatsDay(store, "2027-03-14")
        try await insertStatsDay(store, "2027-03-13")

        try await store.purgeExpiredLegacyDictationData(now: now, calendar: newYork)

        let days = try await store.database.read { try String.fetchAll($0, sql: "SELECT day FROM dictationStatsDay") }
        XCTAssertEqual(days, ["2027-03-14"])
    }

    func testPurgeExpiresStatsEvenWithCountingTurnedOff() async throws {
        let store = try MeetingStore.inMemory()
        try await store.database.write { db in try db.execute(sql: "UPDATE dictationStatsPolicy SET isEnabled = 0") }
        try await insertStatsDay(store, LegacyDictationRetentionTests.day(daysBefore: 366, from: now, calendar))

        let removed = try await store.purgeExpiredLegacyDictationData(now: now, calendar: calendar)

        XCTAssertEqual(removed.statsDays, 1, "nothing shows these totals once the dictation code is gone")
    }

    func testPurgeIsIdempotentAndKeepsCopiedNotes() async throws {
        let store = try MeetingStore.inMemory()
        let meeting = Meeting(title: "Weekly", startedAt: now.addingTimeInterval(-90 * 86_400),
                              endedAt: now.addingTimeInterval(-90 * 86_400 + 1_800))
        try await store.save(meeting)
        let note = ContextItem(meetingID: meeting.id, kind: .note, content: "Revisar el presupuesto.", timestamp: 60)
        let expired = try await insertDictation(store, at: now.addingTimeInterval(-60 * 86_400))
        try await store.database.write { [now] db in
            try db.execute(
                sql: """
                    INSERT INTO contextItem (id, meetingID, kind, content, timestamp, createdAt, updatedAt)
                    VALUES (?, ?, 'note', ?, 60, ?, ?)
                    """,
                arguments: [note.id.uuidString, meeting.id.rawValue.uuidString, note.content, now, now])
            try db.execute(
                sql: "INSERT INTO dictationMeetingNote (dictationID, meetingID, contextItemID, createdAt) VALUES (?, ?, ?, ?)",
                arguments: [expired, meeting.id.rawValue.uuidString, note.id.uuidString, now])
        }

        let first = try await store.purgeExpiredLegacyDictationData(now: now, calendar: calendar)
        let second = try await store.purgeExpiredLegacyDictationData(now: now, calendar: calendar)
        let notes = try await store.contextItems(for: meeting.id).filter { $0.kind == .note }

        XCTAssertEqual(first.history, 1)
        XCTAssertEqual(second, .none)
        XCTAssertEqual(notes.map(\.content), ["Revisar el presupuesto."])
        try await store.database.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM dictationMeetingNote"), 0)
            XCTAssertTrue(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
        }
    }

    func testAFailedPurgeRemovesNothing() async throws {
        let store = try MeetingStore.inMemory()
        _ = try await insertDictation(store, at: now.addingTimeInterval(-400 * 86_400))
        try await insertCounted(store, at: now.addingTimeInterval(-10 * 86_400))
        try await store.database.write { db in
            try db.execute(sql: """
                CREATE TRIGGER failCountedDelete BEFORE DELETE ON dictationStatsCounted
                BEGIN SELECT RAISE(ABORT, 'synthetic failure'); END
                """)
        }

        do {
            try await store.purgeExpiredLegacyDictationData(now: now, calendar: calendar)
            XCTFail("the failure must reach the caller")
        } catch {
            XCTAssertTrue("\(error)".contains("synthetic failure"), "\(error)")
        }
        let left = try await store.legacyDictationRows()
        XCTAssertEqual(left, LegacyDictationRows(history: 1, statsDays: 0, countedDictations: 1))
    }

    func testAMissingPolicyIsAVisibleFailure() async throws {
        let store = try MeetingStore.inMemory()
        _ = try await insertDictation(store, at: now.addingTimeInterval(-400 * 86_400))
        try await store.database.write { db in try db.execute(sql: "DELETE FROM dictationHistoryPolicy") }

        do {
            try await store.purgeExpiredLegacyDictationData(now: now, calendar: calendar)
            XCTFail("a missing policy must not read as a default horizon")
        } catch StorageError.missingLegacyDictationPolicy {}
        do {
            try await store.deleteAllLegacyDictationData()
            XCTFail("a missing policy must fail the delete")
        } catch StorageError.missingLegacyDictationPolicy {}
        let left = try await store.legacyDictationRows()
        XCTAssertEqual(left.history, 1, "a failed delete rolls back")
    }

    func testDeleteAllRemovesEveryLegacyRowAndAdvancesTheGeneration() async throws {
        let store = try MeetingStore.inMemory()
        _ = try await insertDictation(store, at: now)
        try await insertStatsDay(store, LegacyDictationRetentionTests.day(daysBefore: 0, from: now, calendar))
        try await insertCounted(store, at: now)
        let before = try await store.legacyDictationRows()

        let removed = try await store.deleteAllLegacyDictationData()
        let after = try await store.legacyDictationRows()
        let generation = try await store.database.read {
            try Int.fetchOne($0, sql: "SELECT generation FROM dictationHistoryPolicy")
        }

        XCTAssertEqual(before, LegacyDictationRows(history: 1, statsDays: 1, countedDictations: 1))
        XCTAssertEqual(removed, before)
        XCTAssertTrue(after.isEmpty)
        XCTAssertEqual(generation, 1)
    }

    func testDeleteAllKeepsCopiedNotesAndRemovesOnlyTheirLinks() async throws {
        let store = try MeetingStore.inMemory()
        let meeting = Meeting(title: "Weekly", startedAt: now, endedAt: now.addingTimeInterval(1_800))
        try await store.save(meeting)
        let note = ContextItem(meetingID: meeting.id, kind: .note, content: "Se queda.", timestamp: 60)
        let dictation = try await insertDictation(store, at: now)
        try await store.database.write { [now] db in
            try db.execute(
                sql: """
                    INSERT INTO contextItem (id, meetingID, kind, content, timestamp, createdAt, updatedAt)
                    VALUES (?, ?, 'note', ?, 60, ?, ?)
                    """,
                arguments: [note.id.uuidString, meeting.id.rawValue.uuidString, note.content, now, now])
            try db.execute(
                sql: "INSERT INTO dictationMeetingNote (dictationID, meetingID, contextItemID, createdAt) VALUES (?, ?, ?, ?)",
                arguments: [dictation, meeting.id.rawValue.uuidString, note.id.uuidString, now])
        }

        try await store.deleteAllLegacyDictationData()
        let notes = try await store.contextItems(for: meeting.id).filter { $0.kind == .note }

        XCTAssertEqual(notes.map(\.content), ["Se queda."], "the note belongs to the meeting")
        try await store.database.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM dictationMeetingNote"), 0)
            XCTAssertTrue(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
        }
    }

    // The frozen migrations seed every consent off; the purge horizon starts at 30 days.
    func testFrozenMigrationsSeedEveryDictationConsentOff() throws {
        let database = try DatabaseQueue()
        try StorageSchema.migrator().migrate(database, upTo: "v54")
        try database.read { db in
            let policy = try XCTUnwrap(try Row.fetchOne(db, sql: "SELECT * FROM dictationHistoryPolicy"))
            XCTAssertEqual(policy["isEnabled"], false)
            XCTAssertEqual(policy["keepsOriginal"], false)
            XCTAssertEqual(policy["retentionDays"], 30)
            XCTAssertEqual(policy["generation"], 0)
            XCTAssertEqual(try Set(db.columns(in: "dictationRecord").map(\.name)), [
                "id", "createdAt", "durationMs", "text", "originalText", "mode", "language",
                "engine", "applicationName", "applicationBundleID", "delivery"
            ])
        }
        try database.write { try $0.execute(sql: "UPDATE dictationHistoryPolicy SET isEnabled = 1 WHERE id = 1") }
        try StorageSchema.migrator().migrate(database, upTo: "v58")
        try database.read { db in
            let policy = try XCTUnwrap(try Row.fetchOne(db, sql: "SELECT * FROM dictationHistoryPolicy"))
            XCTAssertEqual(policy["isEnabled"], true, "v56 keeps the history consent")
            XCTAssertEqual(policy["exposesToAgents"], false)
            XCTAssertEqual(try Bool.fetchOne(db, sql: "SELECT isEnabled FROM dictationStatsPolicy WHERE id = 1"), false)
        }
    }

    private func insertDictation(_ store: MeetingStore, at createdAt: Date) async throws -> String {
        let id = UUID().uuidString
        try await store.database.write { db in
            try db.execute(
                sql: """
                    INSERT INTO dictationRecord (
                        id, createdAt, durationMs, text, mode, engine, delivery)
                    VALUES (?, ?, 1200, 'Hola.', 'literal', 'parakeet-v3', 'verified')
                    """,
                arguments: [id, createdAt])
        }
        return id
    }

    private func insertStatsDay(_ store: MeetingStore, _ day: String) async throws {
        try await store.database.write { db in
            try db.execute(
                sql: """
                    INSERT INTO dictationStatsDay (day, applicationName, dictations, words, spokenMs, notDelivered)
                    VALUES (?, 'Notes', 1, 3, 1200, 0)
                    """,
                arguments: [day])
        }
    }

    private func insertCounted(_ store: MeetingStore, at countedAt: Date) async throws {
        try await store.database.write { db in
            try db.execute(
                sql: """
                    INSERT INTO dictationStatsCounted (dictationID, day, applicationName, delivered, countedAt)
                    VALUES (?, '2027-01-15', 'Notes', 1, ?)
                    """,
                arguments: [UUID().uuidString, countedAt])
        }
    }

    private static func day(daysBefore days: Int, from date: Date, _ calendar: Calendar) -> String {
        let shifted = calendar.date(byAdding: .day, value: -days, to: date) ?? date
        let parts = calendar.dateComponents([.year, .month, .day], from: shifted)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}
