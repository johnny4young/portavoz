import Foundation
import GRDB
import PortavozCore

struct DecisionContinuityRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "decisionContinuity"

    var id: String
    var statement: String
    var status: String
    var createdAt: Date
    var updatedAt: Date
    var deletedAt: Date?

    init(_ decision: MeetingDecision) {
        id = decision.id.rawValue.uuidString
        statement = decision.statement
        status = decision.status.rawValue
        createdAt = decision.createdAt
        updatedAt = decision.updatedAt
        deletedAt = decision.deletedAt
    }

    var decision: MeetingDecision {
        get throws {
            guard let status = DecisionContinuityStatus(rawValue: status),
                  status != .observed
            else {
                throw StorageError.invalidPersistedValue(
                    table: Self.databaseTableName,
                    column: "status",
                    value: self.status)
            }
            return MeetingDecision(
                id: DecisionID(rawValue: try PersistedIdentity.required(
                    id, table: Self.databaseTableName, column: "id")),
                statement: statement,
                status: status,
                createdAt: createdAt,
                updatedAt: updatedAt,
                deletedAt: deletedAt)
        }
    }
}

struct DecisionContinuitySourceRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "decisionContinuitySource"

    var id: String
    var decisionID: String
    var summaryDecisionID: String
    var summaryID: String
    var meetingID: String
    var observedStatement: String
    var sourceTranscriptRevision: Int
    var observedAt: Date
    var linkedAt: Date

    init(_ source: DecisionSource) {
        id = source.id.rawValue.uuidString
        decisionID = source.decisionID.rawValue.uuidString
        summaryDecisionID = source.observationID.rawValue.uuidString
        summaryID = source.summaryID.rawValue.uuidString
        meetingID = source.meetingID.rawValue.uuidString
        observedStatement = source.observedStatement
        sourceTranscriptRevision = source.sourceTranscriptRevision
        observedAt = source.observedAt
        linkedAt = source.linkedAt
    }

    func source(
        evidence: [DecisionEvidenceSegment],
        availability: DecisionEvidenceAvailability
    ) throws -> DecisionSource {
        DecisionSource(
            id: DecisionSourceID(rawValue: try PersistedIdentity.required(
                id, table: Self.databaseTableName, column: "id")),
            decisionID: DecisionID(rawValue: try PersistedIdentity.required(
                decisionID,
                table: Self.databaseTableName,
                column: "decisionID")),
            observationID: SummaryDecisionID(rawValue: try PersistedIdentity.required(
                summaryDecisionID,
                table: Self.databaseTableName,
                column: "summaryDecisionID")),
            summaryID: SummaryID(rawValue: try PersistedIdentity.required(
                summaryID,
                table: Self.databaseTableName,
                column: "summaryID")),
            meetingID: MeetingID(rawValue: try PersistedIdentity.required(
                meetingID,
                table: Self.databaseTableName,
                column: "meetingID")),
            observedStatement: observedStatement,
            sourceTranscriptRevision: sourceTranscriptRevision,
            observedAt: observedAt,
            linkedAt: linkedAt,
            evidence: evidence,
            availability: availability)
    }
}

struct DecisionContinuityEvidenceSegmentRecord:
    Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "decisionContinuityEvidenceSegment"

    var sourceID: String
    var segmentID: String
    var ordinal: Int

    init(sourceID: DecisionSourceID, evidence: DecisionEvidenceSegment) {
        self.sourceID = sourceID.rawValue.uuidString
        segmentID = evidence.segmentID.uuidString
        ordinal = evidence.ordinal
    }

    var evidence: DecisionEvidenceSegment {
        get throws {
            DecisionEvidenceSegment(
                segmentID: try PersistedIdentity.required(
                    segmentID,
                    table: Self.databaseTableName,
                    column: "segmentID"),
                ordinal: ordinal)
        }
    }
}

struct DecisionContinuityEventRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "decisionContinuityEvent"

    var id: String
    var decisionID: String
    var kind: String
    var sourceID: String?
    var relatedDecisionID: String?
    var occurredAt: Date

    init(_ event: DecisionEvent) {
        id = event.id.rawValue.uuidString
        decisionID = event.decisionID.rawValue.uuidString
        kind = event.kind.rawValue
        sourceID = event.sourceID?.rawValue.uuidString
        relatedDecisionID = event.relatedDecisionID?.rawValue.uuidString
        occurredAt = event.occurredAt
    }

    var event: DecisionEvent {
        get throws {
            guard let kind = DecisionEventKind(rawValue: kind) else {
                throw StorageError.invalidPersistedValue(
                    table: Self.databaseTableName,
                    column: "kind",
                    value: self.kind)
            }
            return DecisionEvent(
                id: DecisionEventID(rawValue: try PersistedIdentity.required(
                    id, table: Self.databaseTableName, column: "id")),
                decisionID: DecisionID(rawValue: try PersistedIdentity.required(
                    decisionID,
                    table: Self.databaseTableName,
                    column: "decisionID")),
                kind: kind,
                sourceID: try PersistedIdentity.optional(
                    sourceID,
                    table: Self.databaseTableName,
                    column: "sourceID"
                ).map { DecisionSourceID(rawValue: $0) },
                relatedDecisionID: try PersistedIdentity.optional(
                    relatedDecisionID,
                    table: Self.databaseTableName,
                    column: "relatedDecisionID"
                ).map { DecisionID(rawValue: $0) },
                occurredAt: occurredAt)
        }
    }
}
