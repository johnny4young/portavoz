import Foundation
import GRDB
import PortavozCore

struct CommitmentRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "commitment"

    var id: String
    var assigneeKind: String
    var canonicalPersonID: String?
    var title: String
    var status: String
    var dueAt: Date?
    var createdAt: Date
    var updatedAt: Date
    var deletedAt: Date?

    init(_ commitment: Commitment) {
        id = commitment.id.rawValue.uuidString
        assigneeKind = commitment.assignee.kind.rawValue
        canonicalPersonID = commitment.canonicalPersonID?.rawValue.uuidString
        title = commitment.title
        status = commitment.status.rawValue
        dueAt = commitment.dueAt
        createdAt = commitment.createdAt
        updatedAt = commitment.updatedAt
        deletedAt = commitment.deletedAt
    }

    var commitment: Commitment {
        get throws {
            guard let status = CommitmentStatus(rawValue: status) else {
                throw StorageError.invalidPersistedValue(
                    table: Self.databaseTableName,
                    column: "status",
                    value: self.status)
            }
            guard let kind = CommitmentAssigneeKind(rawValue: assigneeKind),
                  let assignee = CommitmentAssignee(
                      kind: kind,
                      canonicalPersonID: try PersistedIdentity.optional(
                          canonicalPersonID,
                          table: Self.databaseTableName,
                          column: "canonicalPersonID"
                      ).map { PersonID(rawValue: $0) })
            else {
                throw StorageError.invalidPersistedValue(
                    table: Self.databaseTableName,
                    column: "assigneeKind",
                    value: assigneeKind)
            }
            return Commitment(
                id: CommitmentID(rawValue: try PersistedIdentity.required(
                    id, table: Self.databaseTableName, column: "id")),
                title: title,
                status: status,
                assignee: assignee,
                dueAt: dueAt,
                createdAt: createdAt,
                updatedAt: updatedAt,
                deletedAt: deletedAt)
        }
    }
}

struct CommitmentSourceRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "commitmentSource"

    var id: String
    var commitmentID: String
    var kind: String
    var meetingID: String?
    var actionItemID: String?
    var contextItemID: String?
    var transcriptRevision: Int?
    var firstSeenAt: Date

    init(_ source: CommitmentSource) {
        id = source.id.rawValue.uuidString
        commitmentID = source.commitmentID.rawValue.uuidString
        kind = source.kind.rawValue
        meetingID = source.meetingID?.rawValue.uuidString
        actionItemID = source.actionItemID?.uuidString
        contextItemID = source.contextItemID?.uuidString
        transcriptRevision = source.transcriptRevision
        firstSeenAt = source.firstSeenAt
    }

    func source(evidence: [CommitmentEvidenceSegment]) throws -> CommitmentSource {
        guard let kind = CommitmentSourceKind(rawValue: kind) else {
            throw StorageError.invalidPersistedValue(
                table: Self.databaseTableName,
                column: "kind",
                value: self.kind)
        }
        return CommitmentSource(
            id: CommitmentSourceID(rawValue: try PersistedIdentity.required(
                id, table: Self.databaseTableName, column: "id")),
            commitmentID: CommitmentID(rawValue: try PersistedIdentity.required(
                commitmentID,
                table: Self.databaseTableName,
                column: "commitmentID")),
            kind: kind,
            meetingID: try PersistedIdentity.optional(
                meetingID,
                table: Self.databaseTableName,
                column: "meetingID"
            ).map { MeetingID(rawValue: $0) },
            actionItemID: try PersistedIdentity.optional(
                actionItemID,
                table: Self.databaseTableName,
                column: "actionItemID"),
            contextItemID: try PersistedIdentity.optional(
                contextItemID,
                table: Self.databaseTableName,
                column: "contextItemID"),
            transcriptRevision: transcriptRevision,
            firstSeenAt: firstSeenAt,
            evidence: evidence)
    }
}

struct CommitmentEvidenceSegmentRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "commitmentEvidenceSegment"

    var sourceID: String
    var segmentID: String?
    var role: String
    var ordinal: Int

    init(sourceID: CommitmentSourceID, evidence: CommitmentEvidenceSegment) {
        self.sourceID = sourceID.rawValue.uuidString
        segmentID = evidence.segmentID?.uuidString
        role = evidence.role.rawValue
        ordinal = evidence.ordinal
    }

    var evidence: CommitmentEvidenceSegment {
        get throws {
            guard let role = CommitmentEvidenceRole(rawValue: role) else {
                throw StorageError.invalidPersistedValue(
                    table: Self.databaseTableName,
                    column: "role",
                    value: self.role)
            }
            return CommitmentEvidenceSegment(
                segmentID: try PersistedIdentity.optional(
                    segmentID,
                    table: Self.databaseTableName,
                    column: "segmentID"),
                role: role,
                ordinal: ordinal)
        }
    }
}

