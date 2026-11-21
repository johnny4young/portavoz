import Foundation
import PortavozCore

extension Meeting {
    var durationMinutes: Int? {
        guard let endedAt else { return nil }
        return max(0, Int(endedAt.timeIntervalSince(startedAt) / 60))
    }

    /// "Wed".
    static var weekdayStyle: Date.FormatStyle {
        Date.FormatStyle(locale: AppLanguage.current.locale).weekday(.abbreviated)
    }

    /// "Wed 9 Sep".
    static var dayStyle: Date.FormatStyle { weekdayStyle.day().month(.abbreviated) }

    /// The weekday within a week either side of now, else "Wed 9 Sep".
    static func shortDay(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let days = calendar.dateComponents(
            [.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        return date.formatted(abs(days) < 7 ? weekdayStyle : dayStyle)
    }

    /// "Wed 9 Sep · 31 min", or only the day while the meeting has no end.
    var dayAndLength: String { facts(day: startedAt.formatted(Self.dayStyle)) }

    /// "Wed · 31 min" within the last week, else as `dayAndLength`.
    func recentDayAndLength(now: Date = Date(), calendar: Calendar = .current) -> String {
        facts(day: Self.shortDay(startedAt, now: now, calendar: calendar))
    }

    private func facts(day: String) -> String {
        guard let durationMinutes else { return day }
        return "\(day) · \(L10n.format("%d min", durationMinutes))"
    }
}
