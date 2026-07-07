import Foundation

/// Formats the user's domain vocabulary as Whisper conditioning text.
///
/// Whisper prepends `promptTokens` as "previous context"
/// (`<|startofprev|>`), so a sentence that mentions the terms verbatim
/// biases decoding toward them — "LVGT" stops coming out as "LGBT" and the
/// summary stops hallucinating around the mishearing. Parakeet (live) has no
/// equivalent hook; the refine pass is where the vocabulary lands.
public enum VocabularyPrompt {
    public static func text(_ terms: [String]) -> String? {
        let cleaned = terms
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !cleaned.isEmpty else { return nil }
        return "Glossary: " + cleaned.joined(separator: ", ") + "."
    }

    /// Parses the comma-separated form the Settings field and `--vocab` use.
    public static func parse(_ raw: String) -> [String] {
        raw.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
