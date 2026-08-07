import Foundation

/// Exact constraints shared by every source-backed graph fact query. Date
/// bounds are half-open so adjacent caller ranges cannot overlap.
public struct MeetingMemoryGraphFactFilter: Equatable, Sendable {
    public let occurredAtOrAfter: Date?
    public let occurredBefore: Date?
    public let status: MeetingMemoryGraphFactStatus?

    public init(
        occurredAtOrAfter: Date? = nil,
        occurredBefore: Date? = nil,
        status: MeetingMemoryGraphFactStatus? = nil
    ) {
        self.occurredAtOrAfter = occurredAtOrAfter
        self.occurredBefore = occurredBefore
        self.status = status
    }

    public var isValid: Bool {
        if let occurredAtOrAfter,
           !occurredAtOrAfter.timeIntervalSinceReferenceDate.isFinite {
            return false
        }
        if let occurredBefore,
           !occurredBefore.timeIntervalSinceReferenceDate.isFinite {
            return false
        }
        if let occurredAtOrAfter, let occurredBefore,
           occurredAtOrAfter >= occurredBefore {
            return false
        }
        return true
    }

    public var isUnrestricted: Bool {
        occurredAtOrAfter == nil && occurredBefore == nil && status == nil
    }

    public func includes(
        occurredAt: Date,
        status candidateStatus: MeetingMemoryGraphFactStatus
    ) -> Bool {
        guard isValid,
              occurredAt.timeIntervalSinceReferenceDate.isFinite
        else { return false }
        if let lower = occurredAtOrAfter, occurredAt < lower { return false }
        if let upper = occurredBefore, occurredAt >= upper { return false }
        if let status, candidateStatus != status { return false }
        return true
    }

    public func intersection(
        with other: MeetingMemoryGraphFactFilter
    ) -> MeetingMemoryGraphFactFilter? {
        guard isValid, other.isValid else { return nil }
        if let status, let otherStatus = other.status, status != otherStatus {
            return nil
        }
        let intersection = MeetingMemoryGraphFactFilter(
            occurredAtOrAfter: [occurredAtOrAfter, other.occurredAtOrAfter]
                .compactMap { $0 }
                .max(),
            occurredBefore: [occurredBefore, other.occurredBefore]
                .compactMap { $0 }
                .min(),
            status: status ?? other.status)
        return intersection.isValid ? intersection : nil
    }
}

/// The first source-backed product query over the disposable Meeting Memory
/// Graph. A caller provides an exact commitment identity; natural-language
/// identity discovery remains a separate retrieval concern.
public struct CommitmentBlockerQuery: Equatable, Sendable {
    public static let defaultItemLimit = 20
    public static let maximumItemLimit = 100

    public let commitmentID: CommitmentID
    public let itemLimit: Int
    public let filter: MeetingMemoryGraphFactFilter

    public init(
        commitmentID: CommitmentID,
        itemLimit: Int = defaultItemLimit,
        filter: MeetingMemoryGraphFactFilter = MeetingMemoryGraphFactFilter()
    ) {
        self.commitmentID = commitmentID
        self.itemLimit = itemLimit
        self.filter = filter
    }

    public var isValid: Bool {
        (1...Self.maximumItemLimit).contains(itemLimit) && filter.isValid
    }
}

/// Finds the earliest explicitly confirmed discussion for one exact topic
/// identity. Label and natural-language resolution happen before this query.
public struct TopicFirstDiscussionQuery: Equatable, Sendable {
    public let topicID: TopicID
    public let filter: MeetingMemoryGraphFactFilter

    public init(
        topicID: TopicID,
        filter: MeetingMemoryGraphFactFilter = MeetingMemoryGraphFactFilter()
    ) {
        self.topicID = topicID
        self.filter = filter
    }

    public var isValid: Bool {
        filter.isValid
    }
}

/// Finds explicitly confirmed decision replacements about one exact topic
/// family: which confirmed decision superseded or reversed which. Label and
/// alias resolution happen before this query; a generated note that "guessed"
/// a replacement is not a conflict.
public struct DecisionConflictsQuery: Equatable, Sendable {
    public static let defaultItemLimit = 20
    public static let maximumItemLimit = 100

    public let topicID: TopicID
    public let itemLimit: Int
    public let filter: MeetingMemoryGraphFactFilter

    public init(
        topicID: TopicID,
        itemLimit: Int = Self.defaultItemLimit,
        filter: MeetingMemoryGraphFactFilter = MeetingMemoryGraphFactFilter()
    ) {
        self.topicID = topicID
        self.itemLimit = itemLimit
        self.filter = filter
    }

