import Foundation
import GRDB
import PortavozCore

extension MeetingStore {
    /// One bounded, snapshot-consistent review read. Roots and evidence use at
    /// most two SELECT statements regardless of the number of queue items.
    public func commitmentReviewQueue(
        _ query: CommitmentReviewQueueQuery
    ) async throws -> CommitmentReviewQueuePage {
        if case .meetings(let meetingIDs) = query.scope, meetingIDs.isEmpty {
            return CommitmentReviewQueuePage(items: [], totalCount: 0)
        }
        return try await database.read { database in
            let roots = try Self.commitmentReviewQueueRoots(query, in: database)
            guard !roots.isEmpty else {
                return CommitmentReviewQueuePage(items: [], totalCount: 0)
            }
            let evidenceRows = try Self.commitmentReviewQueueEvidence(
                evidenceKeys: roots.map(\.evidenceID),
                limitPerItem: query.evidenceLimitPerItem,
                in: database)
            let evidenceByID = Dictionary(grouping: evidenceRows, by: \.evidenceID)
            let items = try roots.map { root in
                try root.item(
                    evidenceRows: evidenceByID[root.evidenceID] ?? [],
                    evidenceLimit: query.evidenceLimitPerItem,
                    reviewAt: query.reviewAt)
            }
            return CommitmentReviewQueuePage(
                items: items,
                totalCount: roots.first?.totalCount ?? 0)
        }
    }
}

private extension MeetingStore {
    static func commitmentReviewQueueRoots(
        _ query: CommitmentReviewQueueQuery,
        in database: Database
    ) throws -> [CommitmentReviewQueueRootRow] {
        var scopePredicate = ""
        var arguments: StatementArguments = [query.reviewAt]
        if case .meetings(let meetingIDs) = query.scope {
            scopePredicate = "AND meeting.id IN (\(databaseQuestionMarks(count: meetingIDs.count)))"
            arguments += StatementArguments(meetingIDs.map { $0.rawValue.uuidString })
        }
        arguments += StatementArguments([query.itemLimit])

        return try CommitmentReviewQueueRootRow.fetchAll(
            database,
            sql: commitmentReviewQueueRootSQL.replacingOccurrences(
                of: "__SCOPE_PREDICATE__",
                with: scopePredicate),
            arguments: arguments)
    }

    static func commitmentReviewQueueEvidence(
        evidenceKeys: [String],
        limitPerItem: Int,
        in database: Database
    ) throws -> [CommitmentReviewQueueEvidenceRow] {
        let placeholders = databaseQuestionMarks(count: evidenceKeys.count)
        var arguments = StatementArguments(evidenceKeys)
        arguments += StatementArguments([limitPerItem])
        return try CommitmentReviewQueueEvidenceRow.fetchAll(
            database,
            sql: """
                WITH rankedEvidence AS (
                    SELECT link.evidenceID,
                           link.ordinal,
                           segment.id AS segmentID,
                           segment.meetingID,
                           segment.speakerID,
                           segment.channel,
                           segment.text,
                           segment.language,
                           segment.startTime,
                           segment.endTime,
                           segment.confidence,
                           segment.isFinal,
                           ROW_NUMBER() OVER (
                               PARTITION BY link.evidenceID
                               ORDER BY link.ordinal ASC
                           ) AS rowRank
                    FROM summaryActionItemEvidenceSegment link
                    JOIN segment
                      ON segment.id = link.segmentID
                     AND segment.deletedAt IS NULL
                    WHERE link.evidenceID IN (\(placeholders))
                )
                SELECT *
                FROM rankedEvidence
                WHERE rowRank <= ?
                ORDER BY evidenceID ASC, rowRank ASC
                """,
            arguments: arguments)
    }
}

