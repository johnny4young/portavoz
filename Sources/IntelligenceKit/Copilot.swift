import Foundation
import PortavozCore

/// Cheap, pure gate that decides whether a closed caption row is even
/// worth a model call. It errs on the side of passing (the classifier
/// prunes); its job is to make the common case — nobody asked anything —
/// cost zero.
public enum QuestionHeuristic {
    private static let interrogatives: Set<String> = [
        // EN
        "what", "how", "why", "when", "where", "who", "which", "whose",
        "can", "could", "would", "should", "do", "does", "did", "is", "are",
        // ES
        "qué", "que", "cómo", "como", "por", "cuándo", "cuando", "dónde",
        "donde", "quién", "quien", "cuál", "cual", "cuánto", "cuanto",
        "puedes", "puede", "podría", "podrías", "sabes", "sabe",
    ]

    public static func looksLikeQuestion(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 12 else { return false }
        if trimmed.contains("¿") || trimmed.hasSuffix("?") { return true }
        // "…the question is, how do we deploy?" — a '?' anywhere counts.
        if trimmed.contains("?") { return true }
        guard
            let firstWord = trimmed.lowercased()
                .split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
                .first
        else { return false }
        return interrogatives.contains(String(firstWord))
    }
}

/// One answered question, ready for the recording side panel. `source`
/// names who produced the answer ("on-device" hoy; el proveedor BYOK
/// cuando exista) — the disclosure D26 demands.
public struct CopilotCard: Identifiable, Sendable, Equatable {
    public enum Kind: String, Sendable {
        case knowledge
        case context
    }

    public let id: UUID
    public let question: String
    public let answer: String
    public let kind: Kind
    public let source: String
    public let askedAt: TimeInterval

    public init(
        id: UUID = UUID(),
        question: String,
        answer: String,
        kind: Kind,
        source: String,
        askedAt: TimeInterval
    ) {
        self.id = id
        self.question = question
        self.answer = answer
        self.kind = kind
        self.source = source
        self.askedAt = askedAt
    }
}

#if canImport(FoundationModels)
import FoundationModels

/// The live copilot pipeline (D26): classify a candidate caption row,
/// route by question type, answer on-device. Never speaks, never posts —
/// it only produces cards the user may read, copy or dismiss.
@available(macOS 26.0, iOS 26.0, *)
public struct LiveCopilot: Sendable {
    public init() {}

    /// Full pipeline for one candidate row. Returns nil when there is no
    /// question worth a card (not a question, or logistics chatter).
    ///
    /// Detection runs at `.live` priority with a latest-wins key: while
    /// the model is busy, a newer candidate replaces a queued older one —
    /// ticks never pile up. The answer runs at `.interactive`: a human is
    /// waiting, and the scheduler bounds its wait to the call in flight.
    public func process(
        candidate: String,
        recentTranscript: [RAGPassage],
        askedAt: TimeInterval
    ) async throws -> CopilotCard? {
        guard QuestionHeuristic.looksLikeQuestion(candidate) else { return nil }
        if let reason = FoundationModelSummaryProvider.unavailabilityReason() {
            throw IntelligenceError.modelUnavailable(reason)
        }

        guard let detected = try await classify(candidate), detected.isQuestion,
            !detected.question.isEmpty
        else { return nil }

        switch detected.kind.lowercased() {
        case "knowledge":
            let answer = try await answerKnowledge(detected.question)
            return CopilotCard(
                question: detected.question, answer: answer,
                kind: .knowledge, source: "on-device", askedAt: askedAt)
        case "context":
            guard !recentTranscript.isEmpty else { return nil }
            let answer = try await RAGAnswerer().answer(
                question: detected.question, passages: recentTranscript)
            return CopilotCard(
                question: detected.question, answer: answer,
                kind: .context, source: "on-device", askedAt: askedAt)
        default:
            // Logistics/small talk: a card here is noise, the classic
            // failure mode of this feature class.
            return nil
        }
    }

    private func classify(_ candidate: String) async throws -> DetectedQuestion? {
        let session = LanguageModelSession(
            instructions: """
                You screen live meeting captions for questions that deserve an answer card.
                A question qualifies ONLY if answering it would genuinely help: technical or \
                factual knowledge ("what's the difference between var and let"), or something \
                about this meeting's own discussion ("what did we say about the budget").
                Scheduling, greetings, rhetorical questions and small talk NEVER qualify.
                Classify kind as exactly one of: knowledge, context, logistics.
                Keep the question in its original language, cleaned of filler words.
                """)
        return try await IntelligenceScheduler.shared.run(.live, key: "copilot-detect") {
            let response = try await session.respond(
                to: "Caption: \"\(candidate)\"",
                generating: DetectedQuestion.self,
                options: GenerationOptions(sampling: .greedy))
            return response.content
        }
    }

    private func answerKnowledge(_ question: String) async throws -> String {
        let session = LanguageModelSession(
            instructions: """
                Answer the question directly and correctly in one to three short sentences, \
                in the same language as the question. No preamble, no hedging. \
                If you are not confident in the answer, say so in one sentence.
                """)
        return try await IntelligenceScheduler.shared.run(.interactive) {
            try await session.respond(
                to: question,
                options: GenerationOptions(sampling: .greedy, maximumResponseTokens: 220)
            ).content
        }
    }
}

@available(macOS 26.0, iOS 26.0, *)
@Generable(description: "Screening result for one live caption")
struct DetectedQuestion {
    @Guide(description: "true ONLY if the caption contains a real question someone asked")
    var isQuestion: Bool
    @Guide(description: "The question, cleaned up, in its original language; empty when isQuestion is false")
    var question: String
    @Guide(description: "Exactly one of: knowledge, context, logistics")
    var kind: String
}
#endif
