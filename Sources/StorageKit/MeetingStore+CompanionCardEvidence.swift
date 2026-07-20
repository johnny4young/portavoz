import Foundation
import GRDB
import PortavozCore

extension MeetingStore {
    static func validateCompanionEvidenceShape(
        _ evidence: CompanionCardEvidence?,
        cardID: UUID,
        sourceTranscriptRevision: Int?
    ) throws {
        guard let evidence else { return }
        let revisionMatches = sourceTranscriptRevision == nil
            || evidence.sourceTranscriptRevision == nil
            || evidence.sourceTranscriptRevision == sourceTranscriptRevision
        guard evidence.cardID == cardID,
              evidence.unavailableQuestionCount == 0,
              evidence.unavailableAnswerCount == 0,
              !evidence.questionSegmentIDs.isEmpty,
              Set(evidence.questionSegmentIDs).count == evidence.questionSegmentIDs.count,
              Set(evidence.answerSegmentIDs).count == evidence.answerSegmentIDs.count,
              revisionMatches
        else {
            throw StorageError.invalidGenerationRun(
                "Companion evidence must be available, unique, current, and target its card")
        }
    }

    static func replaceCompanionCardEvidence(
        _ evidence: CompanionCardEvidence?,
        cardID: UUID,
        meetingID: MeetingID,
        at timestamp: Date,
        in db: Database
    ) throws {
        let validated = try evidence.map {
            try validatedCompanionCardEvidence(
                $0,
                cardID: cardID,
                meetingID: meetingID,
                in: db)
        }
        try db.execute(
            sql: "DELETE FROM companionCardEvidence WHERE cardID = ?",
            arguments: [cardID.uuidString])
        guard let evidence, let validated else { return }
        let evidenceKey = evidence.id.rawValue.uuidString
        try CompanionCardEvidenceRecord(
            id: evidenceKey,
            cardID: cardID.uuidString,
            sourceTranscriptRevision: validated.revision,
            createdAt: timestamp)
            .insert(db)
        try insertCompanionEvidenceLinks(
            validated.questionIDs,
            evidenceID: evidenceKey,
            role: "question",
            at: timestamp,
            in: db)
        try insertCompanionEvidenceLinks(
            validated.answerIDs,
            evidenceID: evidenceKey,
            role: "answer",
            at: timestamp,
            in: db)
    }

    static func companionCards(meetingID: MeetingID, in db: Database) throws -> [CompanionCard] {
        let records = try CompanionCardRecord
            .filter(Column("meetingID") == meetingID.rawValue.uuidString)
            .filter(Column("deletedAt") == nil)
            .order(Column("askedAt"))
            .fetchAll(db)
        return try records.map { record in
            let card = try record.card
            return try card.withEvidence(companionCardEvidence(cardID: card.id, in: db))
        }
    }

    private static func validatedCompanionCardEvidence(
        _ evidence: CompanionCardEvidence,
        cardID: UUID,
        meetingID: MeetingID,
        in db: Database
    ) throws -> (questionIDs: [UUID], answerIDs: [UUID], revision: Int) {
        try validateCompanionEvidenceShape(
            evidence,
            cardID: cardID,
            sourceTranscriptRevision: nil)
        let meetingKey = meetingID.rawValue.uuidString
        guard let meeting = try MeetingRecord.fetchOne(db, key: meetingKey) else {
            throw StorageError.meetingNotFound(meetingID)
        }
        if let sourceRevision = evidence.sourceTranscriptRevision,
           sourceRevision != meeting.transcriptRevision {
            throw StorageError.invalidGenerationRun("Companion evidence is stale")
        }
        for segmentID in evidence.questionSegmentIDs + evidence.answerSegmentIDs {
            guard let segment = try SegmentRecord.fetchOne(db, key: segmentID.uuidString),
                  segment.meetingID == meetingKey,
                  segment.deletedAt == nil
            else {
                throw StorageError.invalidGenerationRun(
                    "Companion evidence must reference live segments in its meeting")
            }
        }
        return (
            evidence.questionSegmentIDs,
            evidence.answerSegmentIDs,
            meeting.transcriptRevision)
    }

    private static func insertCompanionEvidenceLinks(
        _ segmentIDs: [UUID],
        evidenceID: String,
        role: String,
        at timestamp: Date,
        in db: Database
    ) throws {
        for (ordinal, segmentID) in segmentIDs.enumerated() {
            try CompanionCardEvidenceSegmentRecord(
                id: UUID().uuidString,
                evidenceID: evidenceID,
                role: role,
                segmentID: segmentID.uuidString,
                ordinal: ordinal,
                createdAt: timestamp)
                .insert(db)
        }
    }

    static func companionCardEvidence(
        cardID: UUID,
        in db: Database
    ) throws -> CompanionCardEvidence? {
        guard let record = try CompanionCardEvidenceRecord
            .filter(Column("cardID") == cardID.uuidString)
            .fetchOne(db)
        else { return nil }
        let links = try CompanionCardEvidenceSegmentRecord
            .filter(Column("evidenceID") == record.id)
            .order(Column("role"), Column("ordinal"))
            .fetchAll(db)
        if let invalid = links.first(where: { $0.role != "question" && $0.role != "answer" }) {
            throw StorageError.invalidPersistedValue(
                table: CompanionCardEvidenceSegmentRecord.databaseTableName,
                column: "role",
                value: invalid.role)
        }
        let question = try resolvedCompanionLinks(links, role: "question")
        let answer = try resolvedCompanionLinks(links, role: "answer")
        return CompanionCardEvidence(
            id: CompanionCardEvidenceID(rawValue: try PersistedIdentity.required(
                record.id,
                table: CompanionCardEvidenceRecord.databaseTableName,
                column: "id")),
            cardID: cardID,
            sourceTranscriptRevision: record.sourceTranscriptRevision,
            questionSegmentIDs: question.ids,
            answerSegmentIDs: answer.ids,
            unavailableQuestionCount: question.unavailable,
            unavailableAnswerCount: answer.unavailable)
    }

    private static func resolvedCompanionLinks(
        _ links: [CompanionCardEvidenceSegmentRecord],
        role: String
    ) throws -> (ids: [UUID], unavailable: Int) {
        let matching = links.filter { $0.role == role }
        let ids = try matching.compactMap { link -> UUID? in
            guard let value = link.segmentID else { return nil }
            guard let id = UUID(uuidString: value) else {
                throw StorageError.invalidPersistedUUID(
                    table: CompanionCardEvidenceSegmentRecord.databaseTableName,
                    column: "segmentID",
                    value: value)
            }
            return id
        }
        return (ids, matching.count - ids.count)
    }
}
