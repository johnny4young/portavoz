import Foundation

/// Explicit user truth that one confirmed decision currently blocks one
/// confirmed commitment. Proximity and generated prose never create it.
public enum DecisionCommitmentBlockerStatus: String, Codable, CaseIterable, Sendable {
    case active
    case cleared
}

/// Exact accepted transcript authority for one blocker lifecycle fact.
public struct DecisionCommitmentBlockerEvidence: Codable, Equatable, Sendable {
    public let meetingID: MeetingID
    public let sourceTranscriptRevision: Int
    public let segmentIDs: [UUID]

    public init(
        meetingID: MeetingID,
        sourceTranscriptRevision: Int,
        segmentIDs: [UUID]
    ) {
        self.meetingID = meetingID
        self.sourceTranscriptRevision = sourceTranscriptRevision
        self.segmentIDs = segmentIDs
    }
}

public struct DecisionCommitmentBlocker: Equatable, Identifiable, Sendable {
    public let id: DecisionCommitmentBlockerID
    public let decisionID: DecisionID
    public let commitmentID: CommitmentID
    public let status: DecisionCommitmentBlockerStatus
    public let confirmedAt: Date
    public let updatedAt: Date

    public init(
        id: DecisionCommitmentBlockerID = DecisionCommitmentBlockerID(),
        decisionID: DecisionID,
        commitmentID: CommitmentID,
        status: DecisionCommitmentBlockerStatus,
        confirmedAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.decisionID = decisionID
        self.commitmentID = commitmentID
        self.status = status
        self.confirmedAt = confirmedAt
        self.updatedAt = updatedAt
    }
}

public enum DecisionCommitmentBlockerEventKind: String, Codable, CaseIterable, Sendable {
    case clear
    case reopen
}

public struct DecisionCommitmentBlockerEvent: Equatable, Identifiable, Sendable {
    public let id: DecisionCommitmentBlockerEventID
    public let blockerID: DecisionCommitmentBlockerID
    public let kind: DecisionCommitmentBlockerEventKind
    public let evidence: DecisionCommitmentBlockerEvidence
    public let occurredAt: Date

    public init(
        id: DecisionCommitmentBlockerEventID = DecisionCommitmentBlockerEventID(),
        blockerID: DecisionCommitmentBlockerID,
        kind: DecisionCommitmentBlockerEventKind,
        evidence: DecisionCommitmentBlockerEvidence,
        occurredAt: Date
    ) {
        self.id = id
        self.blockerID = blockerID
        self.kind = kind
        self.evidence = evidence
        self.occurredAt = occurredAt
    }
}

public struct DecisionCommitmentBlockerConfirmation: Equatable, Sendable {
    public let blockerID: DecisionCommitmentBlockerID
    public let decisionID: DecisionID
    public let commitmentID: CommitmentID
    public let evidence: DecisionCommitmentBlockerEvidence
    public let confirmedAt: Date

    public init(
        blockerID: DecisionCommitmentBlockerID = DecisionCommitmentBlockerID(),
        decisionID: DecisionID,
        commitmentID: CommitmentID,
        evidence: DecisionCommitmentBlockerEvidence,
        confirmedAt: Date = Date()
    ) {
        self.blockerID = blockerID
        self.decisionID = decisionID
        self.commitmentID = commitmentID
        self.evidence = evidence
        self.confirmedAt = confirmedAt
    }
}

public enum DecisionCommitmentBlockerTransition: Equatable, Sendable {
    case clear
    case reopen

    public var eventKind: DecisionCommitmentBlockerEventKind {
        switch self {
        case .clear: .clear
        case .reopen: .reopen
        }
    }
}

public struct DecisionBlockerTransitionConfirmation: Equatable, Sendable {
    public let blockerID: DecisionCommitmentBlockerID
    public let eventID: DecisionCommitmentBlockerEventID
    public let transition: DecisionCommitmentBlockerTransition
    public let evidence: DecisionCommitmentBlockerEvidence
    public let confirmedAt: Date

