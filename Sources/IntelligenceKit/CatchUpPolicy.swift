import Foundation
import PortavozCore

/// Selection policy for the on-demand "catch me up" recap: the answer covers
/// ONLY the recent past, so the clip is the closed caption rows inside a
/// fixed window before the newest closed row — never the whole meeting.
public enum CatchUpPolicy {
    /// How far back the recap looks. Five minutes covers "I zoned out" and
    /// "I just joined" without turning into a second full summary.
    public static let window: TimeInterval = 300

    /// Fewer closed rows than this cannot carry a recap worth a model call.
    public static let minimumRows = 2

    /// The newest row is still growing under the coalescer, so it is
    /// excluded; the clip is every other row whose end falls inside the
    /// window measured back from the newest closed row's end.
    public static func clip(_ captions: [TranscriptSegment]) -> [TranscriptSegment] {
        let closed = captions.dropLast()
        guard let newest = closed.last else { return [] }
        let cutoff = newest.endTime - window
        let clip = closed.filter { $0.endTime >= cutoff }
        return clip.count >= minimumRows ? Array(clip) : []
    }
}
