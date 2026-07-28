import Foundation

/// Pure text assembly for system-wide dictation: confirmed rows + the
/// still-changing partial tail → the text that gets inserted. Lives here
/// (not in the app executable) so it is unit-testable.
public enum DictationAssembler {
    public static func text(confirmed: String, partial: String) -> String {
        let pieces = [confirmed, partial]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return pieces.joined(separator: " ")
    }

    /// A dictation worth pasting carries at least one letter or digit. A
    /// noise artifact that decodes to bare punctuation ("." or "…") must
    /// never land in the target app — same lexical bar the meeting refine
    /// applies to transcript rows.
    public static func hasLexicalContent(_ text: String) -> Bool {
        text.contains { $0.isLetter || $0.isNumber }
    }
}
