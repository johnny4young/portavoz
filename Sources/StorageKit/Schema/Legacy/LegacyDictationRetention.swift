import Foundation
import GRDB

/// Rows that legacy dictation data still holds, or that one call removed.
public struct LegacyDictationRows: Equatable, Sendable {
    public var history: Int
    public var statsDays: Int
    public var countedDictations: Int

    public static let none = Self(history: 0, statsDays: 0, countedDictations: 0)

    public var isEmpty: Bool { self == .none }
}

/// Dictation data an existing library keeps after the dictation code is gone. It is read and
/// written with SQL only, keeps today's horizons whatever the consent rows say, and never
/// touches meeting notes: deleting a dictation cascades only its note link.
extension MeetingStore {
    // Today's horizons, frozen: history follows the stored 7/30/90-day choice, daily stats keep
    // a year, and the retry dedupe keeps two days. A shorter horizon is a policy change.
    static let legacyStatsRetentionDays = 365
    static let legacyCountedRetention: TimeInterval = 2 * 86_400

    /// Removes expired legacy rows in one transaction. Idempotent; a failure removes nothing.
    @discardableResult
    public func purgeExpiredLegacyDictationData(
        now: Date, calendar: Calendar = .current
    ) async throws -> LegacyDictationRows {
        // Falling back to today would delete a year of stats, so an unknown horizon fails instead.
        guard let oldestDate = calendar.date(byAdding: .day, value: -Self.legacyStatsRetentionDays, to: now) else {
            throw StorageError.legacyDictationHorizonUnavailable
        }
        let oldestDay = Self.legacyStatsDay(of: oldestDate, calendar: calendar)
        let countedCutoff = now.addingTimeInterval(-Self.legacyCountedRetention)
        return try await database.write { database in
            guard let days = try Int.fetchOne(
                database, sql: "SELECT retentionDays FROM dictationHistoryPolicy WHERE id = 1")
            else { throw StorageError.missingLegacyDictationPolicy }
            let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
            var removed = LegacyDictationRows.none
            try database.execute(sql: "DELETE FROM dictationRecord WHERE createdAt < ?", arguments: [cutoff])
            removed.history = database.changesCount
            try database.execute(sql: "DELETE FROM dictationStatsDay WHERE day < ?", arguments: [oldestDay])
            removed.statsDays = database.changesCount
            try database.execute(
                sql: "DELETE FROM dictationStatsCounted WHERE countedAt < ?", arguments: [countedCutoff])
            removed.countedDictations = database.changesCount
            return removed
        }
    }

    public func legacyDictationRows() async throws -> LegacyDictationRows {
        try await database.read { database in
            LegacyDictationRows(
                history: try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM dictationRecord") ?? 0,
                statsDays: try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM dictationStatsDay") ?? 0,
                countedDictations: try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM dictationStatsCounted") ?? 0)
        }
    }

    /// Deletes every legacy history and stats row at once; content-free egress receipts stay. A
    /// logical delete: WAL pages and backups keep their copies until SQLite or the user replaces
    /// them. Advances the history generation, so an older build still running cannot save into
    /// history again; stats have no generation, and such a build with counting on can count again.
    @discardableResult
    public func deleteAllLegacyDictationData() async throws -> LegacyDictationRows {
        try await database.write { database in
            var removed = LegacyDictationRows.none
            try database.execute(sql: "DELETE FROM dictationRecord")
            removed.history = database.changesCount
            try database.execute(sql: "DELETE FROM dictationStatsDay")
            removed.statsDays = database.changesCount
            try database.execute(sql: "DELETE FROM dictationStatsCounted")
            removed.countedDictations = database.changesCount
            try database.execute(sql: "UPDATE dictationHistoryPolicy SET generation = generation + 1 WHERE id = 1")
            guard database.changesCount == 1 else { throw StorageError.missingLegacyDictationPolicy }
            return removed
        }
    }

    static func legacyStatsDay(of date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}
