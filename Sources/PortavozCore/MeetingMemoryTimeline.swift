import Foundation

/// One exact, user-confirmed graph subject. Display-name or topic-label
/// matching belongs to a separate discovery boundary; timeline reads never
/// guess which identity the caller meant.
public enum MeetingMemoryTimelineSubject: Hashable, Sendable {
    case person(PersonID)
    case topic(TopicID)
}

/// A bounded "since last time" read. When `throughMeetingID` is nil, the
/// latest meeting connected to the subject becomes the anchor.
public struct MeetingMemoryTimelineQuery: Equatable, Sendable {
    public static let defaultItemLimit = 50
    public static let maximumItemLimit = 100

    public let subject: MeetingMemoryTimelineSubject
    public let throughMeetingID: MeetingID?
    public let itemLimit: Int

    public init(
        subject: MeetingMemoryTimelineSubject,
        throughMeetingID: MeetingID? = nil,
        itemLimit: Int = defaultItemLimit
    ) {
        self.subject = subject
        self.throughMeetingID = throughMeetingID
        self.itemLimit = itemLimit
    }

    public var isValid: Bool {
        (1...Self.maximumItemLimit).contains(itemLimit)
    }
}

public struct MeetingMemoryTimelineMeeting: Equatable, Sendable, Identifiable {
    public let id: MeetingID
    public let title: String
    public let startedAt: Date

    public init(id: MeetingID, title: String, startedAt: Date) {
        self.id = id
        self.title = title
        self.startedAt = startedAt
    }
}

public enum MeetingMemoryTimelineItemKind: String, CaseIterable, Hashable, Sendable {
    case decisionConfirmed = "decision-confirmed"
    case decisionSuperseded = "decision-superseded"
    case decisionReversed = "decision-reversed"
    case commitmentConfirmed = "commitment-confirmed"
    case commitmentReassigned = "commitment-reassigned"
    case commitmentRescheduled = "commitment-rescheduled"
    case commitmentCompleted = "commitment-completed"
    case commitmentReopened = "commitment-reopened"
    case commitmentDismissed = "commitment-dismissed"
    case unresolvedQuestion = "unresolved-question"
    case questionResolved = "question-resolved"
    case questionReopened = "question-reopened"
    case questionDismissed = "question-dismissed"
    case commitmentBlocked = "commitment-blocked"
    case commitmentUnblocked = "commitment-unblocked"
    case commitmentBlockerReopened = "commitment-blocker-reopened"
}

public enum MeetingMemoryTimelineOrigin: String, Sendable {
    case confirmed
}

public enum MeetingMemoryTimelineEntity: Hashable, Sendable {
    case decision(DecisionID)
    case commitment(CommitmentID)
    case question(MeetingQuestionID)
}

/// Structured commitment state carried by a source-backed timeline item.
/// Consumers never need to parse a generated sentence to recover the change.
public enum MeetingMemoryTimelineCommitmentChange: Equatable, Sendable {
    case reassigned(CommitmentAssignee)
    case rescheduled(Date?)
    case completed
    case reopened
    case dismissed
}

public enum MeetingMemoryTimelineQuestionChange: Equatable, Sendable {
    case opened
    case resolved
    case reopened
    case dismissed
}

public enum MeetingMemoryTimelineBlockerChange: Equatable, Sendable {
    case blocked
    case cleared
    case reopened
}

/// Current accepted transcript material that supports one timeline fact.
/// Carrying the exact segment text helps future UI and Ask consumers without
/// granting either layer permission to re-read stale or corrected material.
public struct MeetingMemoryTimelineEvidence: Equatable, Sendable, Identifiable {
    public var id: UUID { segmentID }

    public let meetingID: MeetingID
    public let meetingTitle: String
    public let meetingStartedAt: Date
    public let transcriptRevision: Int
    public let segmentID: UUID
    public let startTime: TimeInterval
    public let endTime: TimeInterval
    public let text: String
    public let language: String?

    public init(
        meetingID: MeetingID,
        meetingTitle: String,
        meetingStartedAt: Date,
        transcriptRevision: Int,
        segmentID: UUID,
        startTime: TimeInterval,
        endTime: TimeInterval,
        text: String,
        language: String?
    ) {
        self.meetingID = meetingID
        self.meetingTitle = meetingTitle
        self.meetingStartedAt = meetingStartedAt
        self.transcriptRevision = transcriptRevision
        self.segmentID = segmentID
        self.startTime = startTime
        self.endTime = endTime
        self.text = text
        self.language = language
    }
}

