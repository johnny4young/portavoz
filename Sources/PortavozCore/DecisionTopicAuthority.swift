import Foundation

/// Explicitly confirmed "this decision is *about* this topic" authority.
///
/// The graph may only check or select topology that authoritative storage
/// already asserts (D270/D271). Joining `topic → meeting → decision` would
/// return every decision taken in any meeting where the topic was mentioned —
/// proximity dressed up as aboutness, which is exactly the failure the corpus
/// distractors exist to catch. A decision becomes about a topic only through an
/// explicit user gesture over exact evidence, and that evidence must be one the
/// decision itself already owns.
public enum DecisionTopicLinkStatus: String, Codable, Sendable {
    case confirmed
    case retracted
}

public struct DecisionTopicLink: Codable, Equatable, Sendable, Identifiable {
    public let id: DecisionTopicLinkID
    public let decisionID: DecisionID
    public let topicID: TopicID
    public let status: DecisionTopicLinkStatus
    public let createdAt: Date
    public let updatedAt: Date
    public let deletedAt: Date?

    public init(
        id: DecisionTopicLinkID,
        decisionID: DecisionID,
        topicID: TopicID,
        status: DecisionTopicLinkStatus,
        createdAt: Date,
        updatedAt: Date,
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.decisionID = decisionID
        self.topicID = topicID
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }
}

/// The exact material the user was looking at when they confirmed aboutness.
/// Source identifiers deliberately keep no foreign keys in storage: purging
/// the summary or meeting must not erase why a user once linked this decision.
public struct DecisionTopicLinkSource: Codable, Equatable, Sendable, Identifiable {
    public let id: DecisionTopicLinkSourceID
    public let linkID: DecisionTopicLinkID
    public let observationID: SummaryDecisionID
    public let summaryID: SummaryID
    public let meetingID: MeetingID
    public let observedStatement: String
    public let observedTopicLabel: String
    public let sourceTranscriptRevision: Int
    public let observedAt: Date
    public let linkedAt: Date

    public init(
        id: DecisionTopicLinkSourceID = DecisionTopicLinkSourceID(),
        linkID: DecisionTopicLinkID,
        observationID: SummaryDecisionID,
        summaryID: SummaryID,
        meetingID: MeetingID,
        observedStatement: String,
        observedTopicLabel: String,
        sourceTranscriptRevision: Int,
        observedAt: Date,
        linkedAt: Date
    ) {
        self.id = id
        self.linkID = linkID
        self.observationID = observationID
        self.summaryID = summaryID
        self.meetingID = meetingID
        self.observedStatement = observedStatement
        self.observedTopicLabel = observedTopicLabel
        self.sourceTranscriptRevision = sourceTranscriptRevision
        self.observedAt = observedAt
        self.linkedAt = linkedAt
    }
}

public enum DecisionTopicLinkEventKind: String, Codable, Sendable {
    case confirm
    case retract
}

public struct DecisionTopicLinkEvent: Codable, Equatable, Sendable, Identifiable {
    public let id: DecisionTopicLinkEventID
    public let linkID: DecisionTopicLinkID
    public let kind: DecisionTopicLinkEventKind
    public let sourceID: DecisionTopicLinkSourceID?
    public let occurredAt: Date

    public init(
        id: DecisionTopicLinkEventID = DecisionTopicLinkEventID(),
        linkID: DecisionTopicLinkID,
        kind: DecisionTopicLinkEventKind,
        sourceID: DecisionTopicLinkSourceID?,
        occurredAt: Date
    ) {
        self.id = id
        self.linkID = linkID
        self.kind = kind
        self.sourceID = sourceID
        self.occurredAt = occurredAt
    }
}

/// One explicit user confirmation. `observationID` names the generated decision
/// observation the user was reading — it must already be a source of the very
/// decision being linked, which is what keeps the link's evidence the
/// decision's own rather than anything that merely co-occurred.
public struct DecisionTopicLinkConfirmation: Equatable, Sendable {
    public let linkID: DecisionTopicLinkID
    public let sourceID: DecisionTopicLinkSourceID
    public let eventID: DecisionTopicLinkEventID
    public let decisionID: DecisionID
    public let topicID: TopicID
    public let observationID: SummaryDecisionID
    public let confirmedAt: Date

