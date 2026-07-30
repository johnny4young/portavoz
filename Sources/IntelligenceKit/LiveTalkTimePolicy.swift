import Foundation
import PortavozCore

/// Rolling talk-time balance for the live recording bar (APUN-004, the
/// Fireflies/Read cue reimplemented as pure math — no model call, so it
/// does not ride the Apuntador opt-in). Channel is the ground truth the
/// live surface always has: microphone = the user, system = everyone
/// else. The mirror's philosophy applies — measured, not judged: the cue
/// only becomes notable with enough evidence.
public enum LiveTalkTimePolicy {
    /// The same five-minute horizon as catch-up: recent enough to act on.
    public static let window: TimeInterval = 300
    /// Defensive presentation bound before the time-window filter. At the
    /// current per-channel caption cadence this leaves ample headroom above
    /// the expected rows in five minutes while keeping work independent of
    /// total meeting duration.
    public static let maximumCandidateRows = 1_024
    /// Below this much attributed speech in the window, no judgment — the
    /// first minute of a meeting is always lopsided.
    public static let minimumSpeech: TimeInterval = 60
    /// Carrying over about two thirds of a conversation is worth a nudge.
    public static let notableFraction = 0.65

    public struct Balance: Equatable, Sendable {
        /// 0…1 share of the window's speech that came from the microphone.
        public let meFraction: Double
        /// Total attributed speech seconds inside the window.
        public let speechSeconds: TimeInterval
        /// True only past `minimumSpeech` AND `notableFraction` — the cue's
        /// visual emphasis, never a blocker.
        public let isNotable: Bool
    }

    /// nil when nothing closed yet — the bar simply doesn't render.
    public static func balance(
        _ captions: [TranscriptSegment],
        window: TimeInterval = window
    ) -> Balance? {
        let closed = captions.suffix(maximumCandidateRows + 1).dropLast()
        guard let newest = closed.last else { return nil }
        let cutoff = newest.endTime - window
        var me: TimeInterval = 0
        var total: TimeInterval = 0
        for row in closed where row.endTime >= cutoff {
            let duration = max(0, row.endTime - row.startTime)
            total += duration
            if row.channel == .microphone { me += duration }
        }
        guard total > 0 else { return nil }
        let fraction = me / total
        return Balance(
            meFraction: fraction,
            speechSeconds: total,
            isNotable: total >= minimumSpeech && fraction >= notableFraction)
    }
}
