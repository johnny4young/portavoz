import Foundation
import PortavozCore

#if canImport(FoundationModels)
import FoundationModels

/// The brief's "What to know": two-three bullets synthesized from the
/// related meetings' overviews, each CITING the passage it came from.
/// Never-trust-verify (the naming filter's lesson): a bullet survives only
/// when its cited passage exists AND shares literal evidence with the text —
/// filler like "the meeting will be brief" can't ground itself and dies.
@available(macOS 26.0, *)
public enum BriefSynthesizer {
    public struct Point: Sendable, Equatable {
        public let text: String
        /// Index into the passages array the point is grounded in.
        public let passageIndex: Int

        public init(text: String, passageIndex: Int) {
            self.text = text
            self.passageIndex = passageIndex
        }
    }

    static let instructions = """
        You brief the user before an upcoming meeting using ONLY the numbered \
        context passages from their past meetings. Produce two or three short \
        bullets, each a concrete fact worth remembering (decisions, open \
        threads, commitments), in the same language as the passages. Each \
        bullet MUST cite the number of the passage it comes from. Never \
        comment on the meeting's duration, format or logistics, and never \
        invent facts that are not in a passage.
        \(PromptFactory.sourceMaterialGuard())
        """

    /// nil/empty = nothing worth showing; the section simply hides.
    public static func whatToKnow(
        eventTitle: String, passages: [RAGPassage]
    ) async -> [Point] {
        guard !passages.isEmpty else { return [] }
        let context = passages.enumerated().map { index, passage in
            "[\(index + 1)] (\(passage.meetingTitle)) \(passage.text)"
        }.joined(separator: "\n")

        let session = LanguageModelSession(instructions: instructions)
        let generated: GeneratedBrief? = try? await IntelligenceScheduler.shared
            .run(.interactive) {
                try await session.respond(
                    to: "Context:\n\(context)\n\nUpcoming meeting: \(eventTitle)",
                    generating: GeneratedBrief.self,
                    options: GenerationOptions(sampling: .greedy)
                ).content
            }
        guard let generated else { return [] }
        let candidates = generated.points.map {
            Point(text: $0.text, passageIndex: $0.source)
        }
        return sanitize(candidates, passages: passages.map(\.text))
    }

    /// Deterministic gate, pure and unit-tested: valid 1-based index, sane
    /// length, and literal grounding — the bullet must share at least one
    /// content word (5+ letters) with its cited passage. The model's opinion
    /// never decides what survives.
    static func sanitize(_ points: [Point], passages: [String]) -> [Point] {
        var seen = Set<String>()
        return points.filter { point in
            let text = point.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard
                text.count >= 10, text.count <= 240,
                !text.contains("\n"),
                point.passageIndex >= 1, point.passageIndex <= passages.count,
                seen.insert(text.lowercased()).inserted
            else { return false }
            return grounded(text, in: passages[point.passageIndex - 1])
        }
    }

    /// Literal evidence check: some content word of the bullet appears in
    /// the passage (case- and diacritic-insensitive).
    static func grounded(_ text: String, in passage: String) -> Bool {
        let words = text.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .filter { $0.count >= 5 }
        return words.contains { word in
            passage.range(
                of: String(word),
                options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }
}

@available(macOS 26.0, *)
@Generable(description: "Pre-meeting brief points")
struct GeneratedBrief {
    @Guide(description: "Two or three bullets; each cites its source passage")
    var points: [GeneratedBriefPoint]
}

@available(macOS 26.0, *)
@Generable(description: "One brief point grounded in a passage")
struct GeneratedBriefPoint {
    @Guide(description: "One short, concrete fact in the passages' language")
    var text: String
    @Guide(description: "The 1-based number of the passage this fact comes from")
    var source: Int
}
#endif
