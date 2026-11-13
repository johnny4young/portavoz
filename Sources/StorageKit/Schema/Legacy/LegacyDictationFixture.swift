#if DEBUG
import Foundation
import GRDB

extension MeetingStore {
    /// UI tests only: one day of 1.x statistics, so a disposable library looks like an upgraded one.
    public func seedLegacyDictationStatsDayForUITests(now: Date, calendar: Calendar = .current) async throws {
        let day = Self.legacyStatsDay(of: now, calendar: calendar)
        try await database.write { database in
            try database.execute(
                sql: """
                    INSERT OR IGNORE INTO dictationStatsDay
                        (day, applicationName, dictations, words, spokenMs, notDelivered)
                    VALUES (?, 'Notes', 1, 3, 1200, 0)
                    """,
                arguments: [day])
        }
    }
}
#endif
