import Foundation

/// Display policy for the rolling live summary: what the user sees during a
/// recording must feel accumulative. The model re-renders the whole summary
/// from accumulated notes each tick, and a render can come out shorter or
/// drop a section — replacing the display with it reads as the summary
/// "shrinking". These rules keep the visible summary monotonic.
public enum LiveSummaryPolicy {
    /// The accumulated notes get collapsed once they pass this size, keeping
    /// the per-tick render cost flat on arbitrarily long meetings.
    public static let notesCollapseThreshold = 6000

    /// A fresh render replaces the current display only when it isn't
    /// meaningfully shorter (≥ 90% of the current length). A shorter render
    /// is kept back — the notes it came from only ever grow, so the next
    /// tick recovers the lost content.
    public static func shouldReplace(current: String?, candidate: String) -> Bool {
        guard !candidate.isEmpty else { return false }
        guard let current, !current.isEmpty else { return true }
        return candidate.count * 10 >= current.count * 9
    }
}