struct CommitmentEventRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "commitmentEvent"

    var id: String
    var commitmentID: String
    var kind: String
    var assigneeKind: String?
    var canonicalPersonID: String?
    var dueAt: Date?
    var sourceMeetingID: String?
    var sourceTranscriptRevision: Int?
    var occurredAt: Date

    init(_ event: CommitmentEvent) {
        id = event.id.rawValue.uuidString
        commitmentID = event.commitmentID.rawValue.uuidString
        kind = event.kind.rawValue
        assigneeKind = event.assignee?.kind.rawValue
        canonicalPersonID = event.canonicalPersonID?.rawValue.uuidString
        dueAt = event.dueAt
        sourceMeetingID = event.sourceMeetingID?.rawValue.uuidString
        sourceTranscriptRevision = event.evidence?.sourceTranscriptRevision
        occurredAt = event.occurredAt
    }

    func event(evidenceSegmentIDs: [UUID]) throws -> CommitmentEvent {
        guard let kind = CommitmentEventKind(rawValue: kind) else {
            throw StorageError.invalidPersistedValue(
                table: Self.databaseTableName,
                column: "kind",
                value: self.kind)
        }
        let assignee = try persistedAssignee()
        let sourceMeetingID = try PersistedIdentity.optional(
            sourceMeetingID,
            table: Self.databaseTableName,
            column: "sourceMeetingID"
        ).map { MeetingID(rawValue: $0) }
        let evidence = try persistedEvidence(
            meetingID: sourceMeetingID,
            segmentIDs: evidenceSegmentIDs)
        return CommitmentEvent(
            id: CommitmentEventID(rawValue: try PersistedIdentity.required(
                id, table: Self.databaseTableName, column: "id")),
            commitmentID: CommitmentID(rawValue: try PersistedIdentity.required(
                commitmentID,
                table: Self.databaseTableName,
                column: "commitmentID")),
            kind: kind,
            assignee: assignee,
            dueAt: dueAt,
            sourceMeetingID: sourceMeetingID,
            evidence: evidence,
            occurredAt: occurredAt)
    }

    private func persistedAssignee() throws -> CommitmentAssignee? {
        let personID = try PersistedIdentity.optional(
            canonicalPersonID,
            table: Self.databaseTableName,
            column: "canonicalPersonID"
        ).map { PersonID(rawValue: $0) }
        let assignee: CommitmentAssignee?
        if let assigneeKind {
            guard let value = CommitmentAssigneeKind(rawValue: assigneeKind),
                  let decoded = CommitmentAssignee(
                      kind: value,
                      canonicalPersonID: personID)
            else {
                throw StorageError.invalidPersistedValue(
                    table: Self.databaseTableName,
                    column: "assigneeKind",
                    value: assigneeKind)
            }
            assignee = decoded
        } else {
            guard personID == nil else {
                throw StorageError.invalidPersistedValue(
                    table: Self.databaseTableName,
                    column: "canonicalPersonID",
                    value: canonicalPersonID ?? "")
            }
            assignee = nil
        }
        return assignee
    }

    private func persistedEvidence(
        meetingID: MeetingID?,
        segmentIDs: [UUID]
    ) throws -> CommitmentEventEvidence? {
        let evidence: CommitmentEventEvidence?
        if let sourceTranscriptRevision {
            guard let meetingID else {
                throw StorageError.invalidPersistedValue(
                    table: Self.databaseTableName,
                    column: "sourceTranscriptRevision",
                    value: String(sourceTranscriptRevision))
            }
            evidence = CommitmentEventEvidence(
                meetingID: meetingID,
                sourceTranscriptRevision: sourceTranscriptRevision,
                segmentIDs: segmentIDs)
        } else {
            guard segmentIDs.isEmpty else {
                throw StorageError.invalidPersistedValue(
                    table: Self.databaseTableName,
                    column: "sourceTranscriptRevision",
                    value: "missing")
            }
            evidence = nil
        }
        return evidence
    }
}

struct CommitmentEventEvidenceSegmentRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "commitmentEventEvidenceSegment"

    var eventID: String
    var segmentID: String
    var ordinal: Int

    init(
        eventID: CommitmentEventID,
        segmentID: UUID,
        ordinal: Int
    ) {
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
