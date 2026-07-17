import Foundation

/// A template that reshapes a meeting into a specific output: standup
/// debrief, 1:1 notes, technical decision record, interview feedback.
public struct Recipe: Codable, Sendable, Identifiable {
    public let id: String
    public let displayName: String
    public let sections: [String]
    public let instructions: String

    public init(id: String, displayName: String, sections: [String], instructions: String) {
        self.id = id
        self.displayName = displayName
        self.sections = sections
        self.instructions = instructions
    }

    /// The default general-purpose meeting recipe.
    public static let general = Recipe(
        id: "general",
        displayName: "General meeting",
        sections: ["Overview", "Decisions", "Action Items", "Open Questions"],
        // One-line prompt instruction.
        // swiftlint:disable:next line_length
        instructions: "Summarize the meeting faithfully. Attribute decisions and commitments to named speakers. Never invent content."
    )

    // Typed recipes (M13b): each reshapes the summary for one meeting kind.
    // Their ids double as the meeting-type classifier's label set.

    public static let standup = Recipe(
        id: "standup",
        displayName: "Standup",
        sections: ["Progress", "Blockers", "Next Up"],
        // One-line prompt instruction.
        // swiftlint:disable:next line_length
        instructions: "This is a daily standup. Group progress by the person who reported it. Blockers get their own section even when only hinted at. Never invent content."
    )

    public static let oneOnOne = Recipe(
        id: "one-on-one",
        displayName: "1:1",
        sections: ["Topics", "Feedback", "Agreements"],
        // One-line prompt instruction.
        // swiftlint:disable:next line_length
        instructions: "This is a one-on-one conversation. Capture the topics discussed, feedback exchanged in both directions, and the concrete agreements. Keep sensitive wording faithful. Never invent content."
    )

    public static let planning = Recipe(
        id: "planning",
        displayName: "Planning",
        sections: ["Goals", "Scope Decisions", "Risks", "Next Steps"],
        // One-line prompt instruction.
        // swiftlint:disable:next line_length
        instructions: "This is a planning session. State the goals, what was decided in or out of scope, the risks raised, and the concrete next steps with owners. Never invent content."
    )

    public static let interview = Recipe(
        id: "interview",
        displayName: "Interview",
        sections: ["Background", "Strengths", "Concerns", "Next Steps"],
        // One-line prompt instruction.
        // swiftlint:disable:next line_length
        instructions: "This is an interview. Summarize the candidate's background, observed strengths, concerns raised, and agreed next steps. Attribute opinions to who voiced them. Never invent content."
    )

    public static let all: [Recipe] = [.general, .standup, .oneOnOne, .planning, .interview]

    public static func byID(_ id: String) -> Recipe? {
        all.first { $0.id == id }
    }

    /// Section positions whose bullets are decisions rather than general
    /// narrative. Only built-ins have explicit semantics; custom structures
    /// stay unclassified until their schema can declare a kind directly.
    public var decisionSectionIndexes: [Int] {
        switch id {
        case Self.general.id, Self.planning.id:
            [1]
        case Self.oneOnOne.id:
            [2]
        default:
            []
        }
    }

    /// Prefix that marks a user-authored structure, distinguishing it from
    /// the five built-ins.
    public static let customIDPrefix = "custom-"

    /// Whether an id refers to a user-authored structure.
    public static func isCustom(_ id: String) -> Bool { id.hasPrefix(customIDPrefix) }

    /// Builds a user-authored structure from raw input — trimmed name, one
    /// section per non-empty line, a reused id when editing (a fresh
    /// `custom-` id otherwise), and a safe default instruction when the user
    /// leaves it blank. Returns nil when the name or every section is empty.
    public static func custom(
        id existingID: String? = nil,
        name: String,
        sectionsText: String,
        instructions: String
    ) -> Recipe? {
        let displayName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let sections = sectionsText
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !displayName.isEmpty, !sections.isEmpty else { return nil }
        let trimmed = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        return Recipe(
            id: existingID ?? customIDPrefix + UUID().uuidString,
            displayName: displayName,
            sections: sections,
            instructions: trimmed.isEmpty
                ? "Summarize the meeting faithfully into the sections above. "
                    + "Attribute decisions and commitments to named speakers. Never invent content."
                : trimmed)
    }
}

/// The result of a summarization pass. Stored as an immutable versioned
/// snapshot — sharing always references a version, never a mutable row.
public struct SummaryDraft: Codable, Sendable {
    public let meetingID: MeetingID
    public let recipeID: String
    public let language: String
    public let markdown: String
    public let actionItems: [ActionItem]
    /// Typed, source-fenced provenance for generated claims. Band 5B starts
    /// deliberately narrow with the overview; later artifact kinds must earn
    /// their own domain shape instead of growing a generic EAV store.
    public let claims: [SummaryClaim]
    /// Exact transcript support for individual bullets in decision-bearing
    /// sections. Positions refer to the rendered, nonempty `##` sections.
    public let decisionEvidence: [SummaryDecisionEvidence]
    /// Identity of the summarized MATERIAL + method (D25), language
    /// EXCLUDED — a snapshot with the same fingerprint in another language
    /// is a valid translation pivot. nil on pre-jul-2026 snapshots (they
    /// simply never match).
    public var fingerprint: String?

