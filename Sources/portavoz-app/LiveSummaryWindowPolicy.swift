import Foundation
import PortavozCore

/// Selects immutable live-caption rows that have not yet crossed the rolling
/// summary boundary. Identity, rather than array position, remains correct
/// when live diarization splits a closed row into multiple speaker turns.
enum LiveSummaryWindowPolicy {
    static let maximumRowsPerCycle = 32
    static let maximumCharactersPerCycle = 6_000

    static func unsummarizedClosedRows(
        _ captions: [TranscriptSegment],
        summarizedIDs: Set<UUID>,
        maximumRows: Int = maximumRowsPerCycle,
        maximumCharacters: Int = maximumCharactersPerCycle
    ) -> [TranscriptSegment] {
        guard maximumRows > 0, maximumCharacters > 0 else { return [] }
        var selected: [TranscriptSegment] = []
        var characterCount = 0

        for segment in captions.dropLast()
        where !summarizedIDs.contains(segment.id) {
            let wouldExceedCharacters =
                characterCount + segment.text.count > maximumCharacters
            if !selected.isEmpty,
                selected.count >= maximumRows || wouldExceedCharacters {
                break
            }
            selected.append(segment)
            characterCount += segment.text.count
        }
        return selected
    }

    static func hasUnsummarizedClosedRows(
        _ captions: [TranscriptSegment],
        summarizedIDs: Set<UUID>
    ) -> Bool {
        captions.dropLast().contains { !summarizedIDs.contains($0.id) }
    }
}
