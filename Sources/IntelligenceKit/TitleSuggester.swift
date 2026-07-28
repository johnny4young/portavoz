import Foundation
import PortavozCore

#if canImport(FoundationModels)
import FoundationModels

/// Proposes a content-based meeting title from the summary ("QVTL Lambda
/// deadline sync" instead of "2026-07-09 09.33 Meeting"). Suggestion-only:
/// shown as a chip next to the title, applied on click, never renames on
/// its own. Deterministic gates: length-capped, single line, and never the
/// current title again.
@available(macOS 26.0, *)
public enum TitleSuggester {
    static let instructions = """
        You title meetings from their summary. Return a short, specific title \
        in the SAME language as the summary: at most six words, no dates, no \
        quotes, no trailing period. Name the concrete topic, never generic \
        words like "meeting", "sync" alone, or "discussion".
        \(PromptFactory.sourceMaterialGuard())
        Examples:
        - summary about a device-ID bug in the QVTL pipeline → QVTL device-ID bug
        - resumen sobre el presupuesto de transcripción del Q3 → Presupuesto de transcripción Q3
        """

    /// nil when the model is unavailable, unsure, or suggests something
    /// unusable (empty, too long, or the same title).
    public static func suggest(summaryMarkdown: String, currentTitle: String) async -> String? {
        let excerpt = String(summaryMarkdown.prefix(1200))
        guard excerpt.count >= 40 else { return nil }
        let session = LanguageModelSession(instructions: instructions)
        let suggested: SuggestedTitle? = try? await IntelligenceScheduler.shared
            .run(.background) {
                try await session.respond(
                    to: "Summary:\n\(excerpt)",
                    generating: SuggestedTitle.self,
                    options: GenerationOptions(sampling: .greedy)
                ).content
            }
        guard let raw = suggested?.title else { return nil }
        let title = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'.“”"))
        guard
            !title.isEmpty,
            title.count <= 60,
            !title.contains("\n"),
            title.caseInsensitiveCompare(currentTitle) != .orderedSame
        else { return nil }
        return title
    }
}

@available(macOS 26.0, *)
@Generable(description: "A short meeting title")
struct SuggestedTitle {
    @Guide(description: "At most six words, same language as the summary, no dates or quotes")
    var title: String
}
#endif
