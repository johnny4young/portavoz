import Foundation

/// A generated summary bullet is merely observed. Only explicit confirmation
/// creates durable user truth; later explicit relationships can retire it.
public enum DecisionContinuityStatus: String, Codable, CaseIterable, Sendable {
    case observed
    case confirmed
    case superseded
    case reversed
}

public enum DecisionEvidenceAvailability: String, Codable, CaseIterable, Sendable {
    case current
    case stale
    case unavailable
}

public struct DecisionEvidenceSegment: Codable, Equatable, Sendable {
    public let segmentID: UUID
    public let ordinal: Int

    public init(segmentID: UUID, ordinal: Int) {
        self.segmentID = segmentID
        self.ordinal = ordinal
    }
}

/// Read-only candidate derived from one immutable generated summary bullet.
/// Loading it performs no continuity mutation and always remains observed.
public struct DecisionObservation: Equatable, Identifiable, Sendable {
    public let id: SummaryDecisionID
    public let summaryID: SummaryID
    public let meetingID: MeetingID
    public let statement: String
    public let sourceTranscriptRevision: Int
    public let observedAt: Date
    public let evidence: [DecisionEvidenceSegment]
    public let availability: DecisionEvidenceAvailability

    public var status: DecisionContinuityStatus { .observed }

    public init(
        id: SummaryDecisionID,
        summaryID: SummaryID,
        meetingID: MeetingID,
        statement: String,
        sourceTranscriptRevision: Int,
        observedAt: Date,
        evidence: [DecisionEvidenceSegment],
        availability: DecisionEvidenceAvailability
    ) {
        self.id = id
        self.summaryID = summaryID
        self.meetingID = meetingID
        self.statement = statement
        self.sourceTranscriptRevision = sourceTranscriptRevision
        self.observedAt = observedAt
        self.evidence = evidence
        self.availability = availability
    }
}

/// Current projection of one explicitly confirmed decision identity.
public struct MeetingDecision: Equatable, Identifiable, Sendable {
    public let id: DecisionID
    public let statement: String
    public let status: DecisionContinuityStatus
    public let createdAt: Date
    public let updatedAt: Date
    public let deletedAt: Date?

    public init(
        id: DecisionID = DecisionID(),
        statement: String,
        status: DecisionContinuityStatus,
        createdAt: Date,
        updatedAt: Date,
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.statement = statement
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }
}

/// Immutable accepted evidence. Source identities and exact segment order
/// survive source purge; only `availability` is derived at read time.
public struct DecisionSource: Equatable, Identifiable, Sendable {
    public let id: DecisionSourceID
    public let decisionID: DecisionID
    public let observationID: SummaryDecisionID
    public let summaryID: SummaryID
    public let meetingID: MeetingID
    public let observedStatement: String
    public let sourceTranscriptRevision: Int
    public let observedAt: Date
    public let linkedAt: Date
    public let evidence: [DecisionEvidenceSegment]
    public let availability: DecisionEvidenceAvailability

    public init(
        id: DecisionSourceID = DecisionSourceID(),
        decisionID: DecisionID,
        observationID: SummaryDecisionID,
        summaryID: SummaryID,
        meetingID: MeetingID,
        observedStatement: String,
        sourceTranscriptRevision: Int,
        observedAt: Date,
        linkedAt: Date,
        evidence: [DecisionEvidenceSegment],
        availability: DecisionEvidenceAvailability
    ) {
        self.id = id
        self.decisionID = decisionID
        self.observationID = observationID
        self.summaryID = summaryID
        self.meetingID = meetingID
        self.observedStatement = observedStatement
        self.sourceTranscriptRevision = sourceTranscriptRevision
        self.observedAt = observedAt
        self.linkedAt = linkedAt
        self.evidence = evidence
        self.availability = availability
    }
}

public enum DecisionEventKind: String, Codable, CaseIterable, Sendable {
    case confirm
    case supersede
    case reverse
}

public struct DecisionEvent: Equatable, Identifiable, Sendable {
    public let id: DecisionEventID
    public let decisionID: DecisionID
    public let kind: DecisionEventKind
    public let sourceID: DecisionSourceID?
    public let relatedDecisionID: DecisionID?
    public let occurredAt: Date

    public init(
        id: DecisionEventID = DecisionEventID(),
        decisionID: DecisionID,
        kind: DecisionEventKind,
        sourceID: DecisionSourceID? = nil,
        relatedDecisionID: DecisionID? = nil,
        occurredAt: Date = Date()
    ) {
        self.id = id
        self.decisionID = decisionID
        self.kind = kind
        self.sourceID = sourceID
        self.relatedDecisionID = relatedDecisionID
        self.occurredAt = occurredAt
    }
}

public enum DecisionRelationshipKind: String, Codable, CaseIterable, Sendable {
    case supersede
    case reverse

    public var eventKind: DecisionEventKind {
        switch self {
        case .supersede: .supersede
        case .reverse: .reverse
        }
    }
}

public struct DecisionConfirmation: Equatable, Sendable {
    public let decisionID: DecisionID
    public let sourceID: DecisionSourceID
    public let eventID: DecisionEventID
    public let observationID: SummaryDecisionID
    public let confirmedAt: Date

    public init(
        decisionID: DecisionID = DecisionID(),
        sourceID: DecisionSourceID = DecisionSourceID(),
        eventID: DecisionEventID = DecisionEventID(),
        observationID: SummaryDecisionID,
        confirmedAt: Date = Date()
    ) {
        self.decisionID = decisionID
        self.sourceID = sourceID
        self.eventID = eventID
        self.observationID = observationID
        self.confirmedAt = confirmedAt
    }
}

