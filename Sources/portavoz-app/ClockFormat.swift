import Foundation

/// The one `m:ss` clock every transcript, player, and live surface renders.
enum ClockFormat {
    /// Minutes and seconds for a non-negative offset. Rounds to the nearest
    /// second; a live counter passes `truncating: true` so 0:59.9 still reads
    /// 0:59 until the minute really turns. The locale only affects digits.
    static func mmss(
        _ seconds: TimeInterval,
        paddedMinutes: Bool = true,
        truncating: Bool = false,
        locale: Locale? = nil
    ) -> String {
        let total = max(0, Int(truncating ? seconds : seconds.rounded()))
        let format = paddedMinutes ? "%02d:%02d" : "%d:%02d"
        return String(format: format, locale: locale, total / 60, total % 60)
    }
}
