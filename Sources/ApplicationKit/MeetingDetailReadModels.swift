import Foundation
import PortavozCore

/// Storage-independent transcript/cast root for one live meeting.
public struct MeetingReviewCore: Sendable {
    public let meeting: Meeting
    public let speakers: [Speaker]
    public let segments: [TranscriptSegment]

    public init(
        meeting: Meeting,
        speakers: [Speaker],
        segments: [TranscriptSegment]
    ) {
        self.meeting = meeting
        self.speakers = speakers
        self.segments = segments
    }
}

/// The newest immutable summary selected across every recipe.
public struct MeetingReviewSummary: Sendable {
    public let draft: SummaryDraft
    public let version: Int

    public init(draft: SummaryDraft, version: Int) {
        self.draft = draft
        self.version = version
    }
}

/// One coherent presentation projection for Meeting Detail.
///
/// Sections are observed independently so degradable summary, Companion, or
/// privacy evidence never hides a healthy transcript/cast root.
public struct MeetingReviewReadModel: Sendable {
    public let core: MeetingReviewCore
    public let summary: MeetingReviewSummary?
    public let companionCards: [CompanionCard]
    public let privacyReceipt: PrivacyReceipt?

    public init(
        core: MeetingReviewCore,
        summary: MeetingReviewSummary?,
        companionCards: [CompanionCard],
        privacyReceipt: PrivacyReceipt?
    ) {
        self.core = core
        self.summary = summary
        self.companionCards = companionCards
        self.privacyReceipt = privacyReceipt
    }

    public var meeting: Meeting { core.meeting }
    public var speakers: [Speaker] { core.speakers }
    public var segments: [TranscriptSegment] { core.segments }
}

public enum MeetingReviewSection: CaseIterable, Hashable, Sendable {
    case core
    case summary
    case companion
    case privacy
}

/// Independent updates emitted by the Meeting Detail read side.
public enum MeetingReviewUpdate: Sendable {
    /// `nil` means the meeting is absent or tombstoned.
    case core(MeetingReviewCore?)
    case summary(MeetingReviewSummary?)
    case companionCards([CompanionCard])
    case privacyReceipt(PrivacyReceipt?)
    case failed(MeetingReviewSection)
}