    public init(
        linkID: DecisionTopicLinkID = DecisionTopicLinkID(),
        sourceID: DecisionTopicLinkSourceID = DecisionTopicLinkSourceID(),
        eventID: DecisionTopicLinkEventID = DecisionTopicLinkEventID(),
        decisionID: DecisionID,
        topicID: TopicID,
        observationID: SummaryDecisionID,
        confirmedAt: Date = Date()
    ) {
        self.linkID = linkID
        self.sourceID = sourceID
        self.eventID = eventID
        self.decisionID = decisionID
        self.topicID = topicID
        self.observationID = observationID
        self.confirmedAt = confirmedAt
    }
}

public struct DecisionTopicLinkRetraction: Equatable, Sendable {
    public let linkID: DecisionTopicLinkID
    public let eventID: DecisionTopicLinkEventID
    public let retractedAt: Date

    public init(
        linkID: DecisionTopicLinkID,
        eventID: DecisionTopicLinkEventID = DecisionTopicLinkEventID(),
        retractedAt: Date = Date()
    ) {
        self.linkID = linkID
        self.eventID = eventID
        self.retractedAt = retractedAt
    }
}

public enum DecisionTopicLinkValidationError: Error, Equatable {
    case invalidEvent
    case invalidOrder
}

/// Pure projection of a link's lifecycle from its append-only events, so the
/// stored status can always be re-derived and checked.
public enum DecisionTopicLinkPolicy {
    public static func projectedStatus(
        linkID: DecisionTopicLinkID,
        events: [DecisionTopicLinkEvent]
    ) throws -> DecisionTopicLinkStatus {
        guard let first = events.first,
              first.kind == .confirm,
              first.sourceID != nil,
              events.count <= 2,
              Set(events.map(\.id)).count == events.count,
              events.allSatisfy({ $0.linkID == linkID })
        else { throw DecisionTopicLinkValidationError.invalidEvent }
        guard events.count == 2 else { return .confirmed }
        let retraction = events[1]
        guard retraction.kind == .retract,
              retraction.sourceID == nil,
              retraction.occurredAt > first.occurredAt
        else { throw DecisionTopicLinkValidationError.invalidOrder }
        return .retracted
    }
}

/// One link with its full evidence and history, as loaded for review.
public struct DecisionTopicLinkContinuity: Equatable, Sendable {
    public let link: DecisionTopicLink
    public let source: DecisionTopicLinkSource
    public let events: [DecisionTopicLinkEvent]

    public init(
        link: DecisionTopicLink,
        source: DecisionTopicLinkSource,
        events: [DecisionTopicLinkEvent]
    ) throws {
        guard source.linkID == link.id,
              try DecisionTopicLinkPolicy.projectedStatus(
                  linkID: link.id,
                  events: events) == link.status
        else { throw DecisionTopicLinkValidationError.invalidEvent }
        self.link = link
        self.source = source
        self.events = events
    }
}

/// What the decision-confirmation gesture needs to render honestly: which
/// generated observations already became durable decisions, and which topics
/// those decisions are about.
public struct DecisionObservationConfirmationState: Equatable, Sendable {
    /// One active aboutness link as presentation needs it: enough identity to
    /// retract, and the label the badge shows.
    public struct TopicLink: Equatable, Sendable, Identifiable {
        public let id: DecisionTopicLinkID
        public let label: String

        public init(id: DecisionTopicLinkID, label: String) {
            self.id = id
            self.label = label
        }
    }

    public let observationID: SummaryDecisionID
    public let decisionID: DecisionID
    public let topicLinks: [TopicLink]

    public var topicLabels: [String] { topicLinks.map(\.label) }

    public init(
        observationID: SummaryDecisionID,
        decisionID: DecisionID,
        topicLinks: [TopicLink]
    ) {
        self.observationID = observationID
        self.decisionID = decisionID
        self.topicLinks = topicLinks
    }
}

/// A live, unmerged topic offered by the linking gesture. Suggestion only —
/// typing a new label creates a new topic; nothing here grants confirmation.
public struct LinkableTopic: Equatable, Sendable, Identifiable {
    public let id: TopicID
    public let preferredLabel: String

    public init(id: TopicID, preferredLabel: String) {
        self.id = id
        self.preferredLabel = preferredLabel
    }
}