public struct MeetingMemoryTimelineNavigation: Equatable, Sendable {
    public let meetingID: MeetingID
    public let segmentID: UUID
    public let timestamp: TimeInterval

    public init(meetingID: MeetingID, segmentID: UUID, timestamp: TimeInterval) {
        self.meetingID = meetingID
        self.segmentID = segmentID
        self.timestamp = timestamp
    }
}

/// A fact-shaped item, never generated narrative. `text` and `relatedText`
/// retain exact authoritative wording, while evidence owns navigation.
public struct MeetingMemoryTimelineItem: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let kind: MeetingMemoryTimelineItemKind
    public let entity: MeetingMemoryTimelineEntity
    public let relatedEntity: MeetingMemoryTimelineEntity?
    public let text: String
    public let relatedText: String?
    public let commitmentChange: MeetingMemoryTimelineCommitmentChange?
    public let questionChange: MeetingMemoryTimelineQuestionChange?
    public let blockerChange: MeetingMemoryTimelineBlockerChange?
    public let origin: MeetingMemoryTimelineOrigin
    public let occurredAt: Date
    public let evidence: [MeetingMemoryTimelineEvidence]

    public init(
        id: UUID,
        kind: MeetingMemoryTimelineItemKind,
        entity: MeetingMemoryTimelineEntity,
        relatedEntity: MeetingMemoryTimelineEntity? = nil,
        text: String,
        relatedText: String? = nil,
        commitmentChange: MeetingMemoryTimelineCommitmentChange? = nil,
        questionChange: MeetingMemoryTimelineQuestionChange? = nil,
        blockerChange: MeetingMemoryTimelineBlockerChange? = nil,
        origin: MeetingMemoryTimelineOrigin,
        occurredAt: Date,
        evidence: [MeetingMemoryTimelineEvidence]
    ) {
        self.id = id
        self.kind = kind
        self.entity = entity
        self.relatedEntity = relatedEntity
        self.text = text
        self.relatedText = relatedText
        self.commitmentChange = commitmentChange
        self.questionChange = questionChange
        self.blockerChange = blockerChange
        self.origin = origin
        self.occurredAt = occurredAt
        self.evidence = evidence
    }

    public var navigation: MeetingMemoryTimelineNavigation? {
        evidence.first.map {
            MeetingMemoryTimelineNavigation(
                meetingID: $0.meetingID,
                segmentID: $0.segmentID,
                timestamp: $0.startTime)
        }
    }
}

public struct MeetingMemoryTimelinePage: Equatable, Sendable {
    public let subject: MeetingMemoryTimelineSubject
    public let baseline: MeetingMemoryTimelineMeeting
    public let through: MeetingMemoryTimelineMeeting
    public let items: [MeetingMemoryTimelineItem]
    public let hasMore: Bool
    public let projectionGeneration: Int
    public let omittedStaleCount: Int
    public let omittedUnavailableCount: Int
    /// Fact classes that this authority snapshot cannot prove. Consumers must
    /// not present their absence as proof that no such change happened.
    public let unsupportedKinds: [MeetingMemoryTimelineItemKind]

    public init(
        subject: MeetingMemoryTimelineSubject,
        baseline: MeetingMemoryTimelineMeeting,
        through: MeetingMemoryTimelineMeeting,
        items: [MeetingMemoryTimelineItem],
        hasMore: Bool,
        projectionGeneration: Int,
        omittedStaleCount: Int,
        omittedUnavailableCount: Int,
        unsupportedKinds: [MeetingMemoryTimelineItemKind]
    ) {
        self.subject = subject
        self.baseline = baseline
        self.through = through
        self.items = items
        self.hasMore = hasMore
        self.projectionGeneration = projectionGeneration
        self.omittedStaleCount = omittedStaleCount
        self.omittedUnavailableCount = omittedUnavailableCount
        self.unsupportedKinds = unsupportedKinds
    }
}

public enum MeetingMemoryTimelineAbstentionReason: String, Equatable, Sendable {
    case invalidQuery = "invalid-query"
    case projectionNotReady = "projection-not-ready"
    case subjectUnavailable = "subject-unavailable"
    case anchorNotRelated = "anchor-not-related"
    case missingTemporalBaseline = "missing-temporal-baseline"
    case staleEvidenceOnly = "stale-evidence-only"
    case evidenceUnavailable = "evidence-unavailable"
}

public enum MeetingMemoryTimelineResult: Equatable, Sendable {
    case timeline(MeetingMemoryTimelinePage)
    case abstained(MeetingMemoryTimelineAbstentionReason)
}
