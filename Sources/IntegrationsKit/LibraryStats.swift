import Foundation
import PortavozCore

/// Pure aggregation for the Insights dashboard: everything derives from
/// the meetings list (no ML, no queries), with `now`/`calendar` injected
/// so tests are deterministic.
public struct LibraryStats: Sendable, Equatable {
    public struct WeekBucket: Sendable, Equatable, Identifiable {
        /// Start of the week (the calendar's first weekday).
        public let weekStart: Date
        public let count: Int
        public var id: Date { weekStart }
    }

    public let totalMeetings: Int
    public let totalSeconds: TimeInterval
    public let averageSeconds: TimeInterval
    /// Oldest → newest, one bucket per week over the window, zeros included
    /// (a chart with missing weeks reads as a lie).
    public let perWeek: [WeekBucket]
    /// 1...7 in the calendar's numbering (1 = Sunday for Gregorian/en).
    public let busiestWeekday: Int?
    /// Consecutive weeks ending NOW with at least one meeting.
    public let weeklyStreak: Int

    public static func compute(
        meetings: [Meeting],
        weeks window: Int = 12,
        calendar: Calendar = .current,
        now: Date = Date()
    ) -> LibraryStats {
        let durations = meetings.compactMap { meeting -> TimeInterval? in
            guard let ended = meeting.endedAt else { return nil }
            let seconds = ended.timeIntervalSince(meeting.startedAt)
            return seconds > 0 ? seconds : nil
        }
        let total = durations.reduce(0, +)

        // Week buckets over the window, zeros included.
        var buckets: [WeekBucket] = []
        if let thisWeek = calendar.dateInterval(of: .weekOfYear, for: now)?.start {
            let starts = (0..<max(1, window)).compactMap {
                calendar.date(byAdding: .weekOfYear, value: -$0, to: thisWeek)
            }.reversed()
            let byWeek = Dictionary(grouping: meetings) { meeting in
                calendar.dateInterval(of: .weekOfYear, for: meeting.startedAt)?.start ?? .distantPast
            }
            buckets = starts.map { WeekBucket(weekStart: $0, count: byWeek[$0]?.count ?? 0) }
        }

        let byWeekday = Dictionary(grouping: meetings) {
            calendar.component(.weekday, from: $0.startedAt)
        }
        let busiest = byWeekday.max {
            ($0.value.count, -$0.key) < ($1.value.count, -$1.key)
        }?.key

        var streak = 0
        for bucket in buckets.reversed() {
            guard bucket.count > 0 else { break }  // swiftlint:disable:this empty_count
            streak += 1
        }

        return LibraryStats(
            totalMeetings: meetings.count,
            totalSeconds: total,
            averageSeconds: durations.isEmpty ? 0 : total / Double(durations.count),
            perWeek: buckets,
            busiestWeekday: busiest,
            weeklyStreak: streak)
    }
}
