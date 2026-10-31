import Foundation

/// Minimum content contract for durable transcript rows and model material.
/// Channel-specific confidence and bleed policies may remove more, but no
/// transcript boundary should admit punctuation-only or symbol-only text.
public enum TranscriptContentPolicy {
    private static let lexicalCharacters = CharacterSet.letters.union(.decimalDigits)

    public static func hasLexicalContent(_ text: String) -> Bool {
        text.unicodeScalars.contains { lexicalCharacters.contains($0) }
    }

    public static func retainLexicalSegments(
        _ segments: [TranscriptSegment]
    ) -> [TranscriptSegment] {
        segments.filter { hasLexicalContent($0.text) }
    }

    /// Reading view over stored rows: older transcripts can still hold
    /// punctuation-only rows, which stay only while a correction targets them.
    public static func readableSegments(
        _ segments: [TranscriptSegment],
        keeping targetedIDs: Set<UUID>
    ) -> [TranscriptSegment] {
        segments.filter { targetedIDs.contains($0.id) || hasLexicalContent($0.text) }
    }
}
