import Foundation
import GRDB
import PortavozCore

extension MeetingStore {
    /// Reads one bounded snapshot of open continuity targets and their exact
    /// source identities. The semantic query remains an ApplicationKit concern;
    /// this adapter neither scores nor mutates commitments.
    public func commitmentLinkSuggestionTargets(
        limit: Int = CommitmentLinkSuggestionPolicy.maximumTargetCount
    ) async throws -> [CommitmentLinkSuggestionTarget] {
        guard (1...CommitmentLinkSuggestionPolicy.maximumTargetCount).contains(limit)
        else { return [] }

        return try await database.read { database in
            let roots = try CommitmentRecord
                .filter(Column("status") == CommitmentStatus.confirmed.rawValue)
                .filter(Column("deletedAt") == nil)
                .order(Column("updatedAt").desc, Column("id"))
                .limit(limit)
                .fetchAll(database)
            guard !roots.isEmpty else { return [] }

            let keys = roots.map(\.id)
            let sourceRows = try Self.commitmentLinkSourceRows(
                commitmentKeys: keys,
                in: database)
            let evidenceRows = try Self.commitmentLinkEvidenceRows(
                commitmentKeys: keys,
                in: database)
            let sourcesByCommitment = Dictionary(
                grouping: sourceRows,
                by: \.commitmentID)
            let evidenceByCommitment = Dictionary(
                grouping: evidenceRows,
                by: \.commitmentID)

            return try roots.compactMap { root in
                let sources = sourcesByCommitment[root.id] ?? []
                guard let sourceCount = sources.first?.relatedRowCount,
                      sourceCount == sources.count,
                      sourceCount <= CommitmentLinkSuggestionPolicy.maximumRelatedRowCount
                else { return nil }

                let evidence = evidenceByCommitment[root.id] ?? []
                let evidenceCount = evidence.first?.relatedRowCount ?? 0
                guard evidenceCount == evidence.count,
                      evidenceCount
                        <= CommitmentLinkSuggestionPolicy.maximumRelatedRowCount
                else { return nil }

                return CommitmentLinkSuggestionTarget(
                    commitment: try root.commitment,
                    sourceMeetingIDs: try sources.compactMap {
                        try $0.meetingIdentity
                    },
                    evidenceSegmentIDs: try evidence.map {
                        try $0.segmentIdentity
                    })
            }
        }
    }
}

private extension MeetingStore {
    static func commitmentLinkSourceRows(
        commitmentKeys: [String],
        in database: Database
    ) throws -> [CommitmentLinkSourceRow] {
        let placeholders = databaseQuestionMarks(count: commitmentKeys.count)
        var arguments = StatementArguments(commitmentKeys)
        arguments += StatementArguments([
            CommitmentLinkSuggestionPolicy.maximumRelatedRowCount + 1
        ])
        return try CommitmentLinkSourceRow.fetchAll(
            database,
            sql: """
                WITH rankedSource AS (
                    SELECT commitmentID,
                           meetingID,
                           ROW_NUMBER() OVER (
                               PARTITION BY commitmentID
                               ORDER BY firstSeenAt ASC, id ASC
                           ) AS rowRank,
                           COUNT(*) OVER (
                               PARTITION BY commitmentID
                           ) AS relatedRowCount
                    FROM commitmentSource
                    WHERE commitmentID IN (\(placeholders))
                )
                SELECT commitmentID, meetingID, relatedRowCount
                FROM rankedSource
                WHERE rowRank <= ?
                ORDER BY commitmentID ASC, rowRank ASC
                """,
            arguments: arguments)
    }

    static func commitmentLinkEvidenceRows(
        commitmentKeys: [String],
        in database: Database
    ) throws -> [CommitmentLinkEvidenceRow] {
        let placeholders = databaseQuestionMarks(count: commitmentKeys.count)
        var arguments = StatementArguments(commitmentKeys)
        arguments += StatementArguments([
            CommitmentLinkSuggestionPolicy.maximumRelatedRowCount + 1
        ])
        return try CommitmentLinkEvidenceRow.fetchAll(
            database,
            sql: """
                WITH rankedEvidence AS (
                    SELECT source.commitmentID,
                           evidence.segmentID,
                           ROW_NUMBER() OVER (
                               PARTITION BY source.commitmentID
                               ORDER BY source.firstSeenAt ASC,
                                        source.id ASC,
                                        evidence.ordinal ASC
                           ) AS rowRank,
                           COUNT(*) OVER (
                               PARTITION BY source.commitmentID
                           ) AS relatedRowCount
                    FROM commitmentSource AS source
                    JOIN commitmentEvidenceSegment AS evidence
                      ON evidence.sourceID = source.id
                    WHERE source.commitmentID IN (\(placeholders))
                      AND evidence.segmentID IS NOT NULL
                )
                SELECT commitmentID, segmentID, relatedRowCount
                FROM rankedEvidence
                WHERE rowRank <= ?
                ORDER BY commitmentID ASC, rowRank ASC
                """,
            arguments: arguments)
    }
}

private struct CommitmentLinkSourceRow: Decodable, FetchableRecord {
    let commitmentID: String
    let meetingID: String?
    let relatedRowCount: Int

    var meetingIdentity: MeetingID? {
        get throws {
            try PersistedIdentity.optional(
                meetingID,
                table: CommitmentSourceRecord.databaseTableName,
                column: "meetingID"
            ).map(MeetingID.init(rawValue:))
        }
    }
}

private struct CommitmentLinkEvidenceRow: Decodable, FetchableRecord {
    let commitmentID: String
    let segmentID: String
    let relatedRowCount: Int

    var segmentIdentity: UUID {
        get throws {
            try PersistedIdentity.required(
                segmentID,
                table: CommitmentEvidenceSegmentRecord.databaseTableName,
                column: "segmentID")
        }
    }
}
