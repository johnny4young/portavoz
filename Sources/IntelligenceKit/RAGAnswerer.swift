import Foundation
import PortavozCore

/// One retrieved piece of context for the answerer.
public struct RAGPassage: Sendable, Equatable {
    /// Exact transcript identity when this passage came from a stored segment.
    /// Cross-meeting search callers may omit it and keep timestamp-only context.
    public let segmentID: UUID?
    /// Ordered accepted transcript evidence behind the retrieval unit.
    public let sourceSegmentIDs: [UUID]
    public let meetingID: MeetingID
    public let meetingTitle: String
    public let timestamp: TimeInterval
    public let transcriptRevision: Int?
    public let text: String

    public init(
        segmentID: UUID? = nil,
        sourceSegmentIDs: [UUID]? = nil,
        meetingID: MeetingID,
        meetingTitle: String,
        timestamp: TimeInterval,
        transcriptRevision: Int? = nil,
        text: String
    ) {
        self.segmentID = segmentID
        self.sourceSegmentIDs = sourceSegmentIDs ?? segmentID.map { [$0] } ?? []
        self.meetingID = meetingID
        self.meetingTitle = meetingTitle
        self.timestamp = timestamp
        self.transcriptRevision = transcriptRevision
        self.text = text
    }
}

/// One source-backed relationship supplied to generation without flattening it
/// into transcript retrieval rank. Exact source passages remain mandatory.
public struct RAGFact: Sendable, Equatable {
    public let kind: MeetingMemoryGraphFactKind
    public let subjectText: String
    public let objectText: String
    public let status: MeetingMemoryGraphFactStatus
    public let occurredAt: Date
    public let primarySourceSegmentID: UUID
    public let sources: [RAGPassage]

    public init(
        kind: MeetingMemoryGraphFactKind,
        subjectText: String,
        objectText: String,
        status: MeetingMemoryGraphFactStatus,
        occurredAt: Date,
        primarySourceSegmentID: UUID,
        sources: [RAGPassage]
    ) {
        self.kind = kind
        self.subjectText = subjectText
        self.objectText = objectText
        self.status = status
        self.occurredAt = occurredAt
        self.primarySourceSegmentID = primarySourceSegmentID
        self.sources = sources
    }
}

/// Disclosure attached to one bounded graph read. It is part of the model
/// context because a truncated or omission-bearing page cannot authorize a
/// complete "all" or "none" claim.
public struct RAGFactPage: Sendable, Equatable {
    public let facts: [RAGFact]
    public let hasMore: Bool
    public let projectionGeneration: Int
    public let omittedStaleCount: Int
    public let omittedUnavailableCount: Int
    public let selectionOmittedCount: Int

    public init(
        facts: [RAGFact],
        hasMore: Bool,
        projectionGeneration: Int,
        omittedStaleCount: Int,
        omittedUnavailableCount: Int,
        selectionOmittedCount: Int = 0
    ) {
        self.facts = facts
        self.hasMore = hasMore
        self.projectionGeneration = projectionGeneration
        self.omittedStaleCount = omittedStaleCount
        self.omittedUnavailableCount = omittedUnavailableCount
        self.selectionOmittedCount = selectionOmittedCount
    }

    public var isComplete: Bool {
        !hasMore
            && omittedStaleCount == 0
            && omittedUnavailableCount == 0
            && selectionOmittedCount == 0
    }
}

/// Counts emitted by the application-owned post-RRF selector. IntelligenceKit
/// validates them again before constructing a prompt so a forged context cannot
/// let graph volume displace transcript evidence.
public struct RAGAnswerSelectionDisclosure: Sendable, Equatable {
    public let transcriptCandidateCount: Int
    public let selectedTranscriptCount: Int
    public let graphFactCandidateCount: Int
    public let selectedGraphFactCount: Int
    public let additionalGraphSourceCount: Int
    public let omittedGraphFactCount: Int

    public init(
        transcriptCandidateCount: Int,
        selectedTranscriptCount: Int,
        graphFactCandidateCount: Int,
        selectedGraphFactCount: Int,
        additionalGraphSourceCount: Int,
        omittedGraphFactCount: Int
    ) {
        self.transcriptCandidateCount = transcriptCandidateCount
        self.selectedTranscriptCount = selectedTranscriptCount
        self.graphFactCandidateCount = graphFactCandidateCount
        self.selectedGraphFactCount = selectedGraphFactCount
        self.additionalGraphSourceCount = additionalGraphSourceCount
        self.omittedGraphFactCount = omittedGraphFactCount
    }

