import Foundation

/// One answered question the live Companion surfaced during a recording,
/// kept so it can be reviewed on the meeting afterward. `source` names who
/// produced the answer ("on-device" today; the BYOK provider when it
/// exists) — the disclosure D26 demands. Lives in Core (not IntelligenceKit)
/// because StorageKit persists it, mirroring `ContextItem`; the pipeline
/// that produces it stays in IntelligenceKit.
public struct CompanionCard: Codable, Identifiable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case knowledge
        case context
    }

    public let id: UUID
    public let question: String
    /// Empty on a pure "asked you" ping — the question itself is the
    /// whole value; the UI hides the answer block.
    public let answer: String
    public let kind: Kind
    public let source: String
    /// True when the caption addressed the device owner BY NAME (D26's
    /// "asked you"): the card doubles as an attention ping.
    public let directed: Bool
    /// Seconds since the meeting started, aligning the card with the transcript.
    public let askedAt: TimeInterval
    /// Additive typed provenance. Older cards and knowledge-only artifacts may
    /// have no transcript evidence and continue to use `askedAt` for playback.
    public let evidence: CompanionCardEvidence?

    public init(
        id: UUID = UUID(),
        question: String,
        answer: String,
        kind: Kind,
        source: String,
        directed: Bool = false,
        askedAt: TimeInterval,
        evidence: CompanionCardEvidence? = nil
    ) {
        self.id = id
        self.question = question
        self.answer = answer
        self.kind = kind
        self.source = source
        self.directed = directed
        self.askedAt = askedAt
        self.evidence = evidence
    }

    public func withEvidence(_ evidence: CompanionCardEvidence?) -> CompanionCard {
        CompanionCard(
            id: id,
            question: question,
            answer: answer,
            kind: kind,
            source: source,
            directed: directed,
            askedAt: askedAt,
            evidence: evidence)
    }
}

/// Role-typed transcript provenance for one immutable Companion card.
///
/// Question sources identify what triggered the card. Answer sources exist
/// only when a context answer cited prior passages from this meeting; knowledge
/// answers and directed pings intentionally keep that role empty.
public struct CompanionCardEvidence: Codable, Sendable, Equatable, Identifiable {
    public let id: CompanionCardEvidenceID
    public let cardID: UUID
    public let sourceTranscriptRevision: Int?
    public let questionSegmentIDs: [UUID]
    public let answerSegmentIDs: [UUID]
    public let unavailableQuestionCount: Int
    public let unavailableAnswerCount: Int

    public init(
        id: CompanionCardEvidenceID = CompanionCardEvidenceID(),
        cardID: UUID,
        sourceTranscriptRevision: Int? = nil,
        questionSegmentIDs: [UUID],
        answerSegmentIDs: [UUID] = [],
        unavailableQuestionCount: Int = 0,
        unavailableAnswerCount: Int = 0
    ) {
        self.id = id
        self.cardID = cardID
        self.sourceTranscriptRevision = sourceTranscriptRevision
        self.questionSegmentIDs = questionSegmentIDs
        self.answerSegmentIDs = answerSegmentIDs
        self.unavailableQuestionCount = unavailableQuestionCount
        self.unavailableAnswerCount = unavailableAnswerCount
    }

    public func resolveQuestion(
        currentTranscriptRevision: Int,
        segments: [TranscriptSegment]
    ) -> TranscriptEvidenceResolution {
        resolveTranscriptEvidence(
            sourceTranscriptRevision: sourceTranscriptRevision,
            evidenceSegmentIDs: questionSegmentIDs,
            unavailableEvidenceCount: unavailableQuestionCount,
            currentTranscriptRevision: currentTranscriptRevision,
            segments: segments)
    }

    public func resolveAnswer(
        currentTranscriptRevision: Int,
        segments: [TranscriptSegment]
    ) -> TranscriptEvidenceResolution? {
        guard !answerSegmentIDs.isEmpty || unavailableAnswerCount > 0 else { return nil }
        return resolveTranscriptEvidence(
            sourceTranscriptRevision: sourceTranscriptRevision,
            evidenceSegmentIDs: answerSegmentIDs,
            unavailableEvidenceCount: unavailableAnswerCount,
            currentTranscriptRevision: currentTranscriptRevision,
            segments: segments)
    }
}

/// One generated Companion artifact and the exact successful model operation
/// that produced it. Persistence links both atomically; UI still renders only
/// the card value.
public struct CompanionGenerationArtifact: Equatable, Sendable {
    public let card: CompanionCard
    public let generationRun: GenerationRun

    public init(card: CompanionCard, generationRun: GenerationRun) {
        self.card = card
        self.generationRun = generationRun
    }
}
