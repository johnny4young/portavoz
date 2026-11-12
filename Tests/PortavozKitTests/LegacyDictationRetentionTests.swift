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
            let kept = try await insertDictation(store, at: now.addingTimeInterval(-Double(days) * 86_400 + 60))
            _ = try await insertDictation(store, at: now.addingTimeInterval(-Double(days) * 86_400 - 60))
            try await insertStatsDay(store, LegacyDictationRetentionTests.day(daysBefore: 365, from: now, calendar))
            try await insertStatsDay(store, LegacyDictationRetentionTests.day(daysBefore: 366, from: now, calendar))
            try await insertCounted(store, at: now.addingTimeInterval(-2 * 86_400 + 60))
            try await insertCounted(store, at: now.addingTimeInterval(-2 * 86_400 - 60))

            let removed = try await store.purgeExpiredLegacyDictationData(now: now, calendar: calendar)
            let left = try await store.legacyDictationRows()

            XCTAssertEqual(removed, LegacyDictationRows(history: 1, statsDays: 1, countedDictations: 1), "\(days)")
            XCTAssertEqual(left, LegacyDictationRows(history: 1, statsDays: 1, countedDictations: 1), "\(days)")
            let ids = try await store.database.read { try String.fetchAll($0, sql: "SELECT id FROM dictationRecord") }
            XCTAssertEqual(ids, [kept], "\(days)")
        }
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
