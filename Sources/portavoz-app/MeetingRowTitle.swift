import Foundation

/// Library rows show the meeting's name, not the file-style date prefix the
/// title template can put in front of it; the row's own second line carries
/// the date.
enum MeetingRowTitle {
    /// "2026-07-10 Sprint Demo · Zephyr" → "Sprint Demo · Zephyr"; titles
    /// without a leading ISO date pass through unchanged, and a title that is
    /// only a date stays as it is so the row is never empty.
    static func display(_ title: String) -> String {
        let scalars = Array(title.unicodeScalars)
        guard scalars.count > 11,
              scalars[4] == "-", scalars[7] == "-", scalars[10] == " ",
              [0, 1, 2, 3, 5, 6, 8, 9].allSatisfy({ CharacterSet.decimalDigits.contains(scalars[$0]) })
        else { return title }
        let rest = String(String.UnicodeScalarView(scalars[11...]))
            .trimmingCharacters(in: .whitespaces)
        return rest.isEmpty ? title : rest
    }
}
