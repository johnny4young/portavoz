import CryptoKit
import Foundation
import GRDB
import PortavozCore

extension MeetingStore {
    /// Records the first real presentation of one current generated candidate.
    /// Replays return the original identity and never rewrite its field claims.
    @discardableResult
    public func recordCommitmentFieldPresentation(
        actionItemID: UUID,
        meetingID: MeetingID,
        observationID: UUID = UUID(),
        at proposedDate: Date = Date()
    ) async throws -> UUID {
        guard proposedDate.timeIntervalSinceReferenceDate.isFinite else {
            throw StorageError.invalidCommitment(
                "commitment field presentation requires a finite date")
        }
        let timestamp = Self.canonicalCommitmentDate(proposedDate)
        return try await database.write { database in
            if let existing = try CommitmentFieldPresentationRecord
                .filter(Column("actionItemID") == actionItemID.uuidString)
                .fetchOne(database) {
                return try PersistedIdentity.required(
                    existing.id,
                    table: CommitmentFieldPresentationRecord.databaseTableName,
                    column: "id")
            }

            let material = try Self.commitmentFieldPresentationMaterial(
                actionItemID: actionItemID,
                meetingID: meetingID,
                presentedAt: timestamp,
                in: database)
            guard timestamp >= material.actionItemCreatedAt else {
                throw StorageError.invalidCommitment(
                    "commitment field presentation predates its generated source")
            }
            let record = CommitmentFieldPresentationRecord(
                id: observationID.uuidString,
                actionItemID: actionItemID.uuidString,
                language: material.language.rawValue,
                suggestedOwnerToken: material.suggestedOwnerToken?.uuidString,
                suggestedDueAt: nil,
                firstPresentedAt: timestamp)
            do {
                try record.insert(database)
            } catch {
                if let existing = try CommitmentFieldPresentationRecord
                    .filter(Column("actionItemID") == actionItemID.uuidString)
                    .fetchOne(database) {
                    return try PersistedIdentity.required(
                        existing.id,
                        table: CommitmentFieldPresentationRecord.databaseTableName,
                        column: "id")
                }
                throw error
            }
            return observationID
        }
    }

    /// Reads the current human disposition for presentations inside one
    /// rolling cohort. One bounded SELECT returns no meeting content.
    public func commitmentFieldQualityObservations(
        endingAt proposedWindowEnd: Date
    ) async throws -> [CommitmentFieldQualityObservation] {
        guard proposedWindowEnd.timeIntervalSinceReferenceDate.isFinite else {
            throw CommitmentFieldQualityError.invalidWindowEnd
        }
        let windowEnd = Self.canonicalCommitmentDate(proposedWindowEnd)
        let windowStart = windowEnd.addingTimeInterval(
            -CommitmentFieldQualityEvaluator.windowDuration)
        return try await database.read { database in
            let rows = try CommitmentFieldQualityObservationRow.fetchAll(
                database,
                sql: commitmentFieldQualityObservationSQL,
                arguments: [
                    windowStart,
                    windowEnd,
                    CommitmentFieldQualityEvaluator.maximumObservationCount + 1
                ])
            guard rows.count <= CommitmentFieldQualityEvaluator.maximumObservationCount else {
                throw CommitmentFieldQualityError.tooManyObservations
            }
            return try rows.map { try $0.observation }
        }
    }
}

private extension MeetingStore {
    static func commitmentFieldPresentationMaterial(
        actionItemID: UUID,
        meetingID: MeetingID,
        presentedAt: Date,
        in database: Database
    ) throws -> CommitmentFieldPresentationMaterial {
        guard let row = try CommitmentFieldPresentationMaterialRow.fetchOne(
            database,
            sql: commitmentFieldPresentationMaterialSQL,
            arguments: [
                actionItemID.uuidString,
                meetingID.rawValue.uuidString,
                presentedAt,
                meetingID.rawValue.uuidString
            ])
        else {
            throw StorageError.invalidCommitment(
                "field presentation requires current direct ActionItem evidence")
        }
        return try row.material
    }
}

enum CommitmentFieldOwnerToken {
    private static let domain = "portavoz.commitment-field-owner.v1"

    static func token(for assignee: CommitmentAssignee) -> UUID? {
        switch assignee {
        case .me:
            token(for: "me")
        case .person(let personID):
            token(for: "person:\(personID.rawValue.uuidString.lowercased())")
        case .unassigned:
            nil
        }
    }

    private static func token(for value: String) -> UUID {
        let digest = SHA256.hash(data: Data("\(domain):\(value)".utf8))
        let bytes = Array(digest.prefix(16))
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}

private struct CommitmentFieldPresentationMaterial {
    let actionItemCreatedAt: Date
    let language: CommitmentFieldQualityLanguage
    let suggestedOwnerToken: UUID?
}

private struct CommitmentFieldPresentationMaterialRow: Decodable, FetchableRecord {
    let actionItemCreatedAt: Date
    let ownerPersonID: String?
    let evidenceLanguages: String

