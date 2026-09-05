import Foundation

/// Pure, locale-explicit formatting for Meeting Detail.
///
/// The route composes one value and views render its strings. No store,
/// capability, clock, or application service can enter this boundary.
struct MeetingDetailPresentation {
    let locale: Locale
    let timeZone: TimeZone

    func meetingDate(_ date: Date) -> String {
        formatted(date, dateStyle: .long)
    }

    func shortDate(_ date: Date) -> String {
        formatted(date, dateStyle: .abbreviated)
    }

    func meetingDuration(startedAt: Date, endedAt: Date?) -> String? {
        guard let endedAt else { return nil }
        let minutes = max(0, Int(endedAt.timeIntervalSince(startedAt) / 60))
        return "\(minutes) min"
    }

    func segmentCount(_ count: Int) -> String {
        "\(max(0, count)) segments"
    }

    func clock(_ seconds: TimeInterval, paddedMinutes: Bool = false) -> String {
        let total = max(0, Int(seconds.rounded()))
        let format = paddedMinutes ? "%02d:%02d" : "%d:%02d"
        return String(
            format: format,
            locale: locale,
            total / 60,
            total % 60)
    }

    func refinedDuration(_ seconds: TimeInterval) -> String {
        "\(clock(seconds)) min"
    }

    var languageIdentifier: String {
        locale.language.languageCode?.identifier ?? "en"
    }

    private func formatted(
        _ date: Date,
        dateStyle: Date.FormatStyle.DateStyle
    ) -> String {
        var style = Date.FormatStyle(date: dateStyle, time: .shortened)
        style.locale = locale
        style.timeZone = timeZone
        return date.formatted(style)
    }
}
