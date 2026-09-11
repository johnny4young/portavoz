import Foundation
import GRDB
import PortavozCore

extension MeetingStore {
    public func decisionObservation(
        for observationID: SummaryDecisionID
    ) async throws -> DecisionObservation {
        try await database.read { database in
            try Self.loadDecisionObservation(observationID, in: database)
        }
    }

    static func loadDecisionObservation(
        _ observationID: SummaryDecisionID,
        in database: Database
    ) throws -> DecisionObservation {
        let observationKey = observationID.rawValue.uuidString
        guard let record = try SummaryDecisionEvidenceRecord.fetchOne(
            database,
            key: observationKey),
              let summary = try SummaryRecord.fetchOne(database, key: record.summaryID),
              summary.deletedAt == nil,
              let meeting = try MeetingRecord.fetchOne(database, key: summary.meetingID),
              meeting.deletedAt == nil
        else {
            throw StorageError.invalidDecisionContinuity(
                "generated decision observation is unavailable")
        }
        let outline = SummaryMarkdownOutline.parse(summary.markdown)
        guard let statement = outline.bulletText(
            sectionOrdinal: record.sectionOrdinal,
            bulletOrdinal: record.bulletOrdinal)
        else {
            throw StorageError.invalidDecisionContinuity(
                "generated decision observation no longer addresses a rendered bullet")
        }
        let links = try SummaryDecisionEvidenceSegmentRecord
            .filter(Column("decisionID") == observationKey)
            .order(Column("ordinal"))
            .fetchAll(database)
        let evidence = try links.compactMap { link -> DecisionEvidenceSegment? in
            guard let value = link.segmentID else { return nil }
            return DecisionEvidenceSegment(
                segmentID: try PersistedIdentity.required(
                    value,
                    table: SummaryDecisionEvidenceSegmentRecord.databaseTableName,
                    column: "segmentID"),
                ordinal: link.ordinal)
        }
        return DecisionObservation(
            id: observationID,
            summaryID: SummaryID(rawValue: try PersistedIdentity.required(
                summary.id,
                table: SummaryRecord.databaseTableName,
                column: "id")),
            meetingID: MeetingID(rawValue: try PersistedIdentity.required(
                summary.meetingID,
                table: SummaryRecord.databaseTableName,
                column: "meetingID")),
            statement: statement,
            sourceTranscriptRevision: record.sourceTranscriptRevision,
            observedAt: summary.createdAt,
            evidence: evidence,
            availability: try decisionEvidenceAvailability(
                meetingID: summary.meetingID,
                sourceTranscriptRevision: record.sourceTranscriptRevision,
                evidence: evidence,
                unavailableEvidenceCount: links.count - evidence.count,
                in: database))
    }

    static func decisionObservationForConfirmation(
        _ observationID: SummaryDecisionID,
        in database: Database
    ) throws -> DecisionObservation {
        let observation = try loadDecisionObservation(observationID, in: database)
        guard observation.availability == .current,
              !observation.evidence.isEmpty,
              observation.evidence.map(\.ordinal)
                == Array(0..<observation.evidence.count)
        else {
            throw StorageError.invalidDecisionContinuity(
                "generated decision lacks complete current transcript evidence")
        }
        return observation
    }

    static func decisionEvidenceAvailability(
        meetingID: String,
        sourceTranscriptRevision: Int,
        evidence: [DecisionEvidenceSegment],
        unavailableEvidenceCount: Int = 0,
        in database: Database
    ) throws -> DecisionEvidenceAvailability {
        guard unavailableEvidenceCount == 0,
              !evidence.isEmpty,
              let meeting = try MeetingRecord.fetchOne(database, key: meetingID),
              meeting.deletedAt == nil
        else { return .unavailable }

        let segmentIDs = evidence.map { $0.segmentID.uuidString }
        let acceptedCount = try Int.fetchOne(
            database,
            sql: """
                SELECT COUNT(*)
                FROM segment
                WHERE segment.id IN (\(decisionPlaceholders(segmentIDs.count)))
                  AND segment.meetingID = ?
                  AND segment.deletedAt IS NULL
                  AND segment.isFinal = 1
                  AND \(acceptedSegmentHasNoActiveCorrectionSQL)
                """,
            arguments: StatementArguments(segmentIDs + [meetingID])) ?? 0
        guard acceptedCount == segmentIDs.count else { return .unavailable }
        return meeting.transcriptRevision == sourceTranscriptRevision
            ? .current
            : .stale
    }

    static func decisionEvidenceAvailability(
        _ source: DecisionContinuitySourceRecord,
        evidence: [DecisionEvidenceSegment],
        in database: Database
    ) throws -> DecisionEvidenceAvailability {
        try decisionEvidenceAvailability(
            meetingID: source.meetingID,
            sourceTranscriptRevision: source.sourceTranscriptRevision,
            evidence: evidence,
            in: database)
    }

    private static func decisionPlaceholders(_ count: Int) -> String {
        guard count > 0 else { return "NULL" }
        return Array(repeating: "?", count: count).joined(separator: ",")
    }
}