    public var isValid: Bool {
        transcriptCandidateCount >= selectedTranscriptCount
            && selectedTranscriptCount > 0
            && graphFactCandidateCount >= selectedGraphFactCount
            && selectedGraphFactCount > 0
            && selectedGraphFactCount <= selectedTranscriptCount
            && additionalGraphSourceCount >= 0
            && omittedGraphFactCount
                == graphFactCandidateCount - selectedGraphFactCount
    }
}

/// Two independent answer lanes. Transcript passages preserve retrieval order;
/// typed facts carry their own exact source passages and are never RRF inputs.
public struct RAGAnswerContext: Sendable, Equatable {
    public let transcriptPassages: [RAGPassage]
    public let factPage: RAGFactPage
    public let selection: RAGAnswerSelectionDisclosure

    public init(
        transcriptPassages: [RAGPassage],
        factPage: RAGFactPage,
        selection: RAGAnswerSelectionDisclosure
    ) {
        self.transcriptPassages = transcriptPassages
        self.factPage = factPage
        self.selection = selection
    }

    public var isFactAwareReady: Bool {
        !transcriptPassages.isEmpty
            && !factPage.facts.isEmpty
            && isValid
    }

    public var isValid: Bool {
        guard factPage.projectionGeneration > 0,
              factPage.omittedStaleCount >= 0,
              factPage.omittedUnavailableCount >= 0,
              factPage.selectionOmittedCount >= 0,
              selection.isValid,
              selection.selectedTranscriptCount == transcriptPassages.count,
              selection.selectedGraphFactCount == factPage.facts.count,
              selection.graphFactCandidateCount
                == factPage.facts.count + factPage.selectionOmittedCount,
              selection.omittedGraphFactCount
                == factPage.selectionOmittedCount,
              Self.hasExactUniquePassages(transcriptPassages),
              factPage.facts.allSatisfy({ fact in
            let sourceIDs = fact.sources.compactMap(\.segmentID)
            return fact.occurredAt.timeIntervalSinceReferenceDate.isFinite
                && !fact.subjectText.trimmingCharacters(
                    in: .whitespacesAndNewlines).isEmpty
                && !fact.objectText.trimmingCharacters(
                    in: .whitespacesAndNewlines).isEmpty
                && !fact.sources.isEmpty
                && sourceIDs.count == fact.sources.count
                && Set(sourceIDs).count == sourceIDs.count
                && sourceIDs.filter {
                    $0 == fact.primarySourceSegmentID
                }.count == 1
                && Self.hasExactUniquePassages(fact.sources)
        }) else { return false }
        var exactSegments: [UUID: RAGPassage] = [:]
        for passage in transcriptPassages + factPage.facts.flatMap(\.sources) {
            guard let segmentID = passage.segmentID else { return false }
            if let existing = exactSegments[segmentID], existing != passage {
                return false
            }
            exactSegments[segmentID] = passage
        }
        let transcriptIDs = Set(transcriptPassages.compactMap(\.segmentID))
        let graphSourceIDs = Set(factPage.facts.flatMap {
            $0.sources.compactMap(\.segmentID)
        })
        return selection.additionalGraphSourceCount
            == graphSourceIDs.subtracting(transcriptIDs).count
    }

    private static func hasExactUniquePassages(
        _ passages: [RAGPassage]
    ) -> Bool {
        guard !passages.isEmpty,
              passages.allSatisfy({ passage in
                  passage.segmentID != nil
                      && passage.timestamp.isFinite
                      && passage.timestamp >= 0
                      && passage.transcriptRevision.map { $0 >= 0 } == true
                      && !passage.meetingTitle.trimmingCharacters(
                          in: .whitespacesAndNewlines).isEmpty
                      && !passage.text.trimmingCharacters(
                          in: .whitespacesAndNewlines).isEmpty
              })
        else { return false }
        let ids = passages.compactMap(\.segmentID)
        return Set(ids).count == ids.count
    }
}

