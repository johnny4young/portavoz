import Foundation

/// The first source-backed product query over the disposable Meeting Memory
/// Graph. A caller provides an exact commitment identity; natural-language
/// identity discovery remains a separate retrieval concern.
public struct CommitmentBlockerQuery: Equatable, Sendable {
    public static let defaultItemLimit = 20
    public static let maximumItemLimit = 100

    public let commitmentID: CommitmentID
    public let itemLimit: Int

    public init(
        commitmentID: CommitmentID,
        itemLimit: Int = defaultItemLimit
    ) {
        self.commitmentID = commitmentID
        self.itemLimit = itemLimit
    }

    public var isValid: Bool {
        (1...Self.maximumItemLimit).contains(itemLimit)
    }
}

/// Finds the earliest explicitly confirmed discussion for one exact topic
/// identity. Label and natural-language resolution happen before this query.
public struct TopicFirstDiscussionQuery: Equatable, Sendable {
    public let topicID: TopicID

    public init(topicID: TopicID) {
        self.topicID = topicID
    }
}

public enum MeetingMemoryGraphFactID: Hashable, Sendable {
    case blocker(DecisionCommitmentBlockerID)
    case topicEvidence(TopicMeetingEvidenceID)
}

public enum MeetingMemoryGraphFactKind: String, Equatable, Sendable {
    case decisionBlocksCommitment = "decision-blocks-commitment"
    case topicDiscussedInMeeting = "topic-discussed-in-meeting"
}

public enum MeetingMemoryGraphFactEntity: Hashable, Sendable {
    case decision(DecisionID)
    case commitment(CommitmentID)
    case topic(TopicID)
    case meeting(MeetingID)
}

public enum MeetingMemoryGraphFactStatus: String, Equatable, Sendable {
    case active
    case confirmed
}

/// Graph queries and timelines share the same exact current transcript
/// evidence shape. This alias prevents a second subtly different provenance
/// contract while the older timeline-specific spelling remains source stable.
public typealias MeetingMemoryGraphEvidence = MeetingMemoryTimelineEvidence

public struct MeetingMemoryGraphFact: Equatable, Sendable, Identifiable {
    public let id: MeetingMemoryGraphFactID
    public let kind: MeetingMemoryGraphFactKind
    public let subject: MeetingMemoryGraphFactEntity
    public let object: MeetingMemoryGraphFactEntity
    public let subjectText: String
    public let objectText: String
    public let status: MeetingMemoryGraphFactStatus
    public let occurredAt: Date
    public let evidence: [MeetingMemoryGraphEvidence]
    public let primaryEvidenceSegmentID: UUID

    public init(
        id: MeetingMemoryGraphFactID,
        kind: MeetingMemoryGraphFactKind,
        subject: MeetingMemoryGraphFactEntity,
        object: MeetingMemoryGraphFactEntity,
        subjectText: String,
        objectText: String,
        status: MeetingMemoryGraphFactStatus,
        occurredAt: Date,
        evidence: [MeetingMemoryGraphEvidence],
        primaryEvidenceSegmentID: UUID
    ) {
        self.id = id
        self.kind = kind
        self.subject = subject
        self.object = object
        self.subjectText = subjectText
        self.objectText = objectText
        self.status = status
        self.occurredAt = occurredAt
        self.evidence = evidence
        self.primaryEvidenceSegmentID = primaryEvidenceSegmentID
    }

    public var navigation: MeetingMemoryTimelineNavigation? {
        evidence.first(where: { $0.segmentID == primaryEvidenceSegmentID }).map {
            MeetingMemoryTimelineNavigation(
                meetingID: $0.meetingID,
                segmentID: $0.segmentID,
                timestamp: $0.startTime)
        }
    }
}

public struct MeetingMemoryGraphFactPage: Equatable, Sendable {
    public let facts: [MeetingMemoryGraphFact]
    public let hasMore: Bool
    public let projectionGeneration: Int
    public let omittedStaleCount: Int
    public let omittedUnavailableCount: Int

    public init(
        facts: [MeetingMemoryGraphFact],
        hasMore: Bool,
        projectionGeneration: Int,
        omittedStaleCount: Int,
        omittedUnavailableCount: Int
    ) {
        self.facts = facts
        self.hasMore = hasMore
        self.projectionGeneration = projectionGeneration
        self.omittedStaleCount = omittedStaleCount
        self.omittedUnavailableCount = omittedUnavailableCount
    }
}

public enum MeetingMemoryGraphQueryAbstention: String, Equatable, Sendable {
    case invalidQuery = "invalid-query"
    case projectionNotReady = "projection-not-ready"
    case commitmentUnavailable = "commitment-unavailable"
    case topicUnavailable = "topic-unavailable"
    case projectionInconsistent = "projection-inconsistent"
    case unsupportedCausalLink = "unsupported-causal-link"
    case candidateBudgetExceeded = "candidate-budget-exceeded"
    case staleEvidenceOnly = "stale-evidence-only"
    case evidenceUnavailable = "evidence-unavailable"
}

public enum MeetingMemoryGraphQueryResult: Equatable, Sendable {
    case facts(MeetingMemoryGraphFactPage)
    case abstained(MeetingMemoryGraphQueryAbstention)
}
