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
        "puedes", "puede", "podría", "podrías", "sabes", "sabe"
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

    /// The "asked you" gate (D26): whole-word, case- and
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

// `CompanionCard` (the persisted answer-card model) lives in PortavozCore so
// StorageKit can save it, mirroring `ContextItem`. The pipeline that produces
// cards stays here.

/// Turns a raw model answer into a card-worthy one — pure, so it runs and is
/// tested without the model. A companion card only earns its place when the
/// model actually answered: filler is worse than nothing on a glanceable panel.
public enum CompanionAnswer {
    /// The answer if it's a real one, else nil. Strips the citation markers the
    /// RAG answerer is told to add ("[2]", "… in passage 3") — meaningless on a
    /// card — and treats a hedge / non-answer ("not in the context", "I
    /// apologize…") as no answer, so the card is dropped instead of showing it.
    public static func usable(_ raw: String) -> String? {
        // A trailing clause that only cites a passage ("… in passage 14.",
        // "… se confirma en el pasaje 3."). No accents in the pattern — the
        // "English source" gate scans this file. swiftlint:disable line_length
        let enPassage =
            #"(?i)[,;]?\s*(this is |as )?\b(confirmed|mentioned|stated|shown|noted)?\b\s*(in|en el|en los|en)?\s*passages?\s+\d+(\s*(,|and|y)\s*\d+)*\.?\s*$"#
        let esPassage =
            #"(?i)[,;]?\s*(esto se |como se |lo )?(confirma|menciona|indica|ve|dice)?\s*(en el|en los|en)?\s*pasajes?\s+\d+(\s*(,|y)\s*\d+)*\)?\.?\s*$"#
        // swiftlint:enable line_length
        let text = raw
            .replacingOccurrences(of: #"\s*\[\d+\]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: enPassage, with: "", options: .regularExpression)
            .replacingOccurrences(of: esPassage, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let low = text.folding(options: .diacriticInsensitive, locale: nil).lowercased()
        let hedges = [
            "not mentioned in the context", "not in the context", "not in the passages",
            "does not mention", "doesn't mention", "no mention of", "not provided in",
            "cannot determine", "can't determine", "unable to determine", "unable to answer",
            "i apologize", "need more information", "provide more context", "clarify your question",
            "no se menciona", "no aparece", "no puedo determinar", "no puedo responder",
            "necesito mas informacion", "mas contexto", "aclara tu pregunta", "no encuentro"
        ]
        if hedges.contains(where: { low.contains($0) }) { return nil }
        return text
    }
}

#if canImport(FoundationModels)
import FoundationModels

public struct CompanionProcessTrace: Equatable, Sendable {
    public internal(set) var classifierInvoked = false
    public internal(set) var answerProviderID: String?
    public internal(set) var answerModelID: String?
    public internal(set) var externalDestinationScope: DataEgressDestinationScope?
    public internal(set) var externalTransferOccurred = false
    public internal(set) var externalTransferSucceeded = false

    public init(
        classifierInvoked: Bool = false,
        answerProviderID: String? = nil,
        answerModelID: String? = nil,
        externalDestinationScope: DataEgressDestinationScope? = nil,
        externalTransferOccurred: Bool = false,
        externalTransferSucceeded: Bool = false
    ) {
        self.classifierInvoked = classifierInvoked
        self.answerProviderID = answerProviderID
        self.answerModelID = answerModelID
        self.externalDestinationScope = externalDestinationScope
        self.externalTransferOccurred = externalTransferOccurred
        self.externalTransferSucceeded = externalTransferSucceeded
    }
}

struct CompanionProcessResult: Sendable {
    let card: CompanionCard?
    let trace: CompanionProcessTrace
}

struct CompanionProcessFailure: Error {
    let trace: CompanionProcessTrace
    let underlying: any Error

    var cancelled: Bool { underlying is CancellationError }
}

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
    private let byok: CompanionBYOKClient?

    public init(byok: CompanionBYOKClient? = nil) {
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
        do {
            return try await processWithTrace(
                candidate: candidate,
                recentTranscript: recentTranscript,
                ownerName: ownerName,
                askedAt: askedAt,
                egressContext: byok.map { _ in
                    CompanionDataEgressContext(
                        meetingID: nil,
                        consentSource: .explicitCompanionClient)
                }).card
        } catch let failure as CompanionProcessFailure {
            throw failure.underlying
        }
    }

    func processWithTrace(
        candidate: String,
        recentTranscript: [RAGPassage],
        ownerName: String? = nil,
        askedAt: TimeInterval,
        egressContext: CompanionDataEgressContext? = nil
    ) async throws -> CompanionProcessResult {
        let mentioned = ownerName.map { QuestionHeuristic.mentions($0, in: candidate) } ?? false
        guard QuestionHeuristic.looksLikeQuestion(candidate) || mentioned else {
            return CompanionProcessResult(card: nil, trace: CompanionProcessTrace())
        }
        if let reason = FoundationModelSummaryProvider.unavailabilityReason() {
            throw IntelligenceError.modelUnavailable(reason)
        }

        var trace = CompanionProcessTrace()
        trace.classifierInvoked = true
        do {
            return try await processCandidate(
                candidate,
                recentTranscript: recentTranscript,
                ownerName: ownerName,
                askedAt: askedAt,
                egressContext: egressContext,
                trace: &trace)
        } catch {
            let underlying: any Error = error is CancellationError || Task.isCancelled
                ? CancellationError()
                : error
            throw CompanionProcessFailure(
                trace: trace,
                underlying: underlying)
        }
    }

    private func processCandidate(
        _ candidate: String,
        recentTranscript: [RAGPassage],
        ownerName: String?,
        askedAt: TimeInterval,
        egressContext: CompanionDataEgressContext?,
        trace: inout CompanionProcessTrace
    ) async throws -> CompanionProcessResult {
        guard let detected = try await classify(candidate, ownerName: ownerName),
            detected.isQuestion, !detected.question.isEmpty
        else { return CompanionProcessResult(card: nil, trace: trace) }
        // Directed = the DETERMINISTIC name gate, never the model's
        // opinion: asked to flag it, the 3B cleaned "Johnny," out of the
        // question and reported false (caught by the gated test).
        let directed = ownerName.map { QuestionHeuristic.mentions($0, in: candidate) } ?? false

        switch detected.kind.lowercased() {
        case "knowledge":
            let rawAnswer: String
            let source: String
            if let byok {
                trace.externalTransferOccurred = true
                trace.answerProviderID = byok.providerLabel
                trace.answerModelID = byok.model
                trace.externalDestinationScope = byok.destination.scope
                do {
                    let answer = try await byok.completeCompanionQuestion(
                        system: Self.knowledgeInstructions,
                        user: detected.question,
                        maxTokens: 400,
                        context: egressContext ?? CompanionDataEgressContext(
                            meetingID: nil,
                            consentSource: .explicitCompanionClient))
                    trace.externalTransferSucceeded = true
                    rawAnswer = answer
                    source = byok.providerLabel
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    try Task.checkCancellation()
                    trace.answerProviderID = CompanionGenerationAttempt.foundationProviderID
                    trace.answerModelID = CompanionGenerationAttempt.foundationModelID
                    rawAnswer = try await answerKnowledge(detected.question)
                    source = "on-device"
                }
            } else {
                trace.answerProviderID = CompanionGenerationAttempt.foundationProviderID
                trace.answerModelID = CompanionGenerationAttempt.foundationModelID
                rawAnswer = try await answerKnowledge(detected.question)
                source = "on-device"
            }
            let card = Self.card(
                question: detected.question, rawAnswer: rawAnswer, kind: .knowledge,
                source: source, directed: directed, askedAt: askedAt)
            return CompanionProcessResult(card: card, trace: trace)
        case "context":
            guard !recentTranscript.isEmpty else {
                let card = directed ? Self.pingCard(detected.question, askedAt: askedAt) : nil
                return CompanionProcessResult(card: card, trace: trace)
            }
            trace.answerProviderID = CompanionGenerationAttempt.foundationProviderID
            trace.answerModelID = CompanionGenerationAttempt.foundationModelID
            let answer = try await RAGAnswerer().answer(
                question: detected.question, passages: recentTranscript)
            let card = Self.card(
                question: detected.question, rawAnswer: answer, kind: .context,
                source: "on-device", directed: directed, askedAt: askedAt)
            return CompanionProcessResult(card: card, trace: trace)
        default:
            // Logistics/small talk: a card here is noise, the classic
            // failure mode of this feature class — UNLESS it was aimed at
            // the owner by name ("Johnny, ¿nos acompañas mañana?"). Then
            // the ping IS the value: question only, no invented answer.
            let card = directed ? Self.pingCard(detected.question, askedAt: askedAt) : nil
            return CompanionProcessResult(card: card, trace: trace)
        }
    }

    /// Builds a card from a raw model answer: keeps it only if the model
    /// actually answered. `usableAnswer` strips the RAG citation markers and
    /// rejects a hedge ("not in the context", "I apologize…") — a NON-directed
    /// question with no real answer produces NO card (filler is worse than
    /// nothing), while a directed "asked you" keeps its ping regardless.
    static func card(
        question: String, rawAnswer: String, kind: CompanionCard.Kind,
        source: String, directed: Bool, askedAt: TimeInterval
    ) -> CompanionCard? {
        if let answer = CompanionAnswer.usable(rawAnswer) {
            return CompanionCard(
                question: question, answer: answer, kind: kind, source: source,
                directed: directed, askedAt: askedAt)
        }
        return directed ? pingCard(question, askedAt: askedAt) : nil
    }

    /// A directed "asked you" ping: the question is the whole value, no answer.
    static func pingCard(_ question: String, askedAt: TimeInterval) -> CompanionCard {
        CompanionCard(
            question: question, answer: "", kind: .context, source: "on-device",
            directed: true, askedAt: askedAt)
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