    public var isValid: Bool {
        itemLimit >= 1
            && itemLimit <= Self.maximumItemLimit
            && filter.isValid
    }
}

/// Finds what changed about one exact topic family since one exact anchor
/// meeting: confirmed decision replacements whose relationship event occurred
/// after the anchor ended. Resolving "the last meeting" to an exact meeting is
/// the caller's job — an unresolvable anchor abstains rather than guessing.
public struct ChangeSinceQuery: Equatable, Sendable {
    public static let defaultItemLimit = 20
    public static let maximumItemLimit = 100

    public let topicID: TopicID
    public let sinceMeetingID: MeetingID
    public let itemLimit: Int
    public let filter: MeetingMemoryGraphFactFilter

    public init(
        topicID: TopicID,
        sinceMeetingID: MeetingID,
        itemLimit: Int = Self.defaultItemLimit,
        filter: MeetingMemoryGraphFactFilter = MeetingMemoryGraphFactFilter()
    ) {
        self.topicID = topicID
        self.sinceMeetingID = sinceMeetingID
        self.itemLimit = itemLimit
        self.filter = filter
    }

    public var isValid: Bool {
        itemLimit >= 1
            && itemLimit <= Self.maximumItemLimit
            && filter.isValid
    }
}

/// Finds current source-backed commitments for one exact canonical person.
/// Name and alias resolution happen before this query.
public struct PersonCommitmentsQuery: Equatable, Sendable {
    public static let defaultItemLimit = 20
    public static let maximumItemLimit = 100

    public let personID: PersonID
    public let itemLimit: Int
    public let filter: MeetingMemoryGraphFactFilter

    public init(
        personID: PersonID,
        itemLimit: Int = defaultItemLimit,
        filter: MeetingMemoryGraphFactFilter = MeetingMemoryGraphFactFilter()
    ) {
        self.personID = personID
        self.itemLimit = itemLimit
        self.filter = filter
    }

    public var isValid: Bool {
        (1...Self.maximumItemLimit).contains(itemLimit) && filter.isValid
    }
}

public enum MeetingMemoryGraphFactID: Hashable, Sendable {
    case blocker(DecisionCommitmentBlockerID)
    case topicEvidence(TopicMeetingEvidenceID)
    case commitment(CommitmentID)
    /// The supersede/reverse event on the older decision: one relationship,
    /// one identity, however many topics its decisions are linked to.
    case decisionRelationship(DecisionEventID)
}

public enum MeetingMemoryGraphFactKind: String, Equatable, Sendable {
    case decisionBlocksCommitment = "decision-blocks-commitment"
    case topicDiscussedInMeeting = "topic-discussed-in-meeting"
    case personCommittedTo = "person-committed-to"
    /// Subject: the successor decision. Object: the decision it replaced.
    /// Shared by decisionConflicts and changeSince — the relationship is the
    /// same authority; the jobs differ only in temporal anchoring.
    case decisionSupersededDecision = "decision-superseded-decision"
}

public enum MeetingMemoryGraphFactEntity: Hashable, Sendable {
    case decision(DecisionID)
    case commitment(CommitmentID)
    case person(PersonID)
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
    case personUnavailable = "person-unavailable"
    case ambiguousPerson = "ambiguous-person"
    case topicUnavailable = "topic-unavailable"
    case ambiguousTopic = "ambiguous-topic"
    case projectionInconsistent = "projection-inconsistent"
    case unsupportedCausalLink = "unsupported-causal-link"
    case noActiveCommitments = "no-active-commitments"
    case noMatchingFacts = "no-matching-facts"
    case candidateBudgetExceeded = "candidate-budget-exceeded"
    case staleEvidenceOnly = "stale-evidence-only"
    case evidenceUnavailable = "evidence-unavailable"
    /// Decisions about the topic exist, but no confirmed supersession or
    /// reversal relates any of them; a generated guess is not a conflict.
    case unsupportedConflict = "unsupported-conflict"
    /// The anchor meeting could not be resolved, so "since when" has no exact
    /// answer and the query abstains rather than guessing a baseline.
    case missingTemporalBaseline = "missing-temporal-baseline"
}

public enum MeetingMemoryGraphQueryResult: Equatable, Sendable {
    case facts(MeetingMemoryGraphFactPage)
    case abstained(MeetingMemoryGraphQueryAbstention)
}
