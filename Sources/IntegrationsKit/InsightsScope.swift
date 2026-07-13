import Foundation
import PortavozCore

/// The Insights time scope (design system 3a): the top tiles re-scope to
/// this week, this month, or this year, with a delta against the previous
/// period of the same kind. Pure so the window math is deterministic and
/// testable.
public enum InsightsScope: String, CaseIterable, Sendable {
    case week
    case month
    case year

    /// The calendar component that bounds one period of this scope.
    private var component: Calendar.Component {
        switch self {
        case .week: return .weekOfYear
        case .month: return .month
        case .year: return .year
        }
    }

    /// The interval covering the period that contains `now`.
    public func currentInterval(now: Date, calendar: Calendar = .current) -> DateInterval {
        calendar.dateInterval(of: component, for: now)
            ?? DateInterval(start: now, duration: 0)
    }

    /// The interval covering the period immediately before the current one —
    /// the baseline the delta is measured against.
    public func previousInterval(now: Date, calendar: Calendar = .current) -> DateInterval {
        let current = currentInterval(now: now, calendar: calendar)
        let priorAnchor = current.start.addingTimeInterval(-1)
        return calendar.dateInterval(of: component, for: priorAnchor)
            ?? DateInterval(start: priorAnchor, duration: 0)
    }
}

/// The scoped headline totals for the Insights tiles.
public struct ScopedTotals: Sendable, Equatable {
    public let count: Int
    public let seconds: TimeInterval
    public let averageSeconds: TimeInterval
    /// Meetings in the previous period of the same scope, for the delta.
    public let previousCount: Int

    public var deltaCount: Int { count - previousCount }

    public init(count: Int, seconds: TimeInterval, averageSeconds: TimeInterval, previousCount: Int) {
        self.count = count
        self.seconds = seconds
        self.averageSeconds = averageSeconds
        self.previousCount = previousCount
    }

    /// Totals for `scope` over `meetings`, plus the previous-period count for
    /// the delta. Duration comes from `endedAt`; meetings still recording
    /// (no end) count toward `count` but not toward time.
    public static func compute(
        meetings: [Meeting],
        scope: InsightsScope,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> ScopedTotals {
        let current = scope.currentInterval(now: now, calendar: calendar)
        let previous = scope.previousInterval(now: now, calendar: calendar)

        var count = 0
        var seconds: TimeInterval = 0
        var withDuration = 0
        var previousCount = 0
        for meeting in meetings {
            if current.contains(meeting.startedAt) {
                count += 1
                if let ended = meeting.endedAt {
                    let elapsed = ended.timeIntervalSince(meeting.startedAt)
                    if elapsed > 0 {
                        seconds += elapsed
                        withDuration += 1
                    }
                }
            } else if previous.contains(meeting.startedAt) {
                previousCount += 1
            }
        }
        let average = withDuration > 0 ? seconds / Double(withDuration) : 0
        return ScopedTotals(
            count: count, seconds: seconds, averageSeconds: average, previousCount: previousCount)
    }
}