    var material: CommitmentFieldPresentationMaterial {
        get throws {
            let owner = try PersistedIdentity.optional(
                ownerPersonID,
                table: SpeakerRecord.databaseTableName,
                column: "personID")
                .map { CommitmentAssignee.person(PersonID(rawValue: $0)) }
                .flatMap(CommitmentFieldOwnerToken.token)
            return CommitmentFieldPresentationMaterial(
                actionItemCreatedAt: actionItemCreatedAt,
                language: Self.languageBucket(evidenceLanguages),
                suggestedOwnerToken: owner)
        }
    }

    private static func languageBucket(
        _ persistedLanguages: String
    ) -> CommitmentFieldQualityLanguage {
        let languages = persistedLanguages
            .split(separator: "|", omittingEmptySubsequences: false)
            .map { raw -> String in
                let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                    .replacingOccurrences(of: "_", with: "-")
                guard !normalized.isEmpty else { return "unknown" }
                return normalized.split(separator: "-").first.map(String.init)
                    ?? "unknown"
            }
        let unique = Set(languages)
        if unique == ["en"] { return .english }
        if unique == ["es"] { return .spanish }
        if unique.count > 1 { return .mixed }
        return .otherOrUnknown
    }
}

private let commitmentFieldPresentationMaterialSQL = """
SELECT item.createdAt AS actionItemCreatedAt,
       CASE WHEN person.id IS NOT NULL THEN person.id END AS ownerPersonID,
       GROUP_CONCAT(COALESCE(segment.language, ''), '|') AS evidenceLanguages
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
WHERE item.id = ?
  AND item.meetingID = ?
  AND item.deletedAt IS NULL
  AND item.isDone = 0
  AND confirmedSource.id IS NULL
  AND (
      review.actionItemID IS NULL
      OR (
          review.disposition = 'deferred'
          AND review.revisitAt <= ?
      )
  )
  AND artifact.rowid = (
      SELECT newest.rowid
      FROM summary newest
      WHERE newest.meetingID = ?
        AND newest.deletedAt IS NULL
      ORDER BY newest.createdAt DESC, newest.rowid DESC
      LIMIT 1
  )
  AND evidence.sourceTranscriptRevision = meeting.transcriptRevision
GROUP BY item.id, artifact.id, meeting.id, evidence.id,
         review.actionItemID, owner.id, person.id
HAVING COUNT(link.id) > 0
   AND COUNT(segment.id) = COUNT(link.id)
"""

private let commitmentFieldQualityObservationSQL = """
SELECT presentation.id,
       presentation.language,
       presentation.firstPresentedAt,
       CASE
           WHEN source.id IS NOT NULL THEN 'confirmed'
           WHEN review.disposition = 'dismissed' THEN 'dismissed'
           WHEN NOT EXISTS (
               SELECT 1
               FROM actionItem activeItem
               JOIN summary activeSummary
                 ON activeSummary.id = activeItem.summaryID
                AND activeSummary.deletedAt IS NULL
               JOIN meeting activeMeeting
                 ON activeMeeting.id = activeItem.meetingID
                AND activeMeeting.deletedAt IS NULL
               WHERE activeItem.id = presentation.actionItemID
                 AND activeItem.deletedAt IS NULL
                 AND activeItem.isDone = 0
                 AND activeSummary.rowid = (
                     SELECT newest.rowid
                     FROM summary newest
                     WHERE newest.meetingID = activeMeeting.id
                       AND newest.deletedAt IS NULL
                     ORDER BY newest.createdAt DESC, newest.rowid DESC
                     LIMIT 1
                 )
           ) THEN 'withdrawn'
           WHEN review.disposition = 'deferred' THEN 'deferred'
           ELSE 'pending'
       END AS outcome,
       CASE
           WHEN source.id IS NOT NULL THEN confirmation.occurredAt
           WHEN review.disposition = 'dismissed' THEN review.updatedAt
       END AS reviewedAt,
       presentation.suggestedOwnerToken,
       confirmation.assigneeKind AS confirmedAssigneeKind,
       confirmation.canonicalPersonID AS confirmedPersonID,
       presentation.suggestedDueAt,
       confirmation.dueAt AS confirmedDueAt
FROM commitmentFieldPresentation presentation
LEFT JOIN commitmentSource source
  ON source.actionItemID = presentation.actionItemID
 AND source.kind = 'generated-action-item'
LEFT JOIN commitmentEvent confirmation
  ON confirmation.commitmentID = source.commitmentID
 AND confirmation.kind = 'confirm'
 AND confirmation.id = (
     SELECT firstConfirmation.id
     FROM commitmentEvent firstConfirmation
     WHERE firstConfirmation.commitmentID = source.commitmentID
       AND firstConfirmation.kind = 'confirm'
     ORDER BY firstConfirmation.occurredAt ASC, firstConfirmation.id ASC
     LIMIT 1
 )
LEFT JOIN commitmentReviewDecision review
  ON review.actionItemID = presentation.actionItemID
 AND review.deletedAt IS NULL
WHERE presentation.firstPresentedAt >= ?
  AND presentation.firstPresentedAt <= ?
ORDER BY presentation.firstPresentedAt ASC, presentation.id ASC
LIMIT ?
"""
