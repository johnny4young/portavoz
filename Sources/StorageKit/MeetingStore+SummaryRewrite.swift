import Foundation
import GRDB
import PortavozCore

extension MeetingStore {
    /// Saves a deterministic rewrite of the meeting's current summary as its
    /// next version, linked to the run that generated the original text so its
    /// freshness is unchanged. Returns nil when there is nothing to rewrite.
    @discardableResult
    public func rewriteCurrentSummary(
        meetingID: MeetingID,
        _ rewrite: @escaping @Sendable (SummaryDraft) -> SummaryDraft?
    ) async throws -> Int? {
        let meetingKey = meetingID.rawValue.uuidString
        return try await database.write { db in
            guard try MeetingRecord
                .filter(Column("id") == meetingKey)
                .filter(Column("deletedAt") == nil)
                .fetchCount(db) > 0,
                let record = try SummaryRecord
                    .filter(Column("meetingID") == meetingKey)
                    .filter(Column("deletedAt") == nil)
                    .order(Column("createdAt").desc, Column("rowid").desc)
                    .fetchOne(db)
            else { return nil }
            let current = try Self.summarySnapshot(record, meetingID: meetingID, in: db)
            guard let next = rewrite(current.draft) else { return nil }
            let runID = try PersistedIdentity.optional(
                record.generationRunID,
                table: SummaryRecord.databaseTableName,
                column: "generationRunID"
            ).map { GenerationRunID(rawValue: $0) }
            return try Self.insertSummarySnapshot(
                next,
                at: max(Date(), record.createdAt.addingTimeInterval(0.001)),
                generationRunID: runID,
                allowClaimFeedback: true,
                in: db)
        }
    }
}
