import Foundation
import GRDB
import PortavozCore

extension MeetingStore {
    /// Replaces or clears the user's current assessment of the active overview
    /// claim. Generated Markdown and evidence remain immutable; a newer summary
    /// makes an in-flight write stale rather than annotating hidden history.
    public func setSummaryClaimFeedback(
        _ feedback: SummaryClaimFeedback?,
        for claimID: SummaryClaimID,
        meetingID: MeetingID
    ) async throws {
        try await database.write { db in
            guard try MeetingRecord
                .filter(Column("id") == meetingID.rawValue.uuidString)
                .filter(Column("deletedAt") == nil)
                .fetchCount(db) > 0
            else {
                throw StorageError.meetingNotFound(meetingID)
            }
            let claimKey = claimID.rawValue.uuidString
            guard try Self.isActiveSummaryClaim(
                claimKey,
                meetingID: meetingID,
                in: db)
            else {
                throw StorageError.invalidSummaryClaim(
                    "feedback target is no longer the active summary claim")
            }
            try Self.persistSummaryClaimFeedback(
                feedback,
                claimKey: claimKey,
                at: Date(),
                in: db)
        }
    }

    static func insertInitialSummaryClaimFeedback(
        _ feedback: SummaryClaimFeedback?,
        claimKey: String,
        at timestamp: Date,
        in db: Database
    ) throws {
        guard let feedback else { return }
        try SummaryClaimFeedbackRecord(
            claimID: claimKey,
            kind: feedback.kind.rawValue,
            correctionText: feedback.correctionText,
            createdAt: timestamp,
            updatedAt: timestamp,
            deletedAt: nil)
            .insert(db)
    }

    static func summaryClaimFeedback(
        claimID: String,
        in db: Database
    ) throws -> SummaryClaimFeedback? {
        guard let record = try SummaryClaimFeedbackRecord
            .filter(Column("claimID") == claimID)
            .filter(Column("deletedAt") == nil)
            .fetchOne(db)
        else { return nil }
        guard let kind = SummaryClaimFeedbackKind(rawValue: record.kind) else {
            throw StorageError.invalidPersistedValue(
                table: SummaryClaimFeedbackRecord.databaseTableName,
                column: "kind",
                value: record.kind)
        }
        switch kind {
        case .correction:
            guard let feedback = record.correctionText.flatMap(SummaryClaimFeedback.correction)
            else {
                throw StorageError.invalidPersistedValue(
                    table: SummaryClaimFeedbackRecord.databaseTableName,
                    column: "correctionText",
                    value: record.correctionText ?? "NULL")
            }
            return feedback
        case .unsupported:
            guard record.correctionText == nil else {
                throw StorageError.invalidPersistedValue(
                    table: SummaryClaimFeedbackRecord.databaseTableName,
                    column: "correctionText",
                    value: record.correctionText ?? "")
            }
            return .unsupported
        }
    }

    private static func isActiveSummaryClaim(
        _ claimKey: String,
        meetingID: MeetingID,
        in db: Database
    ) throws -> Bool {
        try Bool.fetchOne(
            db,
            sql: """
                SELECT EXISTS (
                    SELECT 1
                    FROM summaryClaim AS claim
                    JOIN summary AS artifact ON artifact.id = claim.summaryID
                    WHERE claim.id = ?
                      AND artifact.meetingID = ?
                      AND artifact.deletedAt IS NULL
                      AND artifact.rowid = (
                          SELECT rowid
                          FROM summary
                          WHERE meetingID = ? AND deletedAt IS NULL
                          ORDER BY createdAt DESC, rowid DESC
                          LIMIT 1
                      )
                )
                """,
            arguments: [
                claimKey,
                meetingID.rawValue.uuidString,
                meetingID.rawValue.uuidString
            ]) ?? false
    }

    private static func persistSummaryClaimFeedback(
        _ feedback: SummaryClaimFeedback?,
        claimKey: String,
        at timestamp: Date,
        in db: Database
    ) throws {
        let current = try SummaryClaimFeedbackRecord.fetchOne(db, key: claimKey)
        guard let feedback else {
            guard var current, current.deletedAt == nil else { return }
            current.correctionText = nil
            current.updatedAt = timestamp
            current.deletedAt = timestamp
            try current.update(db)
            return
        }
        if var current {
            current.kind = feedback.kind.rawValue
            current.correctionText = feedback.correctionText
            current.updatedAt = timestamp
            current.deletedAt = nil
            try current.update(db)
        } else {
            try insertInitialSummaryClaimFeedback(
                feedback,
                claimKey: claimKey,
                at: timestamp,
                in: db)
        }
    }
}