    public init(
        blockerID: DecisionCommitmentBlockerID,
        eventID: DecisionCommitmentBlockerEventID = DecisionCommitmentBlockerEventID(),
        transition: DecisionCommitmentBlockerTransition,
        evidence: DecisionCommitmentBlockerEvidence,
        confirmedAt: Date = Date()
    ) {
        self.blockerID = blockerID
        self.eventID = eventID
        self.transition = transition
        self.evidence = evidence
        self.confirmedAt = confirmedAt
    }
}

public struct DecisionCommitmentBlockerContinuity: Equatable, Sendable {
    public let blocker: DecisionCommitmentBlocker
    public let openingEvidence: DecisionCommitmentBlockerEvidence
    public let events: [DecisionCommitmentBlockerEvent]

    public init(
        blocker: DecisionCommitmentBlocker,
        openingEvidence: DecisionCommitmentBlockerEvidence,
        events: [DecisionCommitmentBlockerEvent]
    ) throws {
        let projected = try DecisionCommitmentBlockerPolicy.projectedBlocker(
            id: blocker.id,
            decisionID: blocker.decisionID,
            commitmentID: blocker.commitmentID,
            openingEvidence: openingEvidence,
            confirmedAt: blocker.confirmedAt,
            events: events)
        guard projected == blocker else {
            throw DecisionCommitmentBlockerValidationError.projectionMismatch
        }
        self.blocker = blocker
        self.openingEvidence = openingEvidence
        self.events = events
    }
}

public enum DecisionCommitmentBlockerValidationError: Error, Equatable, Sendable {
    case invalidEvidence
    case invalidEvent
    case invalidOrder
    case invalidTransition
    case projectionMismatch
}

public enum DecisionCommitmentBlockerPolicy {
    public static func projectedBlocker(
        id: DecisionCommitmentBlockerID,
        decisionID: DecisionID,
        commitmentID: CommitmentID,
        openingEvidence: DecisionCommitmentBlockerEvidence,
        confirmedAt: Date,
        events: [DecisionCommitmentBlockerEvent]
    ) throws -> DecisionCommitmentBlocker {
        guard validEvidence(openingEvidence) else {
            throw DecisionCommitmentBlockerValidationError.invalidEvidence
        }
        guard confirmedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw DecisionCommitmentBlockerValidationError.invalidOrder
        }
        guard Set(events.map(\.id)).count == events.count else {
            throw DecisionCommitmentBlockerValidationError.invalidEvent
        }

        var status = DecisionCommitmentBlockerStatus.active
        var prior = confirmedAt
        for event in events {
            guard event.blockerID == id else {
                throw DecisionCommitmentBlockerValidationError.invalidEvent
            }
            guard validEvidence(event.evidence) else {
                throw DecisionCommitmentBlockerValidationError.invalidEvidence
            }
            guard event.occurredAt.timeIntervalSinceReferenceDate.isFinite,
                  event.occurredAt > prior
            else { throw DecisionCommitmentBlockerValidationError.invalidOrder }
            prior = event.occurredAt
            switch (status, event.kind) {
            case (.active, .clear): status = .cleared
            case (.cleared, .reopen): status = .active
            default: throw DecisionCommitmentBlockerValidationError.invalidTransition
            }
        }
        return DecisionCommitmentBlocker(
            id: id,
            decisionID: decisionID,
            commitmentID: commitmentID,
            status: status,
            confirmedAt: confirmedAt,
            updatedAt: events.last?.occurredAt ?? confirmedAt)
    }

    private static func validEvidence(
        _ evidence: DecisionCommitmentBlockerEvidence
    ) -> Bool {
        evidence.sourceTranscriptRevision >= 0
            && !evidence.segmentIDs.isEmpty
            && Set(evidence.segmentIDs).count == evidence.segmentIDs.count
    }
}
