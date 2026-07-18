import Foundation
import GRDB
import PortavozCore

extension MeetingStore {
    /// One SQLite snapshot for interfaces that render the current meeting and
    /// its latest General summary together.
    public struct MeetingLibrarySnapshot: Sendable {
        public let detail: MeetingDetail
        public let summary: (draft: SummaryDraft, version: Int)?
    }

    public func meetingLibrarySnapshot(
        _ id: MeetingID
    ) async throws -> MeetingLibrarySnapshot? {
        try await database.read { db in
            guard let core = try Self.fetchMeetingReviewCore(id, in: db) else {
                return nil
            }
            let key = id.rawValue.uuidString
            let summaries = try SummaryRecord
                .filter(Column("meetingID") == key)
                .filter(Column("deletedAt") == nil)
                .order(
                    Column("createdAt").desc,
                    Column("version").desc,
                    Column("recipeID").asc,
                    Column("id").asc)
                .fetchAll(db)
                .map {
                    SummaryInfo(
                        recipeID: $0.recipeID,
                        language: $0.language,
                        version: $0.version,
                        createdAt: $0.createdAt)
                }
            let detail = MeetingDetail(
                meeting: core.meeting,
                speakers: core.speakers,
                segments: core.segments,
                summaries: summaries)
            let summary = try Self.generalSummarySnapshot(
                meetingID: id,
                in: db)
            return MeetingLibrarySnapshot(detail: detail, summary: summary)
        }
    }

    private static func generalSummarySnapshot(
        meetingID: MeetingID,
        in database: Database
    ) throws -> (draft: SummaryDraft, version: Int)? {
        guard let record = try SummaryRecord
            .filter(Column("meetingID") == meetingID.rawValue.uuidString)
            .filter(Column("recipeID") == Recipe.general.id)
            .filter(Column("deletedAt") == nil)
            .order(Column("version").desc)
            .fetchOne(database)
        else { return nil }
        return try summarySnapshot(record, meetingID: meetingID, in: database)
    }
}
