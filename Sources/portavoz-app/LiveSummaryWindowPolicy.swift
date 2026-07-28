import Foundation
import PortavozCore

/// Selects immutable live-caption rows that have not yet crossed the rolling
/// summary boundary. Identity, rather than array position, remains correct
/// when live diarization splits a closed row into multiple speaker turns.
enum LiveSummaryWindowPolicy {
    static func unsummarizedClosedRows(
        _ captions: [TranscriptSegment],
        summarizedIDs: Set<UUID>
    ) -> [TranscriptSegment] {
        captions.dropLast().filter { !summarizedIDs.contains($0.id) }
    }
}