private let commitmentReviewQueueRootSQL = """
SELECT item.id AS actionItemID,
       item.text AS actionItemText,
       item.ownerSpeakerID,
       meeting.id AS meetingID,
       meeting.title AS meetingTitle,
       meeting.startedAt AS meetingStartedAt,
       meeting.endedAt AS meetingEndedAt,
       meeting.transcriptRevision AS currentTranscriptRevision,
       evidence.id AS evidenceID,
       evidence.sourceTranscriptRevision,
       review.disposition AS reviewDisposition,
       review.revisitAt,
       CASE WHEN person.id IS NOT NULL THEN owner.personID END
           AS suggestedPersonID,
       CASE WHEN person.id IS NOT NULL
            THEN COALESCE(NULLIF(TRIM(owner.displayName), ''), owner.label)
       END AS suggestedOwnerName,
       COUNT(link.id) AS evidenceCount,
       SUM(CASE WHEN segment.id IS NOT NULL THEN 1 ELSE 0 END)
           AS availableEvidenceCount,
       COUNT(*) OVER () AS totalCount
FROM actionItem item
JOIN summary artifact
  ON artifact.id = item.summaryID
 AND artifact.deletedAt IS NULL
JOIN meeting
  ON meeting.id = item.meetingID
 AND meeting.deletedAt IS NULL
 AND meeting.endedAt IS NOT NULL
JOIN summaryActionItemEvidence evidence
  ON evidence.actionItemID = item.id
LEFT JOIN summaryActionItemEvidenceSegment link
  ON link.evidenceID = evidence.id
LEFT JOIN segment
  ON segment.id = link.segmentID
 AND segment.meetingID = meeting.id
 AND segment.deletedAt IS NULL
LEFT JOIN speaker owner
  ON owner.id = item.ownerSpeakerID
 AND owner.meetingID = meeting.id
 AND owner.deletedAt IS NULL
LEFT JOIN person
  ON person.id = owner.personID
 AND person.deletedAt IS NULL
LEFT JOIN commitmentReviewDecision review
  ON review.actionItemID = item.id
 AND review.deletedAt IS NULL
LEFT JOIN commitmentSource confirmedSource
  ON confirmedSource.actionItemID = item.id
WHERE item.deletedAt IS NULL
  AND item.isDone = 0
  AND confirmedSource.id IS NULL
  AND artifact.rowid = (
      SELECT newest.rowid
      FROM summary newest
      WHERE newest.meetingID = meeting.id
        AND newest.deletedAt IS NULL
      ORDER BY newest.createdAt DESC, newest.rowid DESC
      LIMIT 1
  )
  AND (
      review.actionItemID IS NULL
      OR (
          review.disposition = 'deferred'
          AND review.revisitAt <= ?
      )
  )
  __SCOPE_PREDICATE__
GROUP BY item.id, artifact.id, meeting.id, evidence.id,
         review.actionItemID, owner.id, person.id
HAVING COUNT(link.id) > 0
ORDER BY
    CASE WHEN review.disposition = 'deferred' THEN 0 ELSE 1 END,
    CASE WHEN review.disposition = 'deferred' THEN review.revisitAt END ASC,
    meeting.endedAt DESC,
    item.createdAt ASC,
    item.id ASC
LIMIT ?
"""

private struct CommitmentReviewQueueRootRow: Decodable, FetchableRecord {
    let actionItemID: String
    let actionItemText: String
    let ownerSpeakerID: String?
    let meetingID: String
    let meetingTitle: String
    let meetingStartedAt: Date
    let meetingEndedAt: Date
    let currentTranscriptRevision: Int
    let evidenceID: String
    let sourceTranscriptRevision: Int
    let reviewDisposition: String?
    let revisitAt: Date?
    let suggestedPersonID: String?
    let suggestedOwnerName: String?
    let evidenceCount: Int
    let availableEvidenceCount: Int
    let totalCount: Int

    func item(
        evidenceRows: [CommitmentReviewQueueEvidenceRow],
        evidenceLimit: Int,
        reviewAt: Date
    ) throws -> CommitmentReviewQueueItem {
        let meetingID = try parsedMeetingID
        return CommitmentReviewQueueItem(
            meetingID: meetingID,
            meetingTitle: meetingTitle,
            meetingStartedAt: meetingStartedAt,
            meetingEndedAt: meetingEndedAt,
            actionItem: try parsedActionItem,
            evidence: try evidenceResolution(
                rows: evidenceRows,
                limit: evidenceLimit,
                meetingID: meetingID),
            evidenceCount: evidenceCount,
            suggestedOwner: try ownerSuggestion,
            reason: try reviewReason(at: reviewAt))
    }

    var parsedMeetingID: MeetingID {
        get throws {
            MeetingID(rawValue: try PersistedIdentity.required(
                meetingID,
                table: ActionItemRecord.databaseTableName,
                column: "meetingID"))
        }
    }

