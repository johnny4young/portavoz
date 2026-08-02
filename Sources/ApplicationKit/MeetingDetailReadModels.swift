import Foundation
import PortavozCore

/// Storage-independent transcript/cast root for one live meeting.
public struct MeetingReviewCore: Sendable {
    public let meeting: Meeting
    public let speakers: [Speaker]
    public let segments: [TranscriptSegment]
    public let corrections: [TranscriptCorrectionEvent]
    public let correctionRevision: TranscriptCorrectionRevision
    public let isRefinedTranscript: Bool

    public init(
        meeting: Meeting,
        speakers: [Speaker],
        segments: [TranscriptSegment],
        corrections: [TranscriptCorrectionEvent] = [],
        correctionRevision: TranscriptCorrectionRevision? = nil,
        isRefinedTranscript: Bool = false
    ) {
        self.meeting = meeting
        self.speakers = speakers
        self.segments = segments
        self.corrections = corrections
        self.correctionRevision = correctionRevision ?? Self.derivedCorrectionRevision(
            meeting: meeting,
            corrections: corrections)
        self.isRefinedTranscript = isRefinedTranscript
    }

    private static func derivedCorrectionRevision(
        meeting: Meeting,
        corrections: [TranscriptCorrectionEvent]
    ) -> TranscriptCorrectionRevision {
        guard !corrections.isEmpty else { return .accepted }
        return (try? TranscriptCorrectionRevision.current(
            meetingID: meeting.id,
            baseTranscriptRevision: meeting.transcriptRevision,
            history: corrections)) ?? .unavailable
    }
}

/// The newest immutable summary selected across every recipe.
public struct MeetingReviewSummary: Sendable {
    public let draft: SummaryDraft
    public let version: Int
    public let correctionSource: TranscriptCorrectionArtifactSource

    public init(
        draft: SummaryDraft,
        version: Int,
        correctionSource: TranscriptCorrectionArtifactSource = .legacyAccepted
    ) {
        self.draft = draft
        self.version = version
        self.correctionSource = correctionSource
    }
}

public enum DerivedArtifactFreshness: Equatable, Sendable {
    case current
    case stale
}

/// One coherent presentation projection for Meeting Detail.
///
/// Sections are observed independently so degradable summary, Companion, or
/// privacy/processing evidence never hides a healthy transcript/cast root.
public struct MeetingReviewReadModel: Sendable {
    public let core: MeetingReviewCore
    public let summary: MeetingReviewSummary?
    public let companionCards: [CompanionCard]
    public let companionCorrectionSources: [UUID: TranscriptCorrectionArtifactSource]
    public let privacyReceipt: PrivacyReceipt?
    public let processingJobs: [ProcessingJob]
    public let notes: MeetingReviewNotes

    public init(
        core: MeetingReviewCore,
        summary: MeetingReviewSummary?,
        companionCards: [CompanionCard],
        companionCorrectionSources: [UUID: TranscriptCorrectionArtifactSource] = [:],
        privacyReceipt: PrivacyReceipt?,
        processingJobs: [ProcessingJob],
        notes: MeetingReviewNotes = MeetingReviewNotes()
    ) {
        self.core = core
        self.summary = summary
        self.companionCards = companionCards
        self.companionCorrectionSources = companionCorrectionSources
        self.privacyReceipt = privacyReceipt
        self.processingJobs = processingJobs
        self.notes = notes
    }

    public var meeting: Meeting { core.meeting }
    public var speakers: [Speaker] { core.speakers }
    public var segments: [TranscriptSegment] { core.segments }
    public var corrections: [TranscriptCorrectionEvent] { core.corrections }
    public var correctionRevision: TranscriptCorrectionRevision {
        core.correctionRevision
    }

    public var summaryFreshness: DerivedArtifactFreshness {
        guard let summary else { return .current }
        return summary.correctionSource.matches(correctionRevision) ? .current : .stale
    }

    public func companionFreshness(_ card: CompanionCard) -> DerivedArtifactFreshness {
        let source = companionCorrectionSources[card.id] ?? .legacyAccepted
        return source.matches(correctionRevision) ? .current : .stale
    }
}

/// The user's own notes for one meeting: the raw timestamped context items
/// plus the optional LLM-enhanced document (NOTES-001). Independent from
/// the transcript root like every other degradable section.
public struct MeetingReviewNotes: Sendable {
    public let contextItems: [ContextItem]
    public let enhanced: EnhancedNote?

    public init(
        contextItems: [ContextItem] = [],
        enhanced: EnhancedNote? = nil
    ) {
        self.contextItems = contextItems
        self.enhanced = enhanced
    }
}

public enum MeetingReviewSection: CaseIterable, Hashable, Sendable {
    case core
    case summary
    case companion
    case privacy
    case processing
    case notes
}

/// Independent updates emitted by the Meeting Detail read side.
public enum MeetingReviewUpdate: Sendable {
    /// `nil` means the meeting is absent or tombstoned.
    case core(MeetingReviewCore?)
    case summary(MeetingReviewSummary?)
    case companionCards(
        [CompanionCard],
        correctionSources: [UUID: TranscriptCorrectionArtifactSource] = [:])
    case privacyReceipt(PrivacyReceipt?)
    case processingJobs([ProcessingJob])
    case notes(MeetingReviewNotes)
    case failed(MeetingReviewSection)
}
