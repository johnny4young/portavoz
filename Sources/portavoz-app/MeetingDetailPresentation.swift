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

    /// Day · time · duration · spoken language, the line above the title.
    func meetingKicker(startedAt: Date, endedAt: Date?, language: String?) -> String {
        [
            startedAt.formatted(localized(
                Date.FormatStyle().weekday(.abbreviated).day().month(.abbreviated).year())),
            startedAt.formatted(localized(Date.FormatStyle(date: .omitted, time: .shortened))),
            meetingDuration(startedAt: startedAt, endedAt: endedAt),
            Self.spokenLanguageName(language)
        ]
        .compactMap { $0 }
        .joined(separator: " · ")
    }

    /// The language named in itself, as the people in the meeting say it.
    static func spokenLanguageName(_ code: String?) -> String? {
        guard let code, !code.isEmpty else { return nil }
        let own = Locale(identifier: code)
        return own.localizedString(forLanguageCode: code)?.capitalized(with: own)
    }

    func shortDate(_ date: Date) -> String {
        formatted(date, dateStyle: .abbreviated)
    }

    func meetingDuration(startedAt: Date, endedAt: Date?) -> String? {
        guard let endedAt else { return nil }
        let minutes = max(0, Int(endedAt.timeIntervalSince(startedAt) / 60))
        return L10n.format("%d min", minutes)
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
        date.formatted(localized(Date.FormatStyle(date: dateStyle, time: .shortened)))
    }

    private func localized(_ style: Date.FormatStyle) -> Date.FormatStyle {
        var style = style
        style.locale = locale
        style.timeZone = timeZone
        return style
    }
}