    public init(
        meetingID: MeetingID, recipeID: String, language: String, markdown: String,
        actionItems: [ActionItem], fingerprint: String? = nil,
        claims: [SummaryClaim] = [],
        decisionEvidence: [SummaryDecisionEvidence] = []
    ) {
        self.meetingID = meetingID
        self.recipeID = recipeID
        self.language = language
        self.markdown = markdown
        self.actionItems = actionItems
        self.fingerprint = fingerprint
        self.claims = claims
        self.decisionEvidence = decisionEvidence
    }

    private enum CodingKeys: String, CodingKey {
        case meetingID, recipeID, language, markdown, actionItems, fingerprint, claims
        case decisionEvidence
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        meetingID = try container.decode(MeetingID.self, forKey: .meetingID)
        recipeID = try container.decode(String.self, forKey: .recipeID)
        language = try container.decode(String.self, forKey: .language)
        markdown = try container.decode(String.self, forKey: .markdown)
        actionItems = try container.decode([ActionItem].self, forKey: .actionItems)
        fingerprint = try container.decodeIfPresent(String.self, forKey: .fingerprint)
        claims = try container.decodeIfPresent([SummaryClaim].self, forKey: .claims) ?? []
        decisionEvidence = try container.decodeIfPresent(
            [SummaryDecisionEvidence].self,
            forKey: .decisionEvidence) ?? []
    }
}

/// The generated statement that the first evidence vertical can prove.
public enum SummaryClaimKind: String, Codable, Sendable {
    case overview
}

/// The user's current assessment of one generated claim.
///
/// This state is deliberately separate from generated Markdown: correcting or
/// rejecting a claim never rewrites model output, enters another prompt, or
/// becomes hidden training history. One claim has at most one reversible
/// assessment, which explicit `.portavoz` export carries with the claim.
public enum SummaryClaimFeedbackKind: String, Codable, Sendable {
    case correction
    case unsupported
}

public struct SummaryClaimFeedback: Codable, Equatable, Sendable {
    public static let maximumCorrectionLength = 2_000

    public let kind: SummaryClaimFeedbackKind
    public let correctionText: String?

    public static func correction(_ text: String) -> SummaryClaimFeedback? {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty,
              normalized.unicodeScalars.count <= maximumCorrectionLength
        else {
            return nil
        }
        return SummaryClaimFeedback(kind: .correction, correctionText: normalized)
    }

    public static let unsupported = SummaryClaimFeedback(
        kind: .unsupported,
        correctionText: nil)

    private init(kind: SummaryClaimFeedbackKind, correctionText: String?) {
        self.kind = kind
        self.correctionText = correctionText
    }

    private enum CodingKeys: String, CodingKey {
        case kind, correctionText
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(SummaryClaimFeedbackKind.self, forKey: .kind)
        let correctionText = try container.decodeIfPresent(String.self, forKey: .correctionText)
        switch kind {
        case .correction:
            guard let feedback = correctionText.flatMap(Self.correction) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .correctionText,
                    in: container,
                    debugDescription: "correction feedback must contain 1...2000 characters")
            }
            self = feedback
        case .unsupported:
            guard correctionText == nil else {
                throw DecodingError.dataCorruptedError(
                    forKey: .correctionText,
                    in: container,
                    debugDescription: "unsupported feedback cannot contain correction text")
            }
            self = .unsupported
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encodeIfPresent(correctionText, forKey: .correctionText)
    }
}

/// Ordered transcript evidence for one generated claim.
///
/// `sourceTranscriptRevision` is nil while a provider result is in memory;
/// StorageKit validates the references and stamps the current revision in the
/// same transaction as the immutable summary snapshot.
public struct SummaryClaim: Codable, Sendable, Identifiable {
    public let id: SummaryClaimID
    public let kind: SummaryClaimKind
    public let sourceTranscriptRevision: Int?
    public let evidenceSegmentIDs: [UUID]
    /// Links become NULL when their segment is physically removed. Keeping a
    /// count lets the UI fail closed without manufacturing replacement IDs.
    public let unavailableEvidenceCount: Int
    /// User-owned mutable metadata loaded beside this immutable generated
    /// claim. Providers and translation pivots always create claims with nil.
    public let feedback: SummaryClaimFeedback?

