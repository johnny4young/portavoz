import Foundation
import PortavozCore

#if canImport(FoundationModels)
import FoundationModels

/// Names a meeting chapter with a short TOPIC heading ("Subscriber IDs",
/// "Endpoint decommission") instead of a verbatim opening line ("Okay",
/// "I mean…"). `ChapterExtractor` finds the time breaks and a real-excerpt
/// fallback; this labels them for navigation. Suggestion-only and best-effort:
/// nil when the model is unavailable or returns something unusable, and the
/// caller falls back to the excerpt.
@available(macOS 26.0, iOS 26.0, *)
public enum ChapterTitler {
    /// A topic title for the chapter's text, or nil when the model is
    /// unavailable/unsure or the passage is too thin to label.
    public static func title(forChapterText text: String) async -> String? {
        let excerpt = String(text.prefix(1200))
        guard excerpt.count >= 24 else { return nil }
        let session = LanguageModelSession(
            instructions: PromptFactory.chapterTitleInstructions)
        let generated: GeneratedChapterTitle? = try? await IntelligenceScheduler.shared
            .run(.background) {
                try await session.respond(
                    to: "Transcript:\n\(excerpt)",
                    generating: GeneratedChapterTitle.self,
                    options: GenerationOptions(sampling: .greedy)
                ).content
            }
        guard let raw = generated?.title else { return nil }
        let title = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'.“”"))
        guard !title.isEmpty, title.count <= 40, !title.contains("\n") else { return nil }
        return title
    }
}

@available(macOS 26.0, iOS 26.0, *)
@Generable(description: "A short topic heading for a meeting chapter")
struct GeneratedChapterTitle {
    @Guide(description: "2 to 4 words, same language as the transcript, the topic — never a verbatim quote")
    var title: String
}
#endif
