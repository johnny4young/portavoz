import Foundation

/// The one transcript order every durable read and every in-memory artifact
/// shares.
///
/// `startTime` alone is not a total order: the microphone and system channels
/// routinely open a segment at the same instant, and diarization slicing emits
/// pieces that can land on an existing start time. An operation fingerprint
/// taken over a start-time-only projection is therefore not a function of the
/// durable rows — two reads of unchanged material can hash differently and
/// permanently supersede the derived work that was fenced against them.
///
/// Segment identity is the tiebreaker because it is immutable, unique inside a
/// meeting, and compares identically in Swift and in SQLite: every `uuidString`
/// has the same 8-4-4-4-12 shape, so a byte-wise `ORDER BY startTime, id`
/// reproduces `canonicalOrder` exactly.
public enum TranscriptSegmentOrder {
    public static func canonicalOrder(
        _ first: TranscriptSegment,
        _ second: TranscriptSegment
    ) -> Bool {
        if first.startTime != second.startTime { return first.startTime < second.startTime }
        return first.id.uuidString < second.id.uuidString
    }

    public static func canonical(_ segments: [TranscriptSegment]) -> [TranscriptSegment] {
        segments.sorted(by: canonicalOrder)
    }
}
