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

    /// The "te preguntaron" gate (D26): whole-word, case- and
    /// diacritic-insensitive match of the owner's first name or full name.
    /// Token equality on purpose — "John" must not fire inside "Johnny".
    public static func mentions(_ name: String, in text: String) -> Bool {
        func fold(_ value: String) -> String {
            value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
                .lowercased()
        }
        func tokens(_ value: String) -> [String] {
            fold(value).components(separatedBy: CharacterSet.letters.inverted)
                .filter { !$0.isEmpty }
        }
        let nameTokens = tokens(name)
        guard let first = nameTokens.first else { return false }
        let textTokens = tokens(text)
        if textTokens.contains(first) { return true }
        // Full name as a consecutive token run ("ana maría" in "…ana maría, ¿…?").
        guard nameTokens.count > 1, textTokens.count >= nameTokens.count else { return false }
        return (0...(textTokens.count - nameTokens.count)).contains { start in
            Array(textTokens[start..<(start + nameTokens.count)]) == nameTokens
        }
    }
}

/// One answered question, ready for the recording side panel. `source`
/// names who produced the answer ("on-device" hoy; el proveedor BYOK
/// cuando exista) — the disclosure D26 demands.
public struct CompanionCard: Identifiable, Sendable, Equatable {
    public enum Kind: String, Sendable {
        case knowledge
        case context
    }

    public let id: UUID
    public let question: String
    /// Empty on a pure "te preguntaron" ping — the question itself is the
    /// whole value; the UI hides the answer block.
    public let answer: String
    public let kind: Kind
    public let source: String
    /// True when the caption addressed the device owner BY NAME (D26's
    /// "te preguntaron"): the card doubles as an attention ping.
    public let directed: Bool
    public let askedAt: TimeInterval

    public init(
        id: UUID = UUID(),
        question: String,
        answer: String,
        kind: Kind,
        source: String,
        directed: Bool = false,
        askedAt: TimeInterval
    ) {
        self.id = id
        self.question = question
        self.answer = answer
        self.kind = kind
        self.source = source
        self.directed = directed
        self.askedAt = askedAt
    }
}

#if canImport(FoundationModels)
import FoundationModels

/// The live companion pipeline (D26): classify a candidate caption row,
/// route by question type, answer on-device — or, for `knowledge`
/// questions ONLY and with the user's explicit BYOK opt-in, via their
/// external provider (a 3B model answers "¿var vs let?" fine; it is not
/// who you want for anything deeper). Never speaks, never posts — it only
/// produces cards the user may read, copy or dismiss.
@available(macOS 26.0, iOS 26.0, *)
public struct LiveCompanion: Sendable {
    /// Non-nil only when the user configured BYOK AND enabled it for the
    /// companion (D8/D26). Only the detected question text ever leaves the
    /// device — never audio, never the rest of the meeting.
    private let byok: OpenAICompatibleChatClient?

    public init(byok: OpenAICompatibleChatClient? = nil) {
        self.byok = byok
    }