public struct DecisionSourceConfirmation: Equatable, Sendable {
    public let decisionID: DecisionID
    public let sourceID: DecisionSourceID
    public let observationID: SummaryDecisionID
    public let confirmedAt: Date

    public init(
        decisionID: DecisionID,
        sourceID: DecisionSourceID = DecisionSourceID(),
        observationID: SummaryDecisionID,
        confirmedAt: Date = Date()
    ) {
        self.decisionID = decisionID
        self.sourceID = sourceID
        self.observationID = observationID
        self.confirmedAt = confirmedAt
    }
}

public struct DecisionRelationshipConfirmation: Equatable, Sendable {
    public let targetDecisionID: DecisionID
    public let successorDecisionID: DecisionID
    public let kind: DecisionRelationshipKind
    public let eventID: DecisionEventID
    public let confirmedAt: Date

    public init(
        targetDecisionID: DecisionID,
        successorDecisionID: DecisionID,
        kind: DecisionRelationshipKind,
        eventID: DecisionEventID = DecisionEventID(),
        confirmedAt: Date = Date()
    ) {
        self.targetDecisionID = targetDecisionID
        self.successorDecisionID = successorDecisionID
        self.kind = kind
        self.eventID = eventID
        self.confirmedAt = confirmedAt
    }
}

public enum DecisionContinuityValidationError: Error, Equatable, CustomStringConvertible {
    case invalidStatement
    case invalidSource
    case invalidEvent
    case invalidOrder
    case projectionMismatch

    public var description: String {
        switch self {
        case .invalidStatement: "decision statement is empty"
        case .invalidSource: "decision source is invalid"
        case .invalidEvent: "decision event is invalid"
        case .invalidOrder: "decision history order is invalid"
        case .projectionMismatch: "decision projection does not match history"
        }
    }
}

public enum DecisionContinuityPolicy {
    public static func projectedDecision(
        id: DecisionID,
        statement: String,
        events: [DecisionEvent]
    ) throws -> MeetingDecision {
        let text = statement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw DecisionContinuityValidationError.invalidStatement
        }
        guard let first = events.first,
              first.kind == .confirm,
              first.decisionID == id,
              first.sourceID != nil,
              first.relatedDecisionID == nil,
              Set(events.map(\.id)).count == events.count
        else { throw DecisionContinuityValidationError.invalidEvent }
        var prior = Date.distantPast
        var terminal: DecisionEvent?
        for (index, event) in events.enumerated() {
            guard event.decisionID == id,
                  event.occurredAt.timeIntervalSinceReferenceDate.isFinite,
                  event.occurredAt >= prior
            else { throw DecisionContinuityValidationError.invalidOrder }
            prior = event.occurredAt
            switch event.kind {
            case .confirm:
                guard index == 0,
                      event.sourceID != nil,
                      event.relatedDecisionID == nil
                else { throw DecisionContinuityValidationError.invalidEvent }
            case .supersede, .reverse:
                guard terminal == nil,
                      event.sourceID == nil,
                      let related = event.relatedDecisionID,
                      related != id,
                      index == events.count - 1
                else { throw DecisionContinuityValidationError.invalidEvent }
                terminal = event
            }
        }
        let status: DecisionContinuityStatus = switch terminal?.kind {
        case .supersede: .superseded
        case .reverse: .reversed
        case .confirm, nil: .confirmed
        }
        return MeetingDecision(
            id: id,
            statement: text,
            status: status,
            createdAt: first.occurredAt,
            updatedAt: events.last?.occurredAt ?? first.occurredAt)
    }
}

public struct DecisionContinuity: Equatable, Sendable {
    public let decision: MeetingDecision
    public let sources: [DecisionSource]
    public let events: [DecisionEvent]

    public init(
        decision: MeetingDecision,
        sources: [DecisionSource],
        events: [DecisionEvent]
    ) throws {
        guard decision.status != .observed,
              decision.deletedAt == nil,
              !sources.isEmpty,
              Set(sources.map(\.id)).count == sources.count,
              Set(sources.map(\.observationID)).count == sources.count,
              sources.allSatisfy({ Self.sourceIsValid($0, decisionID: decision.id) })
        else { throw DecisionContinuityValidationError.invalidSource }
        let projected = try DecisionContinuityPolicy.projectedDecision(
            id: decision.id,
            statement: decision.statement,
            events: events)
        guard projected == decision,
              let confirmedSourceID = events.first?.sourceID,
              let confirmedSource = sources.first(where: { $0.id == confirmedSourceID }),
              confirmedSource.observedStatement == decision.statement,
              confirmedSource.linkedAt == events.first?.occurredAt,
              sources.first?.id == confirmedSourceID,
              zip(sources, sources.dropFirst()).allSatisfy({ prior, next in
                  prior.linkedAt < next.linkedAt
              })
        else { throw DecisionContinuityValidationError.projectionMismatch }
        self.decision = decision
        self.sources = sources
        self.events = events
    }

    private static func sourceIsValid(
        _ source: DecisionSource,
        decisionID: DecisionID
    ) -> Bool {
        source.decisionID == decisionID
            && !source.observedStatement.trimmingCharacters(
                in: .whitespacesAndNewlines).isEmpty
            && source.sourceTranscriptRevision >= 0
            && source.observedAt.timeIntervalSinceReferenceDate.isFinite
            && source.linkedAt.timeIntervalSinceReferenceDate.isFinite
            && source.linkedAt >= source.observedAt
            && !source.evidence.isEmpty
            && source.evidence.map(\.ordinal) == Array(0..<source.evidence.count)
            && Set(source.evidence.map(\.segmentID)).count == source.evidence.count
    }
}
