import PortavozCore
import TranscriptionKit

/// Session-local projection. Partial revisions do not rejoin the closed prefix;
/// the coalescer owns admission and tells us which prefix remains valid.
struct DictationTranscriptProjection {
    private let coalescer = CaptionCoalescer()
    private var captions: [TranscriptSegment] = []
    private var closedCount = 0
    private(set) var confirmedText = ""
    var partialText: String { captions.last?.text ?? "" }
    var finalText: String { DictationAssembler.text(confirmed: confirmedText, partial: partialText) }

    /// Whether the caller needs to publish a new confirmed prefix. The tail is
    /// always read from the admitted rows, including same-count replacements.
    mutating func apply(_ segment: TranscriptSegment) -> Bool {
        guard let invalidated = coalescer.apply(segment, to: &captions) else { return false }
        let nextClosedCount = max(0, captions.count - 1)
        if invalidated < closedCount || nextClosedCount < closedCount {
            // A removed microphone echo can reopen a formerly closed remote
            // row. This uncommon correction invalidates the retained prefix.
            confirmedText = captions.prefix(nextClosedCount).map(\.text).joined(separator: " ")
        } else if nextClosedCount > closedCount {
            for row in captions[closedCount..<nextClosedCount] {
                if !confirmedText.isEmpty { confirmedText += " " }
                confirmedText += row.text
            }
        } else {
            return false
        }
        closedCount = nextClosedCount
        return true
    }
}
