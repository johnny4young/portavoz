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
}
