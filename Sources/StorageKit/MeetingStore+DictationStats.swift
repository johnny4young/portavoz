import Foundation
import GRDB
import PortavozCore

extension MeetingStore {
    public func dictationStatsEnabled() async throws -> Bool {
        try await database.read { try Self.dictationStatsEnabled(in: $0) }
    }

    /// Turning statistics off stops counting; the totals stay until deleted.
    public func setDictationStatsEnabled(_ isEnabled: Bool) async throws {
        try await database.write { database in
            try database.execute(
                sql: "UPDATE dictationStatsPolicy SET isEnabled = ? WHERE id = 1", arguments: [isEnabled])
        }
    }

    /// Counts one finished dictation while statistics are on, reading the consent
    /// in the same transaction. A retry of the same dictation only moves it
    /// between delivered and not delivered. Returns whether it was counted.
    @discardableResult
    public func recordDictationStats(
        _ sample: DictationStatsSample, at now: Date = Date(), calendar: Calendar = .current
    ) async throws -> Bool {
        guard sample.isValid else { throw StorageError.invalidDictationRecord("invalid statistics") }
        let oldestDay = DictationStatsCalendar.day(
            of: calendar.date(byAdding: .day, value: -DictationStatsCalendar.retentionDays, to: now) ?? now,
            calendar: calendar)
        let forgetCountedBefore = now.addingTimeInterval(-2 * 86_400)
        return try await database.write { database in
            guard try Self.dictationStatsEnabled(in: database) else { return false }
            try database.execute(sql: "DELETE FROM dictationStatsDay WHERE day < ?", arguments: [oldestDay])
            try database.execute(
                sql: "DELETE FROM dictationStatsCounted WHERE countedAt < ?", arguments: [forgetCountedBefore])
            let id = sample.id.rawValue.uuidString
            if let counted = try Row.fetchOne(
                database,
                sql: "SELECT day, applicationName, delivered FROM dictationStatsCounted WHERE dictationID = ?",
                arguments: [id]) {
                let delivered: Bool = counted["delivered"]
                guard delivered != sample.delivered else { return true }
                try database.execute(
                    sql: """
                        UPDATE dictationStatsDay SET notDelivered = MAX(0, notDelivered + ?)
                        WHERE day = ? AND applicationName = ?
                        """,
                    arguments: [
                        sample.delivered ? -1 : 1, counted["day"] as String, counted["applicationName"] as String
                    ])
                try database.execute(
                    sql: "UPDATE dictationStatsCounted SET delivered = ? WHERE dictationID = ?",
                    arguments: [sample.delivered, id])
                return true
            }
            let application = sample.applicationName ?? ""
            try database.execute(
                sql: """
                    INSERT INTO dictationStatsCounted (dictationID, day, applicationName, delivered, countedAt)
                    VALUES (?, ?, ?, ?, ?)
                    """,
                arguments: [id, sample.day, application, sample.delivered, now])
            try database.execute(
                sql: """
                    INSERT INTO dictationStatsDay (day, applicationName, dictations, words, spokenMs, notDelivered)
                    VALUES (?, ?, 1, ?, ?, ?)
                    ON CONFLICT(day, applicationName) DO UPDATE SET
                        dictations = dictations + 1,
                        words = words + excluded.words,
                        spokenMs = spokenMs + excluded.spokenMs,
                        notDelivered = notDelivered + excluded.notDelivered
                    """,
                arguments: [
                    sample.day, application, sample.words, Int((sample.spokenDuration * 1_000).rounded()),
                    sample.delivered ? 0 : 1
                ])
            return true
        }
    }

    /// Totals for each of `days` (oldest first, empty days included) and the
    /// busiest apps across them.
    public func dictationStatsSummary(days: [String]) async throws -> DictationStatsSummary {
        guard let first = days.first, let last = days.last else {
            return DictationStatsSummary(days: [], topApplications: [])
        }
        return try await database.read { database in
            let rows = try Row.fetchAll(
                database,
                sql: """
                    SELECT day, SUM(dictations) AS dictations, SUM(words) AS words,
                           SUM(spokenMs) AS spokenMs, SUM(notDelivered) AS notDelivered
                    FROM dictationStatsDay WHERE day BETWEEN ? AND ? GROUP BY day
                    """,
                arguments: [first, last])
            var totals: [String: DictationStatsTotals] = [:]
            for row in rows {
                let spokenMs: Int = row["spokenMs"]
                totals[row["day"]] = DictationStatsTotals(
                    dictations: row["dictations"], words: row["words"],
                    spokenDuration: Double(spokenMs) / 1_000, notDelivered: row["notDelivered"])
            }
            let applications = try Row.fetchAll(
                database,
                sql: """
                    SELECT applicationName, SUM(dictations) AS dictations, SUM(words) AS words
                    FROM dictationStatsDay
                    WHERE day BETWEEN ? AND ? AND applicationName != ''
                    GROUP BY applicationName
                    ORDER BY SUM(dictations) DESC, SUM(words) DESC, applicationName
                    LIMIT ?
                    """,
                arguments: [first, last, DictationStatsCalendar.topApplicationCount]
            ).map {
                DictationStatsApplication(name: $0["applicationName"], dictations: $0["dictations"], words: $0["words"])
            }
            return DictationStatsSummary(
                days: days.map { DictationStatsDay(day: $0, totals: totals[$0] ?? .zero) },
                topApplications: applications)
        }
    }

    public func deleteDictationStats() async throws {
        try await database.write { database in
            try database.execute(sql: "DELETE FROM dictationStatsDay")
            try database.execute(sql: "DELETE FROM dictationStatsCounted")
        }
    }

    static func dictationStatsEnabled(in database: Database) throws -> Bool {
        try Bool.fetchOne(database, sql: "SELECT isEnabled FROM dictationStatsPolicy WHERE id = 1") ?? false
    }
}
