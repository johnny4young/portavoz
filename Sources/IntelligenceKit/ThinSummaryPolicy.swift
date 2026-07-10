import Foundation

/// Detects a summary that is suspiciously small for its meeting — the
/// field case (Jul 10) was a 56-minute sprint demo reduced to 530
/// characters and zero action items by the on-device 3B. Deterministic
/// gate for a suggestion chip: the model's opinion never decides, and a
/// short meeting legitimately produces a short summary.
public enum ThinSummaryPolicy {
    /// Meetings under this length are allowed any summary size.
    static let minimumMeetingSeconds: TimeInterval = 20 * 60
    /// Under this many characters, a long meeting's summary is thin.
    static let thinCharacterFloor = 900

    public static func isThin(
        summaryCharacters: Int,
        actionItems: Int,
        meetingSeconds: TimeInterval
    ) -> Bool {
        guard meetingSeconds >= minimumMeetingSeconds else { return false }
        if summaryCharacters < thinCharacterFloor { return true }
        // A 40+ minute working meeting with ZERO action items is the other
        // signature of a collapsed summary.
        return meetingSeconds >= 40 * 60 && actionItems == 0
    }
}
