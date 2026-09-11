import Foundation

/// Pure, locale-explicit formatting for Meeting Detail.
///
/// The route composes one value and views render its strings. No store,
/// capability, clock, or application service can enter this boundary; the
/// only lookup is the app's string catalog, so every user-visible count
/// follows the selected app language like the rest of the surface.
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
        return L10n.format("%d min", minutes)
    }

    func segmentCount(_ count: Int) -> String {
        let count = max(0, count)
        return count == 1
            ? L10n.text("1 segment")
            : L10n.format("%d segments", count)
    }

    func clock(_ seconds: TimeInterval, paddedMinutes: Bool = false) -> String {
        ClockFormat.mmss(seconds, paddedMinutes: paddedMinutes, locale: locale)
    }

    func refinedDuration(_ seconds: TimeInterval) -> String {
        L10n.format("%@ min", clock(seconds))
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