    /// Full pipeline for one candidate row. Returns nil when there is no
    /// question worth a card (not a question, or logistics chatter that
    /// wasn't aimed at the owner by name).
    ///
    /// Detection runs at `.live` priority with a latest-wins key: while
    /// the model is busy, a newer candidate replaces a queued older one —
    /// ticks never pile up. The answer runs at `.interactive`: a human is
    /// waiting, and the scheduler bounds its wait to the call in flight.
    public func process(
        candidate: String,
        recentTranscript: [RAGPassage],
        ownerName: String? = nil,
        askedAt: TimeInterval
    ) async throws -> CompanionCard? {
        let mentioned = ownerName.map { QuestionHeuristic.mentions($0, in: candidate) } ?? false
        guard QuestionHeuristic.looksLikeQuestion(candidate) || mentioned else { return nil }
        if let reason = FoundationModelSummaryProvider.unavailabilityReason() {
            throw IntelligenceError.modelUnavailable(reason)
        }

        guard let detected = try await classify(candidate, ownerName: ownerName),
            detected.isQuestion, !detected.question.isEmpty
        else { return nil }
        // Directed = the DETERMINISTIC name gate, never the model's
        // opinion: asked to flag it, the 3B cleaned "Johnny," out of the
        // question and reported false (caught by the gated test).
        let directed = mentioned

        switch detected.kind.lowercased() {
        case "knowledge":
            if let byok,
                let answer = try? await byok.complete(
                    system: Self.knowledgeInstructions,
                    user: detected.question,
                    maxTokens: 400)
            {
                return CompanionCard(
                    question: detected.question,
                    answer: answer.trimmingCharacters(in: .whitespacesAndNewlines),
                    kind: .knowledge, source: byok.providerLabel,
                    directed: directed, askedAt: askedAt)
            }
            // No BYOK — or the cloud call failed (network, quota, endpoint
            // down): the card falls back on-device and says so in `source`.
            let answer = try await answerKnowledge(detected.question)
            return CompanionCard(
                question: detected.question, answer: answer,
                kind: .knowledge, source: "on-device",
                directed: directed, askedAt: askedAt)
        case "context":
            guard !recentTranscript.isEmpty else { return nil }
            let answer = try await RAGAnswerer().answer(
                question: detected.question, passages: recentTranscript)
            return CompanionCard(
                question: detected.question, answer: answer,
                kind: .context, source: "on-device",
                directed: directed, askedAt: askedAt)
        default:
            // Logistics/small talk: a card here is noise, the classic
            // failure mode of this feature class — UNLESS it was aimed at
            // the owner by name ("Johnny, ¿nos acompañas mañana?"). Then
            // the ping IS the value: question only, no invented answer.
            guard directed else { return nil }
            return CompanionCard(
                question: detected.question, answer: "",
                kind: .context, source: "on-device",
                directed: true, askedAt: askedAt)
        }
    }

    /// Pure so the prompt shape is pinned by tests. The owner block only
    /// exists when a name is known — an unnamed owner must not soften the
    /// logistics filter.
    static func classifierInstructions(ownerName: String?) -> String {
        var text = """
            You screen live meeting captions for questions that deserve an answer card.
            A question qualifies ONLY if answering it would genuinely help: technical or \
            factual knowledge ("what's the difference between var and let"), or something \
            about this meeting's own discussion ("what did we say about the budget").
            Scheduling, greetings, rhetorical questions and small talk NEVER qualify. \
            Asking a person to do, join or attend something is logistics, even when it \
            mentions the meeting's topics: "can you join the demo tomorrow?" and \
            "¿nos acompañas mañana a la reunión con el cliente?" are logistics, \
            NOT context.
            """
        if let ownerName, !ownerName.isEmpty {
            text += """
                \nEXCEPTION: the device owner is named "\(ownerName)". When the caption \
                addresses \(ownerName) by name with a question or request, it ALWAYS \
                qualifies, whatever the topic — but still classify kind honestly.
                """
        }
        text += """
            \nClassify kind as exactly one of: knowledge, context, logistics.
            Keep the question in its original language, cleaned of filler words.
            """
        return text
    }

    private func classify(
        _ candidate: String, ownerName: String?
    ) async throws -> DetectedQuestion? {
        let session = LanguageModelSession(
            instructions: Self.classifierInstructions(ownerName: ownerName))
        return try await IntelligenceScheduler.shared.run(.live, key: "companion-detect") {
            let response = try await session.respond(
                to: "Caption: \"\(candidate)\"",
                generating: DetectedQuestion.self,
                options: GenerationOptions(sampling: .greedy))
            return response.content
        }
    }

    /// Shared by the on-device and BYOK paths, so switching provider never
    /// changes the card's voice.
    private static let knowledgeInstructions = """
        Answer the question directly and correctly in one to three short sentences, \
        in the same language as the question. No preamble, no hedging. \
        If you are not confident in the answer, say so in one sentence.
        """

    private func answerKnowledge(_ question: String) async throws -> String {
        let session = LanguageModelSession(instructions: Self.knowledgeInstructions)
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
