import Foundation

/// Renders meeting titles from a user-configurable template. Token style
/// follows what recording tools already ship: Zoom names cloud recordings
/// "YYYY-MM-DD HH.mm.ss Title" (ISO date first so titles sort
/// chronologically), OBS exposes date/time patterns. Times use dots, not
/// colons, so a title can double as a filename.
public enum TitleTemplate {
    public static let defaultTemplate = "{date} {time} Meeting"

    /// Tokens: `{date}` → 2026-07-07 · `{time}` → 10.47 · `{seq}` →
    /// per-day sequence (01, 02…) · `{weekday}` → localized weekday name.
    /// Unknown tokens pass through untouched; a blank template falls back
    /// to the default.
    public static func render(
        _ template: String,
        date: Date,
        sequence: Int,
        locale: Locale = .current
    ) -> String {
        var source = template.trimmingCharacters(in: .whitespacesAndNewlines)
        if source.isEmpty { source = defaultTemplate }

        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let day = dateFormatter.string(from: date)

        dateFormatter.dateFormat = "HH.mm"
        let time = dateFormatter.string(from: date)

        let weekdayFormatter = DateFormatter()
        weekdayFormatter.locale = locale
        weekdayFormatter.dateFormat = "EEEE"
        let weekday = weekdayFormatter.string(from: date)

        return source
            .replacingOccurrences(of: "{date}", with: day)
            .replacingOccurrences(of: "{time}", with: time)
            .replacingOccurrences(of: "{seq}", with: String(format: "%02d", max(1, sequence)))
            .replacingOccurrences(of: "{weekday}", with: weekday)
    }
}