/// Provider-neutral fact-aware prompt construction. Foundation Models, MLX,
/// and remote-compatible adapters may consume the same admitted material, but
/// this formatter itself remains runnable on every supported macOS version.
enum RAGFactAnswerPrompt {
    static let instructions = """
        You answer questions about the user's own meetings using ONLY the numbered
        exact context segments and typed facts.
        \(PromptFactory.sourceMaterialGuard())
        Write a direct answer of one to three full sentences — never output a bare citation.
        Typed facts describe allowed relationships, but every answer claim must cite
        one or more exact source-segment markers.
        Never cite a fact marker by itself and never treat repeated graph
        relationships as stronger transcript relevance.
        After each claim, add the marker of the exact segment that supports it, e.g. "… media hora de latencia [T2]."
        If the fact-page disclosure says the page is incomplete, never claim that
        the result covers all or none of the user's meetings.
        If the context does not contain the answer, say so plainly — never guess.
        """

    static func make(
        question: String,
        context: RAGAnswerContext
    ) -> String {
        let transcript = transcriptPrompt(context.transcriptPassages)
        let transcriptMarkers = transcriptSourceMarkers(
            context.transcriptPassages)
        let graph = graphPrompt(
            facts: context.factPage.facts,
            transcriptMarkers: transcriptMarkers)
        return """
            Transcript passages:
            \(transcript.isEmpty ? "(none)" : transcript)

            Typed source-backed facts:
            \(graph.facts.isEmpty ? "(none)" : graph.facts)

            Exact graph source segments:
            \(graph.sources.isEmpty ? "(none)" : graph.sources)

            Fact page disclosure:
            \(factPageDisclosure(context.factPage))

            Context selection disclosure:
            \(selectionDisclosure(context.selection))

            Question: \(question)

            Answer with full sentences, in the same language as the question.
            Cite only [T…] and [S…] exact segment markers after supported claims; never cite [F…] alone.
            When complete=false, do not make exhaustive all/none claims.
            """
    }

    private static func transcriptPrompt(_ passages: [RAGPassage]) -> String {
        passages.enumerated().map { index, passage in
            "[T\(index + 1)] (\(passage.meetingTitle), "
                + "\(timestamp(passage.timestamp))) \(passage.text)"
        }.joined(separator: "\n")
    }

    /// Production calls `make` only after `isFactAwareReady`, which rejects
    /// duplicate segment IDs. Earliest-marker resolution keeps this pure
    /// formatter total for focused tests that intentionally bypass admission.
    private static func transcriptSourceMarkers(
        _ passages: [RAGPassage]
    ) -> [UUID: String] {
        Dictionary(
            passages.enumerated().compactMap { index, passage in
                passage.segmentID.map { ($0, "T\(index + 1)") }
            },
            uniquingKeysWith: { first, _ in first })
    }

    private static func graphPrompt(
        facts: [RAGFact],
        transcriptMarkers: [UUID: String]
    ) -> (facts: String, sources: String) {
        let graphSources = uniqueGraphSources(facts).filter { source in
            source.segmentID.map { transcriptMarkers[$0] == nil } ?? false
        }
        let sourceMarkers = Dictionary(
            graphSources.enumerated().compactMap { index, passage in
                passage.segmentID.map { ($0, "S\(index + 1)") }
            },
            uniquingKeysWith: { first, _ in first })
        let factPrompt = facts.enumerated().map { index, fact in
            let sources = fact.sources.compactMap { source in
                source.segmentID.flatMap { segmentID in
                    transcriptMarkers[segmentID] ?? sourceMarkers[segmentID]
                }
            }
            let primary = (
                transcriptMarkers[fact.primarySourceSegmentID]
                    ?? sourceMarkers[fact.primarySourceSegmentID]
            ).map { "[\($0)]" } ?? "[missing]"
            let sourceList = sources.map { "[\($0)]" }.joined(separator: ", ")
            return "[F\(index + 1)] relation=\(fact.kind.rawValue); "
                + "status=\(fact.status.rawValue); "
                + "subject=\"\(oneLine(fact.subjectText))\"; "
                + "object=\"\(oneLine(fact.objectText))\"; "
                + "occurredAt=\(isoDate(fact.occurredAt)); "
                + "primarySource=\(primary); sources=\(sourceList)"
        }.joined(separator: "\n")
        let sourcePrompt = graphSources.enumerated().map { index, passage in
            "[S\(index + 1)] (\(passage.meetingTitle), "
                + "\(timestamp(passage.timestamp))) \(passage.text)"
        }.joined(separator: "\n")
        return (factPrompt, sourcePrompt)
    }

