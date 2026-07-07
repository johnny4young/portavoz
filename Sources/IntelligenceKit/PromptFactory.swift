import Foundation

/// Builds the prompts every summary provider shares. Pure functions, so
/// the load-bearing details — glossary preservation, output language,
/// recipe sections, the never-invent rule — are pinned by unit tests
/// instead of hoped for.
public enum PromptFactory {
    /// System/instructions text for the single-pass or reduce phase.
    public static func summaryInstructions(
        recipe: Recipe,
        targetLanguage: String,
        glossary: [String]
    ) -> String {
        var lines: [String] = []
        lines.append("You are the note-taker of a meeting. \(recipe.instructions)")
        lines.append(
            "Structure the summary with these sections, in this order: "
                + recipe.sections.joined(separator: ", ")
                + ". Translate the headings into the output language.")
        lines.append(languageDirective(targetLanguage: targetLanguage, glossary: glossary))
        lines.append(
            "Speakers are labeled in the transcript (\"Me\" is the device owner). "
                + "Attribute decisions and commitments to those labels. "
                + "If something is not in the transcript, leave it out — never invent content.")
        lines.append(
            "Report commitments exclusively through the dedicated action-items field, "
                + "never as a summary section.")
        return lines.joined(separator: "\n")
    }

    /// Instructions for the map phase over one transcript chunk. Brevity
    /// is load-bearing: each level of notes must be several times smaller
    /// than its input or the recursive condensing never converges.
    public static func notesInstructions(targetLanguage: String, glossary: [String]) -> String {
        [
            "You compress meeting transcript excerpts into dense factual notes.",
            "Keep every decision, commitment, number, date, and open question, each attributed to its speaker label.",
            "Write at most 10 terse bullet points, no preamble.",
            languageDirective(targetLanguage: targetLanguage, glossary: glossary),
        ].joined(separator: "\n")
    }

    public static func notesPrompt(chunk: String, index: Int, total: Int) -> String {
        "Transcript excerpt \(index + 1) of \(total):\n\n\(chunk)\n\nNotes:"
    }

    /// The language reminder rides at the END of the user prompt on
    /// purpose: the small on-device model weighs recency heavily and
    /// ignored the language when it only lived in the instructions
    /// (observed 2026-07-07: "es" request → English summary).
    public static func summaryPrompt(
        transcriptOrNotes text: String, targetLanguage: String
    ) -> String {
        "Here is the meeting material to summarize:\n\n\(text)\n\n"
            + "Remember: write the ENTIRE summary in \(languageName(for: targetLanguage)), including every heading and bullet."
    }

    /// The bilingual core: output language + glossary terms kept verbatim.
    /// Acceptance (M4): a Spanish summary of an English meeting must keep
    /// the glossary untranslated.
    static func languageDirective(targetLanguage: String, glossary: [String]) -> String {
        let name = languageName(for: targetLanguage)
        var directive =
            "Write every part of the output in \(name), regardless of the language spoken in the meeting."
        if !glossary.isEmpty {
            directive +=
                " Keep these terms exactly as written, never translated: "
                + glossary.joined(separator: ", ") + "."
        }
        return directive
    }

    /// "es" → "Spanish (español)": a small model follows a spelled-out
    /// language name far more reliably than a BCP-47 tag.
    static func languageName(for tag: String) -> String {
        let english = Locale(identifier: "en").localizedString(forLanguageCode: tag)
        let native = Locale(identifier: tag).localizedString(forLanguageCode: tag)
        switch (english, native) {
        case (let english?, let native?) where english.caseInsensitiveCompare(native) != .orderedSame:
            return "\(english) (\(native))"
        case (let english?, _):
            return english
        default:
            return tag
        }
    }
}
