import Foundation
import PortavozCore

/// Builds the prompts every summary provider shares. Pure functions, so
/// the load-bearing details — glossary preservation, output language,
/// recipe sections, the never-invent rule — are pinned by unit tests
/// instead of hoped for.
public enum PromptFactory {
    /// System/instructions text for the single-pass or reduce phase.
    public static func summaryInstructions(
        recipe: Recipe,
        targetLanguage: String,
        glossary: [String],
        hasUserNotes: Bool = false
    ) -> String {
        var lines: [String] = []
        lines.append("You are the note-taker of a meeting. \(recipe.instructions)")
        if hasUserNotes {
            lines.append(notesBehavior())
        }
        lines.append(
            "Structure the summary with these sections, in this order: "
                + recipe.sections.joined(separator: ", ")
                + ". Translate the headings into the output language.")
        lines.append(
            "Return exactly one structured section entry for every listed section, "
                + "in the same order; keep its bullets empty when nothing applies.")
        lines.append(languageDirective(targetLanguage: targetLanguage, glossary: glossary))
        lines.append(
            "Speakers are labeled in the transcript (\"Me\" is the device owner). "
                + "Attribute decisions and commitments to those labels. "
                + "If something is not in the transcript, leave it out — never invent content.")
        lines.append(
            "Report commitments exclusively through the dedicated action-items field, "
                + "never as a summary section.")
        lines.append(
            "A decision is not an action item: never copy a decision bullet into the "
                + "action-items field unless the transcript states a separate commitment.")
        lines.append(
            "When the material has [E#] tags, cite only exact tags that directly support "
                + "the overview, a decision-bearing bullet, or an action item; "
                + "never invent or alter a tag.")
        lines.append(
            "Attach exact source tags to every supported action item in its dedicated field; "
                + "use no tags when the commitment is not directly supported.")
        let decisionSections = recipe.decisionSectionIndexes.compactMap { index in
            recipe.sections.indices.contains(index) ? recipe.sections[index] : nil
        }
        if decisionSections.isEmpty {
            lines.append("This recipe has no typed decision section; section bullets need no evidence.")
        } else {
            lines.append(
                "These instructed sections contain typed decisions: "
                    + decisionSections.joined(separator: ", ")
                    + ". Attach exact source tags to each supported bullet in those sections only.")
        }
        return lines.joined(separator: "\n")
    }

    /// Instructions for the map phase over one transcript chunk. Brevity
    /// is load-bearing: each level of notes must be several times smaller
    /// than its input or the recursive condensing never converges.
    public static func notesInstructions(targetLanguage: String, glossary: [String]) -> String {
        [
            "You compress meeting transcript excerpts into dense factual notes.",
            "Keep every decision, commitment, number, date, and open question, each attributed to its speaker label.",
            "Preserve every source tag such as [E1] exactly beside the fact it supports.",
            "Write at most 10 terse bullet points, no preamble.",
            languageDirective(targetLanguage: targetLanguage, glossary: glossary)
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
        transcriptOrNotes text: String,
        targetLanguage: String,
        userNotes: String = ""
    ) -> String {
        var prompt = ""
        if !userNotes.isEmpty {
            prompt += "THE USER'S OWN NOTES (their personal emphasis):\n\(userNotes)\n\n"
        }
        prompt += "Here is the meeting material to summarize:\n\n\(text)\n\n"
        // The language order goes LAST — the 3B forgets directives that
        // don't close the prompt (D18).
        prompt +=
            "Remember: write the ENTIRE summary in \(languageName(for: targetLanguage)), including every heading and bullet."
        return prompt
    }

    /// D28: the user's notes are INTENT — the summary must expand each one
    /// with facts and never contradict them. Bullets born from a note are
    /// prefixed "▸ " (one cheap token instead of inflating the guided
    /// schema), so the UI can render coauthorship like Granola's
    /// black-vs-gray without a schema change.
    static func notesBehavior() -> String {
        "The user's own notes mark what mattered to THEM. Treat each note as a "
            + "topic the summary MUST cover: expand it with facts from the material, "
            + "never contradict it, and prefix every bullet that grows out of a user "
            + "note with \"▸ \". Notes are terse fragments — resolve them against the "
            + "material, don't quote them verbatim."
    }

    /// Formats context items as a compact, timestamped block. Budgeted for
    /// the 3B window: each note clipped to `perNoteLimit` chars, the whole
    /// block to `budget` (oldest first — the block interleaves with the
    /// transcript's own order).
    public static func notesBlock(
        _ items: [ContextItem],
        perNoteLimit: Int = 120,
        budget: Int = 800
    ) -> String {
        var lines: [String] = []
        var used = 0
        for item in items.sorted(by: { $0.timestamp < $1.timestamp }) {
            let content = item.content
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\n", with: " ")
            guard !content.isEmpty else { continue }
            let safeContent = TranscriptFormatter.escapeEvidenceTags(in: content)
            let clipped = String(safeContent.prefix(perNoteLimit))
            let total = Int(item.timestamp)
            let line = String(format: "[%02d:%02d] %@", total / 60, total % 60, clipped)
            guard used + line.count + 1 <= budget else { break }
            lines.append(line)
            used += line.count + 1
        }
        return lines.joined(separator: "\n")
    }

    /// Instructions for translating a FINISHED summary (D25's pivot):
    /// re-expression only — structure, order and content are frozen.
    public static func translationInstructions(
        targetLanguage: String, glossary: [String]
    ) -> String {
        [
            "You translate a finished meeting summary into another language.",
            "Translate EVERYTHING, headings included, but change nothing else: "
                + "same markdown structure, same bullets in the same order, "
                + "no content added, removed or reworded beyond translation.",
            "Keep any \"▸ \" bullet prefixes exactly where they are.",
            languageDirective(targetLanguage: targetLanguage, glossary: glossary)
        ].joined(separator: "\n")
    }

    /// Structure and action items translate in SEPARATE calls: shown both
    /// at once, the 3B promoted the item list into an invented extra
    /// section (caught by the gated test).
    public static func translationPrompt(
        markdown: String, actionItems: String, targetLanguage: String
    ) -> String {
        var prompt = ""
        if !markdown.isEmpty {
            prompt += "Summary to translate:\n\n\(markdown)\n\n"
        }
        if !actionItems.isEmpty {
            prompt +=
                "Action items to translate, one per line, same order and count:\n\(actionItems)\n\n"
        }
        prompt +=
            "Remember: write the ENTIRE translation in \(languageName(for: targetLanguage))."
        return prompt
    }

    /// Instructions for speaker naming (M6). Evidence-or-nothing: a small
    /// model happily invents names unless the bar is explicit proof.
    public static func namingInstructions() -> String {
        [
            "You map meeting speaker labels (S1, S2, …) to real people's names.",
            // One-line prompt instruction.
            // swiftlint:disable:next line_length
            "A mapping is valid ONLY with explicit proof in the transcript: the speaker introduces themselves (\"soy Ana\", \"this is John speaking\"), or another speaker addresses them by name immediately around their turn (\"thanks, Ana\" right after S2 spoke).",
            "Never infer names from topics, roles or guesses. Skip the label \"Me\".",
            "When nothing is provable, return an empty list — that is the common case."
        ].joined(separator: "\n")
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
