import Foundation
import GRDB
import PortavozCore

extension MeetingStore {
    static func insertSummaryActionItemEvidence(
        _ evidence: [SummaryActionItemEvidence],
        draft: SummaryDraft,
        at timestamp: Date,
        in db: Database
    ) throws {
        guard !evidence.isEmpty else { return }
        let actionItemIDs = Set(draft.actionItems.map(\.id))
        guard Set(evidence.map(\.id)).count == evidence.count,
              Set(evidence.map(\.actionItemID)).count == evidence.count,
              evidence.allSatisfy({ actionItemIDs.contains($0.actionItemID) })
        else {
            throw StorageError.invalidSummaryClaim(
                "action-item evidence identities and targets must be unique and local")
        }

        for itemEvidence in evidence {
            let validated = try validatedSummaryEvidence(
                itemEvidence.evidenceSegmentIDs,
                unavailableCount: itemEvidence.unavailableEvidenceCount,
                sourceRevision: itemEvidence.sourceTranscriptRevision,
                meetingID: draft.meetingID,
                in: db)
            let evidenceKey = itemEvidence.id.rawValue.uuidString
            try SummaryActionItemEvidenceRecord(
                id: evidenceKey,
                actionItemID: itemEvidence.actionItemID.uuidString,
                sourceTranscriptRevision: validated.revision,
                createdAt: timestamp)
                .insert(db)
            for (ordinal, segmentID) in validated.ids.enumerated() {
                try SummaryActionItemEvidenceSegmentRecord(
                    id: UUID().uuidString,
                    evidenceID: evidenceKey,
                    segmentID: segmentID.uuidString,
                    ordinal: ordinal,
                    createdAt: timestamp)
                    .insert(db)
            }
        }
    }

    static func summaryActionItemEvidence(
        actionItems: [ActionItem],
        in db: Database
    ) throws -> [SummaryActionItemEvidence] {
        try actionItems.compactMap { item in
            guard let record = try SummaryActionItemEvidenceRecord
                .filter(Column("actionItemID") == item.id.uuidString)
                .fetchOne(db)
            else { return nil }
            let links = try SummaryActionItemEvidenceSegmentRecord
                .filter(Column("evidenceID") == record.id)
                .order(Column("ordinal"))
                .fetchAll(db)
            let segmentIDs = try links.compactMap { link -> UUID? in
                guard let value = link.segmentID else { return nil }
                guard let id = UUID(uuidString: value) else {
                    throw StorageError.invalidPersistedUUID(
                        table: SummaryActionItemEvidenceSegmentRecord.databaseTableName,
                        column: "segmentID",
                        value: value)
                }
                return id
            }
            return SummaryActionItemEvidence(
                id: SummaryActionItemEvidenceID(rawValue: try PersistedIdentity.required(
                    record.id,
                    table: SummaryActionItemEvidenceRecord.databaseTableName,
                    column: "id")),
                actionItemID: item.id,
                sourceTranscriptRevision: record.sourceTranscriptRevision,
                evidenceSegmentIDs: segmentIDs,
                unavailableEvidenceCount: links.count - segmentIDs.count)
        }
    }
}
