import Foundation

/// Explicit user truth for one topic-scoped question. Generated summary or
/// Companion text never creates this identity.
public enum MeetingQuestionStatus: String, Codable, CaseIterable, Sendable {
    case open
    case resolved
    case dismissed
}

/// Exact accepted transcript authority for one question lifecycle fact.
public struct MeetingQuestionEvidence: Codable, Equatable, Sendable {
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

public struct MeetingQuestion: Equatable, Identifiable, Sendable {
    public let id: MeetingQuestionID
    public let topicID: TopicID
    public let text: String
    public let status: MeetingQuestionStatus
    public let openedAt: Date
    public let updatedAt: Date

    public init(
        id: MeetingQuestionID = MeetingQuestionID(),
        topicID: TopicID,
        text: String,
        status: MeetingQuestionStatus,
        openedAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.topicID = topicID
        self.text = text
        self.status = status
        self.openedAt = openedAt
        self.updatedAt = updatedAt
    }
}

public enum MeetingQuestionEventKind: String, Codable, CaseIterable, Sendable {
    case resolve
    case reopen
    case dismiss
}

public struct MeetingQuestionEvent: Equatable, Identifiable, Sendable {
    public let id: MeetingQuestionEventID
    public let questionID: MeetingQuestionID
    public let kind: MeetingQuestionEventKind
    public let evidence: MeetingQuestionEvidence
    public let occurredAt: Date

    public init(
        id: MeetingQuestionEventID = MeetingQuestionEventID(),
        questionID: MeetingQuestionID,
        kind: MeetingQuestionEventKind,
        evidence: MeetingQuestionEvidence,
        occurredAt: Date
    ) {
        self.id = id
        self.questionID = questionID
        self.kind = kind
        self.evidence = evidence
        self.occurredAt = occurredAt
    }
}

public struct MeetingQuestionConfirmation: Equatable, Sendable {
    public let questionID: MeetingQuestionID
    public let topicID: TopicID
    public let text: String
    public let evidence: MeetingQuestionEvidence
    public let confirmedAt: Date

    public init(
        questionID: MeetingQuestionID = MeetingQuestionID(),
        topicID: TopicID,
        text: String,
        evidence: MeetingQuestionEvidence,
        confirmedAt: Date = Date()
    ) {
        self.questionID = questionID
        self.topicID = topicID
        self.text = text
        self.evidence = evidence
        self.confirmedAt = confirmedAt
    }
}

public enum MeetingQuestionTransition: Equatable, Sendable {
    case resolve
    case reopen
    case dismiss

    public var eventKind: MeetingQuestionEventKind {
        switch self {
        case .resolve: .resolve
        case .reopen: .reopen
        case .dismiss: .dismiss
        }
    }
}

public struct MeetingQuestionTransitionConfirmation: Equatable, Sendable {
    public let questionID: MeetingQuestionID
    public let eventID: MeetingQuestionEventID
    public let transition: MeetingQuestionTransition
    public let evidence: MeetingQuestionEvidence
    public let confirmedAt: Date

    public init(
        questionID: MeetingQuestionID,
        eventID: MeetingQuestionEventID = MeetingQuestionEventID(),
        transition: MeetingQuestionTransition,
        evidence: MeetingQuestionEvidence,
        confirmedAt: Date = Date()
    ) {
        self.questionID = questionID
        self.eventID = eventID
        self.transition = transition
        self.evidence = evidence
        self.confirmedAt = confirmedAt
    }
}

public struct MeetingQuestionContinuity: Equatable, Sendable {
    public let question: MeetingQuestion
    public let openingEvidence: MeetingQuestionEvidence
    public let events: [MeetingQuestionEvent]

    public init(
        question: MeetingQuestion,
        openingEvidence: MeetingQuestionEvidence,
        events: [MeetingQuestionEvent]
    ) throws {
        let projected = try MeetingQuestionContinuityPolicy.projectedQuestion(
            id: question.id,
            topicID: question.topicID,
            text: question.text,
            openingEvidence: openingEvidence,
            openedAt: question.openedAt,
            events: events)
        guard projected == question else {
            throw MeetingQuestionContinuityValidationError.projectionMismatch
        }
        self.question = question
        self.openingEvidence = openingEvidence
        self.events = events
    }
}

public enum MeetingQuestionContinuityValidationError: Error, Equatable, Sendable {
    case invalidText
    case invalidEvidence
    case invalidEvent
    case invalidOrder
    case invalidTransition
    case projectionMismatch
}

public enum MeetingQuestionContinuityPolicy {
    public static func projectedQuestion(
        id: MeetingQuestionID,
        topicID: TopicID,
        text: String,
        openingEvidence: MeetingQuestionEvidence,
        openedAt: Date,
        events: [MeetingQuestionEvent]
    ) throws -> MeetingQuestion {
        let wording = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wording.isEmpty else {
            throw MeetingQuestionContinuityValidationError.invalidText
        }
        guard validEvidence(openingEvidence) else {
            throw MeetingQuestionContinuityValidationError.invalidEvidence
        }
        guard openedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw MeetingQuestionContinuityValidationError.invalidOrder
        }
        guard Set(events.map(\.id)).count == events.count else {
            throw MeetingQuestionContinuityValidationError.invalidEvent
        }

        var status = MeetingQuestionStatus.open
        var prior = openedAt
        for event in events {
            guard event.questionID == id else {
                throw MeetingQuestionContinuityValidationError.invalidEvent
            }
            guard validEvidence(event.evidence) else {
                throw MeetingQuestionContinuityValidationError.invalidEvidence
            }
            guard event.occurredAt.timeIntervalSinceReferenceDate.isFinite,
                  event.occurredAt > prior
            else { throw MeetingQuestionContinuityValidationError.invalidOrder }
            prior = event.occurredAt
            switch (status, event.kind) {
            case (.open, .resolve):
                status = .resolved
            case (.resolved, .reopen):
                status = .open
            case (.open, .dismiss), (.resolved, .dismiss):
                status = .dismissed
            default:
                throw MeetingQuestionContinuityValidationError.invalidTransition
            }
        }
        return MeetingQuestion(
            id: id,
            topicID: topicID,
            text: wording,
            status: status,
            openedAt: openedAt,
            updatedAt: events.last?.occurredAt ?? openedAt)
    }

    private static func validEvidence(_ evidence: MeetingQuestionEvidence) -> Bool {
        evidence.sourceTranscriptRevision >= 0
            && !evidence.segmentIDs.isEmpty
            && Set(evidence.segmentIDs).count == evidence.segmentIDs.count
    }
}
