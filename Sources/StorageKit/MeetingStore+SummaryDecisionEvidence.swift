import Foundation
import GRDB
import PortavozCore

extension MeetingStore {
    static func insertSummaryDecisionEvidence(
        _ decisions: [SummaryDecisionEvidence],
        summaryID: String,
        draft: SummaryDraft,
        at timestamp: Date,
        in db: Database
    ) throws {
        guard !decisions.isEmpty else { return }
        let outline = SummaryMarkdownOutline.parse(draft.markdown)
        let positions = decisions.map { Position($0) }
        guard Set(decisions.map(\.id)).count == decisions.count,
              Set(positions).count == positions.count
        else {
            throw StorageError.invalidSummaryClaim(
                "decision evidence identities and positions must be unique")
        }

        for decision in decisions {
            guard outline.sections.indices.contains(decision.sectionOrdinal),
                  outline.sections[decision.sectionOrdinal].bulletLines.indices.contains(
                    decision.bulletOrdinal)
            else {
                throw StorageError.invalidSummaryClaim(
                    "decision evidence must address a rendered summary bullet")
            }
            let evidence = try validatedSummaryEvidence(
                decision.evidenceSegmentIDs,
                unavailableCount: decision.unavailableEvidenceCount,
                sourceRevision: decision.sourceTranscriptRevision,
                meetingID: draft.meetingID,
                in: db)
            let decisionKey = decision.id.rawValue.uuidString
            try SummaryDecisionEvidenceRecord(
                id: decisionKey,
                summaryID: summaryID,
                sectionOrdinal: decision.sectionOrdinal,
                bulletOrdinal: decision.bulletOrdinal,
                sourceTranscriptRevision: evidence.revision,
                createdAt: timestamp)
                .insert(db)
            for (ordinal, evidenceID) in evidence.ids.enumerated() {
                try SummaryDecisionEvidenceSegmentRecord(
                    id: UUID().uuidString,
                    decisionID: decisionKey,
                    segmentID: evidenceID.uuidString,
                    ordinal: ordinal,
                    createdAt: timestamp)
                    .insert(db)
            }
        }
    }

    static func summaryDecisionEvidence(
        summaryID: String,
        in db: Database
    ) throws -> [SummaryDecisionEvidence] {
        try SummaryDecisionEvidenceRecord
            .filter(Column("summaryID") == summaryID)
            .order(Column("sectionOrdinal"), Column("bulletOrdinal"))
            .fetchAll(db)
            .map { record in
                let links = try SummaryDecisionEvidenceSegmentRecord
                    .filter(Column("decisionID") == record.id)
                    .order(Column("ordinal"))
                    .fetchAll(db)
                let evidenceIDs = try links.compactMap { link -> UUID? in
                    guard let value = link.segmentID else { return nil }
                    guard let id = UUID(uuidString: value) else {
                        throw StorageError.invalidPersistedUUID(
                            table: SummaryDecisionEvidenceSegmentRecord.databaseTableName,
                            column: "segmentID",
                            value: value)
                    }
                    return id
                }
                return SummaryDecisionEvidence(
                    id: SummaryDecisionID(rawValue: try PersistedIdentity.required(
                        record.id,
                        table: SummaryDecisionEvidenceRecord.databaseTableName,
                        column: "id")),
                    sectionOrdinal: record.sectionOrdinal,
                    bulletOrdinal: record.bulletOrdinal,
                    sourceTranscriptRevision: record.sourceTranscriptRevision,
                    evidenceSegmentIDs: evidenceIDs,
                    unavailableEvidenceCount: links.count - evidenceIDs.count)
            }
    }

    static func validatedSummaryEvidence(
        _ evidenceIDs: [UUID],
        unavailableCount: Int,
        sourceRevision: Int?,
        meetingID: MeetingID,
        in db: Database
    ) throws -> (ids: [UUID], revision: Int) {
        guard unavailableCount == 0,
              !evidenceIDs.isEmpty,
              Set(evidenceIDs).count == evidenceIDs.count
        else {
            throw StorageError.invalidSummaryClaim(
                "new evidence must be nonempty, available, and unique")
        }
        let meetingKey = meetingID.rawValue.uuidString
        guard let meeting = try MeetingRecord.fetchOne(db, key: meetingKey) else {
            throw StorageError.meetingNotFound(meetingID)
        }
        if let sourceRevision, sourceRevision != meeting.transcriptRevision {
            throw StorageError.invalidSummaryClaim(
                "source transcript revision does not match the meeting")
        }
        for evidenceID in evidenceIDs {
            guard let segment = try SegmentRecord.fetchOne(
                db, key: evidenceID.uuidString),
                segment.meetingID == meetingKey,
                segment.deletedAt == nil
            else {
                throw StorageError.invalidSummaryClaim(
                    "evidence must reference a live segment in the same meeting")
            }
        }
        return (evidenceIDs, meeting.transcriptRevision)
    }
}

private struct Position: Hashable {
    let section: Int
    let bullet: Int

    init(_ evidence: SummaryDecisionEvidence) {
        section = evidence.sectionOrdinal
        bullet = evidence.bulletOrdinal
    }
}
