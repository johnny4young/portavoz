import Foundation

public enum CommitmentReviewQueueScope: Sendable, Equatable {
    case library
    case meetings([MeetingID])
}

public enum CommitmentReviewQueueReason: Sendable, Equatable {
    case newAfterMeeting
    case deferredDue(revisitAt: Date)
}

public struct CommitmentReviewQueueOwner: Sendable, Equatable {
    public let personID: PersonID
    public let displayName: String

    public init(personID: PersonID, displayName: String) {
        self.personID = personID
        self.displayName = displayName
    }
}

/// One generated action item that is ready for explicit human review.
///
/// This is a bounded read-model value, not commitment truth. `evidence`
/// describes the complete source's freshness, while `segments` may contain
/// only the bounded preview reported by `evidenceCount`/`hasMoreEvidence`.
/// Confirmation must therefore reopen the source in Meeting Detail; this value
/// cannot create reminders, continuity, or external work by itself.
public struct CommitmentReviewQueueItem: Sendable, Identifiable {
    public var id: UUID { actionItem.id }

    public let meetingID: MeetingID
    public let meetingTitle: String
    public let meetingStartedAt: Date
    public let meetingEndedAt: Date
    public let actionItem: ActionItem
    public let evidence: TranscriptEvidenceResolution
    public let evidenceCount: Int
    public let suggestedOwner: CommitmentReviewQueueOwner?
    public let reason: CommitmentReviewQueueReason

    public var hasMoreEvidence: Bool {
        evidenceCount > evidence.segments.count
    }

    public init(
        meetingID: MeetingID,
        meetingTitle: String,
        meetingStartedAt: Date,
        meetingEndedAt: Date,
        actionItem: ActionItem,
        evidence: TranscriptEvidenceResolution,
        evidenceCount: Int,
        suggestedOwner: CommitmentReviewQueueOwner?,
        reason: CommitmentReviewQueueReason
    ) {
        self.meetingID = meetingID
        self.meetingTitle = meetingTitle
        self.meetingStartedAt = meetingStartedAt
        self.meetingEndedAt = meetingEndedAt
        self.actionItem = actionItem
        self.evidence = evidence
        self.evidenceCount = evidenceCount
        self.suggestedOwner = suggestedOwner
        self.reason = reason
    }
}

public struct CommitmentReviewQueuePage: Sendable {
    public let items: [CommitmentReviewQueueItem]
    public let totalCount: Int

    public var hasMore: Bool { totalCount > items.count }

    public init(items: [CommitmentReviewQueueItem], totalCount: Int) {
        self.items = items
        self.totalCount = totalCount
    }
}

public enum CommitmentReviewQueueQueryError: Error, Sendable, Equatable {
    case invalidReviewDate
    case invalidLimit
    case invalidMeetingScope
}

/// A concrete, bounded queue query. Application policy supplies the sampled
/// review date so persistence never reads the clock or invents "review now".
public struct CommitmentReviewQueueQuery: Sendable, Equatable {
    public static let maximumItemCount = 100
    public static let maximumEvidenceCount = 20
    public static let maximumMeetingScopeCount = 50

    public let scope: CommitmentReviewQueueScope
    public let reviewAt: Date
    public let itemLimit: Int
    public let evidenceLimitPerItem: Int

    public init(
        scope: CommitmentReviewQueueScope = .library,
        reviewAt: Date,
        itemLimit: Int = 50,
        evidenceLimitPerItem: Int = 3
    ) throws {
        guard reviewAt.timeIntervalSinceReferenceDate.isFinite else {
            throw CommitmentReviewQueueQueryError.invalidReviewDate
        }
        guard (1...Self.maximumItemCount).contains(itemLimit),
              (1...Self.maximumEvidenceCount).contains(evidenceLimitPerItem)
        else { throw CommitmentReviewQueueQueryError.invalidLimit }
        if case .meetings(let meetingIDs) = scope {
            guard meetingIDs.count <= Self.maximumMeetingScopeCount,
                  Set(meetingIDs).count == meetingIDs.count
            else { throw CommitmentReviewQueueQueryError.invalidMeetingScope }
        }

        self.scope = scope
        self.reviewAt = reviewAt
        self.itemLimit = itemLimit
        self.evidenceLimitPerItem = evidenceLimitPerItem
    }
}
