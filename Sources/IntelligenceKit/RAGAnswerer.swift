import Foundation
import PortavozCore

/// One retrieved piece of context for the answerer.
public struct RAGPassage: Sendable, Equatable {
    public let meetingID: MeetingID
    public let meetingTitle: String
    public let timestamp: TimeInterval
    public let text: String

    public init(meetingID: MeetingID, meetingTitle: String, timestamp: TimeInterval, text: String) {
        self.meetingID = meetingID
        self.meetingTitle = meetingTitle
        self.timestamp = timestamp
        self.text = text
    }
}

public enum RAGFusion {
    /// Reciprocal-rank fusion of the lexical (FTS) and semantic result
    /// lists: score(item) = Σ 1/(60 + rank). Items found by both climbs;
    /// order within a single list is preserved. Pure and boring on
    /// purpose — this is the piece a wrong constant silently ruins.
    public static func fuse<ID: Hashable>(
        lexical: [ID], semantic: [ID], limit: Int
    ) -> [ID] {
        var scores: [ID: Double] = [:]
        for (rank, id) in lexical.enumerated() {
            scores[id, default: 0] += 1.0 / Double(60 + rank)
        }
        for (rank, id) in semantic.enumerated() {
            scores[id, default: 0] += 1.0 / Double(60 + rank)
        }
        return scores.sorted { left, right in
            if left.value != right.value { return left.value > right.value }
            return String(describing: left.key) < String(describing: right.key)
        }.prefix(limit).map(\.key)
    }
}

#if canImport(FoundationModels)
import FoundationModels

/// Answers questions over retrieved meeting passages, on-device. The
/// model may ONLY use the provided context and must cite it — anything
/// not in the passages is "no lo encuentro".
@available(macOS 26.0, iOS 26.0, *)
public struct RAGAnswerer: Sendable {
    public init() {}

    public func answer(question: String, passages: [RAGPassage]) async throws -> String {
        if let reason = FoundationModelSummaryProvider.unavailabilityReason() {
            throw IntelligenceError.modelUnavailable(reason)
        }
        guard !passages.isEmpty else {
            return "No encuentro nada relacionado en tus reuniones."
        }

        let context = passages.enumerated().map { index, passage in
            "[\(index + 1)] (\(passage.meetingTitle), \(Self.timestamp(passage.timestamp))) \(passage.text)"
        }.joined(separator: "\n")

        let session = LanguageModelSession(
            instructions: """
                You answer questions about the user's own meetings using ONLY the numbered context passages.
                Write a direct answer of one to three full sentences — never output a bare citation.
                After each claim, add the marker of the passage that supports it, e.g. "… media hora de latencia [2]."
                If the context does not contain the answer, say so plainly — never guess.
                """)
        return try await IntelligenceScheduler.shared.run(.interactive) {
            try await session.respond(
                to: "Context:\n\(context)\n\nQuestion: \(question)\n\n"
                    + "Answer with full sentences, in the same language as the question.",
                options: GenerationOptions(sampling: .greedy, maximumResponseTokens: 500)
            ).content
        }
    }

    /// Multi-query expansion for cross-lingual retrieval: the library is
    /// bilingual, so a Spanish question must also search in English (and
    /// vice versa). Returns the original question plus up to two terse
    /// paraphrases; on any failure, just the original.
    public func expandQuery(_ question: String) async -> [String] {
        let session = LanguageModelSession(
            instructions: """
                Rewrite the user's question as exactly two terse keyword search queries \
                for a meeting transcript index: one in English and one in Spanish. \
                One per line, no numbering, no commentary.
                """)
        guard
            let content = try? await IntelligenceScheduler.shared.run(
                .interactive,
                operation: {
                    try await session.respond(
                        to: question,
                        options: GenerationOptions(sampling: .greedy, maximumResponseTokens: 60)
                    ).content
                })
        else { return [question] }
        let variants = content
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)) }
            .filter { !$0.isEmpty && $0.caseInsensitiveCompare(question) != .orderedSame }
        return [question] + variants.prefix(2)
    }

    static func timestamp(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
#endif
