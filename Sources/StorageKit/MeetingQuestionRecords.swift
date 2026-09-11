import Foundation
import GRDB
import PortavozCore

struct MeetingQuestionRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "meetingQuestion"

    var id: String
    var topicID: String
    var text: String
    var status: String
    var sourceMeetingID: String
    var sourceTranscriptRevision: Int
    var primarySegmentID: String
    var openedAt: Date
    var updatedAt: Date
    var latestEventID: String?
    var deletedAt: Date?

    init(
        question: MeetingQuestion,
        openingEvidence: MeetingQuestionEvidence
    ) throws {
        guard let primarySegmentID = openingEvidence.segmentIDs.first else {
            throw StorageError.invalidMeetingQuestion(
                "question opening evidence must include a segment")
        }
        id = question.id.rawValue.uuidString
        topicID = question.topicID.rawValue.uuidString
        text = question.text
        status = question.status.rawValue
        sourceMeetingID = openingEvidence.meetingID.rawValue.uuidString
        sourceTranscriptRevision = openingEvidence.sourceTranscriptRevision
        self.primarySegmentID = primarySegmentID.uuidString
        openedAt = question.openedAt
        updatedAt = question.updatedAt
        latestEventID = nil
        deletedAt = nil
    }

    func question() throws -> MeetingQuestion {
        guard let status = MeetingQuestionStatus(rawValue: status) else {
            throw StorageError.invalidPersistedValue(
                table: Self.databaseTableName,
                column: "status",
                value: self.status)
        }
        return MeetingQuestion(
            id: MeetingQuestionID(rawValue: try PersistedIdentity.required(
                id, table: Self.databaseTableName, column: "id")),
            topicID: TopicID(rawValue: try PersistedIdentity.required(
                topicID, table: Self.databaseTableName, column: "topicID")),
            text: text,
            status: status,
            openedAt: openedAt,
            updatedAt: updatedAt)
    }

    func openingEvidence(additionalSegmentIDs: [UUID]) throws -> MeetingQuestionEvidence {
        MeetingQuestionEvidence(
            meetingID: MeetingID(rawValue: try PersistedIdentity.required(
                sourceMeetingID,
                table: Self.databaseTableName,
                column: "sourceMeetingID")),
            sourceTranscriptRevision: sourceTranscriptRevision,
            segmentIDs: [try PersistedIdentity.required(
                primarySegmentID,
                table: Self.databaseTableName,
                column: "primarySegmentID")] + additionalSegmentIDs)
    }
}

struct MeetingQuestionEventRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "meetingQuestionEvent"

    var id: String
    var questionID: String
    var kind: String
    var sourceMeetingID: String
    var sourceTranscriptRevision: Int
    var primarySegmentID: String
    var occurredAt: Date

    init(_ event: MeetingQuestionEvent) throws {
        guard let primarySegmentID = event.evidence.segmentIDs.first else {
            throw StorageError.invalidMeetingQuestion(
                "question event evidence must include a segment")
        }
        id = event.id.rawValue.uuidString
        questionID = event.questionID.rawValue.uuidString
        kind = event.kind.rawValue
        sourceMeetingID = event.evidence.meetingID.rawValue.uuidString
        sourceTranscriptRevision = event.evidence.sourceTranscriptRevision
        self.primarySegmentID = primarySegmentID.uuidString
        occurredAt = event.occurredAt
    }

    func event(additionalSegmentIDs: [UUID]) throws -> MeetingQuestionEvent {
        guard let kind = MeetingQuestionEventKind(rawValue: kind) else {
            throw StorageError.invalidPersistedValue(
                table: Self.databaseTableName,
                column: "kind",
                value: self.kind)
        }
        return MeetingQuestionEvent(
            id: MeetingQuestionEventID(rawValue: try PersistedIdentity.required(
                id, table: Self.databaseTableName, column: "id")),
            questionID: MeetingQuestionID(rawValue: try PersistedIdentity.required(
                questionID, table: Self.databaseTableName, column: "questionID")),
            kind: kind,
            evidence: MeetingQuestionEvidence(
                meetingID: MeetingID(rawValue: try PersistedIdentity.required(
                    sourceMeetingID,
                    table: Self.databaseTableName,
                    column: "sourceMeetingID")),
                sourceTranscriptRevision: sourceTranscriptRevision,
                segmentIDs: [try PersistedIdentity.required(
                    primarySegmentID,
                    table: Self.databaseTableName,
                    column: "primarySegmentID")] + additionalSegmentIDs),
            occurredAt: occurredAt)
    }
}

struct MeetingQuestionEvidenceSegmentRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "meetingQuestionEvidenceSegment"

    var questionID: String
    var segmentID: String
    var ordinal: Int

    init(questionID: MeetingQuestionID, segmentID: UUID, ordinal: Int) {
        self.questionID = questionID.rawValue.uuidString
        self.segmentID = segmentID.uuidString
        self.ordinal = ordinal
    }

    var persistedSegmentID: UUID {
        get throws {
            try PersistedIdentity.required(
                segmentID,
                table: Self.databaseTableName,
                column: "segmentID")
        }
    }
}

struct QuestionEventEvidenceSegmentRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "meetingQuestionEventEvidenceSegment"

    var eventID: String
    var segmentID: String
    var ordinal: Int

    init(eventID: MeetingQuestionEventID, segmentID: UUID, ordinal: Int) {
        self.eventID = eventID.rawValue.uuidString
        self.segmentID = segmentID.uuidString
        self.ordinal = ordinal
    }

    var persistedSegmentID: UUID {
        get throws {
            try PersistedIdentity.required(
                segmentID,
                table: Self.databaseTableName,
                column: "segmentID")
        }
    }
}