    var parsedActionItem: ActionItem {
        get throws {
            ActionItem(
                id: try PersistedIdentity.required(
                    actionItemID,
                    table: ActionItemRecord.databaseTableName,
                    column: "id"),
                text: actionItemText,
                ownerSpeakerID: try PersistedIdentity.optional(
                    ownerSpeakerID,
                    table: ActionItemRecord.databaseTableName,
                    column: "ownerSpeakerID"
                ).map { SpeakerID(rawValue: $0) },
                isDone: false)
        }
    }

    var evidenceStatus: TranscriptEvidenceStatus {
        if sourceTranscriptRevision != currentTranscriptRevision {
            .stale
        } else if evidenceCount == 0 || availableEvidenceCount != evidenceCount {
            .unavailable
        } else {
            .current
        }
    }

    func evidenceResolution(
        rows: [CommitmentReviewQueueEvidenceRow],
        limit: Int,
        meetingID: MeetingID
    ) throws -> TranscriptEvidenceResolution {
        let status = evidenceStatus
        guard status == .current else {
            return TranscriptEvidenceResolution(status: status)
        }
        guard rows.count == min(evidenceCount, limit) else {
            throw StorageError.invalidCommitment(
                "review queue current evidence does not match its bounded rows")
        }
        let segments = try rows.map { row in
            let segment = try row.segment
            guard segment.meetingID == meetingID else {
                throw StorageError.invalidCommitment(
                    "review queue evidence belongs to another meeting")
            }
            return segment
        }
        return TranscriptEvidenceResolution(status: status, segments: segments)
    }

    var ownerSuggestion: CommitmentReviewQueueOwner? {
        get throws {
            switch (suggestedPersonID, suggestedOwnerName) {
            case (nil, nil):
                nil
            case (.some(let personID), .some(let name)):
                CommitmentReviewQueueOwner(
                    personID: PersonID(rawValue: try PersistedIdentity.required(
                        personID,
                        table: SpeakerRecord.databaseTableName,
                        column: "personID")),
                    displayName: name)
            default:
                throw StorageError.invalidCommitment(
                    "review queue owner suggestion is incomplete")
            }
        }
    }

    func reviewReason(at reviewAt: Date) throws -> CommitmentReviewQueueReason {
        guard let reviewDisposition else {
            guard revisitAt == nil else {
                throw StorageError.invalidCommitment(
                    "review queue contains an orphan revisit date")
            }
            return .newAfterMeeting
        }
        guard reviewDisposition == CommitmentReviewDisposition.deferred.rawValue,
              let revisitAt,
              revisitAt <= reviewAt
        else {
            throw StorageError.invalidCommitment(
                "review queue contains an ineligible review decision")
        }
        return .deferredDue(revisitAt: revisitAt)
    }
}

private struct CommitmentReviewQueueEvidenceRow: Decodable, FetchableRecord {
    let evidenceID: String
    let ordinal: Int
    let segmentID: String
    let meetingID: String
    let speakerID: String?
    let channel: String
    let text: String
    let language: String?
    let startTime: Double
    let endTime: Double
    let confidence: Double?
    let isFinal: Bool
    let rowRank: Int

    var segment: TranscriptSegment {
        get throws {
            guard let channel = AudioChannel(rawValue: self.channel) else {
                throw StorageError.invalidPersistedValue(
                    table: SegmentRecord.databaseTableName,
                    column: "channel",
                    value: self.channel)
            }
            return TranscriptSegment(
                id: try PersistedIdentity.required(
                    segmentID,
                    table: SegmentRecord.databaseTableName,
                    column: "id"),
                meetingID: MeetingID(rawValue: try PersistedIdentity.required(
                    meetingID,
                    table: SegmentRecord.databaseTableName,
                    column: "meetingID")),
                speakerID: try PersistedIdentity.optional(
                    speakerID,
                    table: SegmentRecord.databaseTableName,
                    column: "speakerID"
                ).map { SpeakerID(rawValue: $0) },
                channel: channel,
                text: text,
                language: language,
                startTime: startTime,
                endTime: endTime,
                confidence: confidence,
                isFinal: isFinal)
        }
    }
}