    private static func factPageDisclosure(_ page: RAGFactPage) -> String {
        "complete=\(page.isComplete); "
            + "hasMore=\(page.hasMore); "
            + "projectionGeneration=\(page.projectionGeneration); "
            + "omittedStale=\(page.omittedStaleCount); "
            + "omittedUnavailable=\(page.omittedUnavailableCount); "
            + "selectionOmitted=\(page.selectionOmittedCount)"
    }

    private static func selectionDisclosure(
        _ selection: RAGAnswerSelectionDisclosure
    ) -> String {
        "transcriptCandidates=\(selection.transcriptCandidateCount); "
            + "selectedTranscript=\(selection.selectedTranscriptCount); "
            + "graphFactCandidates=\(selection.graphFactCandidateCount); "
            + "selectedGraphFacts=\(selection.selectedGraphFactCount); "
            + "additionalGraphSources="
            + "\(selection.additionalGraphSourceCount); "
            + "omittedGraphFacts=\(selection.omittedGraphFactCount)"
    }

    private static func timestamp(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    private static func uniqueGraphSources(_ facts: [RAGFact]) -> [RAGPassage] {
        var seen: Set<UUID> = []
        var sources: [RAGPassage] = []
        for fact in facts {
            for source in fact.sources {
                guard let segmentID = source.segmentID,
                      seen.insert(segmentID).inserted
                else { continue }
                sources.append(source)
            }
        }
        return sources
    }

    private static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).joined(separator: " ")
    }

    private static func isoDate(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
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
public struct RAGAnswerer: RAGTextAnswering {
    public init() {}

    public func answer(question: String, passages: [RAGPassage]) async throws -> String {
        if let reason = FoundationModelSummaryProvider.unavailabilityReason() {
            throw IntelligenceError.modelUnavailable(reason)
        }
        guard !passages.isEmpty else {
            return "No encuentro nada relacionado en tus reuniones."
        }

        let prompt = try RAGAnswerPrompt.make(
            question: question,
            passages: passages)

        let session = LanguageModelSession(
            instructions: RAGAnswerPrompt.instructions)
        return try await IntelligenceScheduler.shared.run(.interactive) {
            try await session.respond(
                to: prompt.user,
                options: GenerationOptions(
                    sampling: .greedy,
                    maximumResponseTokens: RAGAnswerPrompt.maximumResponseTokens)
            ).content
        }
    }

    /// Streams cumulative Foundation Models snapshots while the shared
    /// interactive scheduler retains single-flight model ownership.
    public func streamAnswer(
        question: String,
        passages: [RAGPassage],
        onSnapshot: @escaping @Sendable (String) async -> Void
    ) async throws -> String {
        if let reason = FoundationModelSummaryProvider.unavailabilityReason() {
            throw IntelligenceError.modelUnavailable(reason)
        }
        guard !passages.isEmpty else {
            return "No encuentro nada relacionado en tus reuniones."
        }

        let prompt = try RAGAnswerPrompt.make(
            question: question,
            passages: passages)
        let session = LanguageModelSession(
            instructions: RAGAnswerPrompt.instructions)
        return try await IntelligenceScheduler.shared.run(.interactive) {
            let stream = session.streamResponse(
                to: prompt.user,
                options: GenerationOptions(
                    sampling: .greedy,
                    maximumResponseTokens: RAGAnswerPrompt.maximumResponseTokens))
            var finalText = ""
            for try await snapshot in stream {
                try Task.checkCancellation()
                finalText = snapshot.content
                await onSnapshot(finalText)
            }
            try Task.checkCancellation()
            return finalText
        }
    }

    public func answer(
        question: String,
        webPassages: [RAGWebPassage]
    ) async throws -> String {
        if let reason = FoundationModelSummaryProvider.unavailabilityReason() {
            throw IntelligenceError.modelUnavailable(reason)
        }
        let prompt = try RAGWebAnswerPrompt.make(
            question: question,
            passages: webPassages)
        let session = LanguageModelSession(
            instructions: RAGWebAnswerPrompt.instructions)
        return try await IntelligenceScheduler.shared.run(.interactive) {
            try await session.respond(
                to: prompt.user,
                options: GenerationOptions(
                    sampling: .greedy,
                    maximumResponseTokens: RAGAnswerPrompt.maximumResponseTokens)
            ).content
        }
    }

    public func streamAnswer(
        question: String,
        webPassages: [RAGWebPassage],
        onSnapshot: @escaping @Sendable (String) async -> Void
    ) async throws -> String {
        if let reason = FoundationModelSummaryProvider.unavailabilityReason() {
            throw IntelligenceError.modelUnavailable(reason)
        }
        let prompt = try RAGWebAnswerPrompt.make(
            question: question,
            passages: webPassages)
        let session = LanguageModelSession(
            instructions: RAGWebAnswerPrompt.instructions)
        return try await IntelligenceScheduler.shared.run(.interactive) {
            let stream = session.streamResponse(
                to: prompt.user,
                options: GenerationOptions(
                    sampling: .greedy,
                    maximumResponseTokens: RAGAnswerPrompt.maximumResponseTokens))
            var finalText = ""
            for try await snapshot in stream {
                try Task.checkCancellation()
                finalText = snapshot.content
                await onSnapshot(finalText)
            }
            try Task.checkCancellation()
            return finalText
        }
    }

    public func answer(
        question: String,
        notePassages: [RAGNotePassage]
    ) async throws -> String {
        if let reason = FoundationModelSummaryProvider.unavailabilityReason() {
            throw IntelligenceError.modelUnavailable(reason)
        }
        let prompt = try RAGNoteAnswerPrompt.make(
            question: question,
            passages: notePassages)
        let session = LanguageModelSession(
            instructions: RAGNoteAnswerPrompt.instructions)
        return try await IntelligenceScheduler.shared.run(.interactive) {
            try await session.respond(
                to: prompt.user,
                options: GenerationOptions(
                    sampling: .greedy,
                    maximumResponseTokens: RAGAnswerPrompt.maximumResponseTokens)
            ).content
        }
    }

    /// Answers from separately typed transcript and graph lanes. Fact markers
    /// expose structure to the model, while only exact transcript/source
    /// markers are valid citations in generated prose.
    public func answer(
        question: String,
        context: RAGAnswerContext
    ) async throws -> String {
        if let reason = FoundationModelSummaryProvider.unavailabilityReason() {
            throw IntelligenceError.modelUnavailable(reason)
        }
        guard !context.transcriptPassages.isEmpty,
              !context.factPage.facts.isEmpty
        else {
            return "No encuentro nada relacionado en tus reuniones."
        }
        guard context.isFactAwareReady else {
            throw IntelligenceError.providerFailed(
                "RAG fact context lacks exact source provenance")
        }

        let prompt = RAGFactAnswerPrompt.make(
            question: question,
            context: context)
        let session = LanguageModelSession(
            instructions: RAGFactAnswerPrompt.instructions)
        return try await IntelligenceScheduler.shared.run(.interactive) {
            try await session.respond(
                to: prompt,
                options: GenerationOptions(
                    sampling: .greedy,
                    maximumResponseTokens: 500)
            ).content
        }
    }

    /// Multi-query expansion for cross-lingual retrieval: the library is
    /// bilingual, so a Spanish question must also search in English (and
    /// vice versa). Returns the original question plus up to two terse
    /// paraphrases; on any failure, just the original.
    public func expandQuery(_ question: String) async throws -> [String] {
        let session = LanguageModelSession(
            instructions: """
                Rewrite the user's question as exactly two terse keyword search queries \
                for a meeting transcript index: one in English and one in Spanish. \
                One per line, no numbering, no commentary.
                """)
        let content: String
        do {
            content = try await IntelligenceScheduler.shared.run(
                .interactive,
                operation: {
                    try await session.respond(
                        to: question,
                        options: GenerationOptions(sampling: .greedy, maximumResponseTokens: 60)
                    ).content
                })
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            return [question]
        }
        try Task.checkCancellation()
        let variants = content
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)) }
            .filter { !$0.isEmpty && $0.caseInsensitiveCompare(question) != .orderedSame }
        return [question] + variants.prefix(2)
    }

}
#endif
