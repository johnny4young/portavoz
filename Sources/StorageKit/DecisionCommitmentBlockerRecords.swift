import Foundation
import GRDB
import PortavozCore

struct DecisionCommitmentBlockerRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "decisionCommitmentBlocker"

    var id: String
    var decisionID: String
    var commitmentID: String
    var status: String
    var sourceMeetingID: String
    var sourceTranscriptRevision: Int
    var primarySegmentID: String
    var confirmedAt: Date
    var updatedAt: Date
    var latestEventID: String?
    var deletedAt: Date?

    init(
        blocker: DecisionCommitmentBlocker,
        openingEvidence: DecisionCommitmentBlockerEvidence
    ) throws {
        guard let primarySegmentID = openingEvidence.segmentIDs.first else {
            throw StorageError.invalidDecisionCommitmentBlocker(
                "blocker opening evidence must include a segment")
        }
        id = blocker.id.rawValue.uuidString
        decisionID = blocker.decisionID.rawValue.uuidString
        commitmentID = blocker.commitmentID.rawValue.uuidString
        status = blocker.status.rawValue
        sourceMeetingID = openingEvidence.meetingID.rawValue.uuidString
        sourceTranscriptRevision = openingEvidence.sourceTranscriptRevision
        self.primarySegmentID = primarySegmentID.uuidString
        confirmedAt = blocker.confirmedAt
        updatedAt = blocker.updatedAt
        latestEventID = nil
        deletedAt = nil
    }

    func blocker() throws -> DecisionCommitmentBlocker {
        guard let status = DecisionCommitmentBlockerStatus(rawValue: status) else {
            throw StorageError.invalidPersistedValue(
                table: Self.databaseTableName,
                column: "status",
                value: self.status)
        }
        return DecisionCommitmentBlocker(
            id: DecisionCommitmentBlockerID(rawValue: try required("id", id)),
            decisionID: DecisionID(rawValue: try required("decisionID", decisionID)),
            commitmentID: CommitmentID(
                rawValue: try required("commitmentID", commitmentID)),
            status: status,
            confirmedAt: confirmedAt,
            updatedAt: updatedAt)
    }

    func openingEvidence(
        additionalSegmentIDs: [UUID]
    ) throws -> DecisionCommitmentBlockerEvidence {
        DecisionCommitmentBlockerEvidence(
            meetingID: MeetingID(
                rawValue: try required("sourceMeetingID", sourceMeetingID)),
            sourceTranscriptRevision: sourceTranscriptRevision,
            segmentIDs: [try required("primarySegmentID", primarySegmentID)]
                + additionalSegmentIDs)
    }

    private func required(_ column: String, _ value: String) throws -> UUID {
        try PersistedIdentity.required(
            value,
            table: Self.databaseTableName,
            column: column)
    }
}

struct DecisionCommitmentBlockerEventRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "decisionCommitmentBlockerEvent"

    var id: String
    var blockerID: String
    var kind: String
    var sourceMeetingID: String
    var sourceTranscriptRevision: Int
    var primarySegmentID: String
    var occurredAt: Date

    init(_ event: DecisionCommitmentBlockerEvent) throws {
        guard let primarySegmentID = event.evidence.segmentIDs.first else {
            throw StorageError.invalidDecisionCommitmentBlocker(
                "blocker event evidence must include a segment")
        }
        id = event.id.rawValue.uuidString
        blockerID = event.blockerID.rawValue.uuidString
        kind = event.kind.rawValue
        sourceMeetingID = event.evidence.meetingID.rawValue.uuidString
        sourceTranscriptRevision = event.evidence.sourceTranscriptRevision
        self.primarySegmentID = primarySegmentID.uuidString
        occurredAt = event.occurredAt
    }

    func event(
        additionalSegmentIDs: [UUID]
    ) throws -> DecisionCommitmentBlockerEvent {
        guard let kind = DecisionCommitmentBlockerEventKind(rawValue: kind) else {
            throw StorageError.invalidPersistedValue(
                table: Self.databaseTableName,
                column: "kind",
                value: self.kind)
        }
        return DecisionCommitmentBlockerEvent(
            id: DecisionCommitmentBlockerEventID(
                rawValue: try required("id", id)),
            blockerID: DecisionCommitmentBlockerID(
                rawValue: try required("blockerID", blockerID)),
            kind: kind,
            evidence: DecisionCommitmentBlockerEvidence(
                meetingID: MeetingID(
                    rawValue: try required("sourceMeetingID", sourceMeetingID)),
                sourceTranscriptRevision: sourceTranscriptRevision,
                segmentIDs: [try required("primarySegmentID", primarySegmentID)]
                    + additionalSegmentIDs),
            occurredAt: occurredAt)
    }

    private func required(_ column: String, _ value: String) throws -> UUID {
        try PersistedIdentity.required(
            value,
            table: Self.databaseTableName,
            column: column)
    }
}

struct BlockerEvidenceSegmentRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "decisionCommitmentBlockerEvidenceSegment"

    var blockerID: String
    var segmentID: String
    var ordinal: Int

    init(blockerID: DecisionCommitmentBlockerID, segmentID: UUID, ordinal: Int) {
        self.blockerID = blockerID.rawValue.uuidString
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

struct BlockerEventEvidenceSegmentRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "decisionCommitmentBlockerEventEvidenceSegment"

    var eventID: String
    var segmentID: String
    var ordinal: Int

    init(eventID: DecisionCommitmentBlockerEventID, segmentID: UUID, ordinal: Int) {
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