    public init(
        id: SummaryClaimID = SummaryClaimID(),
        kind: SummaryClaimKind,
        sourceTranscriptRevision: Int? = nil,
        evidenceSegmentIDs: [UUID],
        unavailableEvidenceCount: Int = 0,
        feedback: SummaryClaimFeedback? = nil
    ) {
        self.id = id
        self.kind = kind
        self.sourceTranscriptRevision = sourceTranscriptRevision
        self.evidenceSegmentIDs = evidenceSegmentIDs
        self.unavailableEvidenceCount = unavailableEvidenceCount
        self.feedback = feedback
    }
}

/// Typed provenance for one decision bullet in the rendered summary.
///
/// The generated text remains owned by immutable Markdown. These coordinates
/// identify that exact displayed bullet without duplicating or rewriting it.
public struct SummaryDecisionEvidence: Codable, Sendable, Identifiable {
    public let id: SummaryDecisionID
    public let sectionOrdinal: Int
    public let bulletOrdinal: Int
    public let sourceTranscriptRevision: Int?
    public let evidenceSegmentIDs: [UUID]
    public let unavailableEvidenceCount: Int

    public init(
        id: SummaryDecisionID = SummaryDecisionID(),
        sectionOrdinal: Int,
        bulletOrdinal: Int,
        sourceTranscriptRevision: Int? = nil,
        evidenceSegmentIDs: [UUID],
        unavailableEvidenceCount: Int = 0
    ) {
        self.id = id
        self.sectionOrdinal = sectionOrdinal
        self.bulletOrdinal = bulletOrdinal
        self.sourceTranscriptRevision = sourceTranscriptRevision
        self.evidenceSegmentIDs = evidenceSegmentIDs
        self.unavailableEvidenceCount = unavailableEvidenceCount
    }
}

public enum SummaryClaimEvidenceStatus: Sendable, Equatable {
    case current
    case stale
    case unavailable
}

public struct SummaryClaimEvidenceResolution: Sendable {
    public let status: SummaryClaimEvidenceStatus
    public let segments: [TranscriptSegment]

    public init(status: SummaryClaimEvidenceStatus, segments: [TranscriptSegment] = []) {
        self.status = status
        self.segments = segments
    }
}

extension SummaryClaim {
    /// Resolves links against one coherent Meeting Detail read model. A stale
    /// revision or any missing/tombstoned link disables every jump: partial
    /// citations would imply stronger provenance than Portavoz can prove.
    public func resolveEvidence(
        currentTranscriptRevision: Int,
        segments: [TranscriptSegment]
    ) -> SummaryClaimEvidenceResolution {
        resolveSummaryEvidence(
            sourceTranscriptRevision: sourceTranscriptRevision,
            evidenceSegmentIDs: evidenceSegmentIDs,
            unavailableEvidenceCount: unavailableEvidenceCount,
            currentTranscriptRevision: currentTranscriptRevision,
            segments: segments)
    }
}

extension SummaryDecisionEvidence {
    public func resolveEvidence(
        currentTranscriptRevision: Int,
        segments: [TranscriptSegment]
    ) -> SummaryClaimEvidenceResolution {
        resolveSummaryEvidence(
            sourceTranscriptRevision: sourceTranscriptRevision,
            evidenceSegmentIDs: evidenceSegmentIDs,
            unavailableEvidenceCount: unavailableEvidenceCount,
            currentTranscriptRevision: currentTranscriptRevision,
            segments: segments)
    }
}

private func resolveSummaryEvidence(
    sourceTranscriptRevision: Int?,
    evidenceSegmentIDs: [UUID],
    unavailableEvidenceCount: Int,
    currentTranscriptRevision: Int,
    segments: [TranscriptSegment]
) -> SummaryClaimEvidenceResolution {
    guard let sourceTranscriptRevision else {
        return SummaryClaimEvidenceResolution(status: .unavailable)
    }
    guard sourceTranscriptRevision == currentTranscriptRevision else {
        return SummaryClaimEvidenceResolution(status: .stale)
    }
    guard unavailableEvidenceCount == 0, !evidenceSegmentIDs.isEmpty else {
        return SummaryClaimEvidenceResolution(status: .unavailable)
    }
    let byID = Dictionary(uniqueKeysWithValues: segments.map { ($0.id, $0) })
    let resolved = evidenceSegmentIDs.compactMap { byID[$0] }
    guard resolved.count == evidenceSegmentIDs.count else {
        return SummaryClaimEvidenceResolution(status: .unavailable)
    }
    return SummaryClaimEvidenceResolution(status: .current, segments: resolved)
}

public struct ActionItem: Codable, Sendable, Identifiable {
    public let id: UUID
    public var text: String
    /// The speaker who owns the commitment, when attribution is possible.
    public var ownerSpeakerID: SpeakerID?
    public var isDone: Bool

    public init(id: UUID = UUID(), text: String, ownerSpeakerID: SpeakerID? = nil, isDone: Bool = false) {
        self.id = id
        self.text = text
        self.ownerSpeakerID = ownerSpeakerID
        self.isDone = isDone
    }
}
