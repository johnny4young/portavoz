import Foundation
import GRDB
import PortavozCore

extension MeetingStore {
    /// Creates question authority only from an explicit topic choice, exact
    /// user-reviewed wording, and current accepted transcript evidence.
    public func confirmMeetingQuestion(
        _ confirmation: MeetingQuestionConfirmation
    ) async throws -> MeetingQuestionContinuity {
        try await database.write { database in
            let timestamp = Self.canonicalMeetingQuestionDate(confirmation.confirmedAt)
            if try MeetingQuestionRecord.fetchOne(
                database,
                key: confirmation.questionID.rawValue.uuidString
            ) != nil {
                let existing = try Self.loadMeetingQuestionContinuity(
                    confirmation.questionID,
                    in: database)
                guard existing.question.topicID == confirmation.topicID,
                      existing.question.text == confirmation.text.trimmingCharacters(
                          in: .whitespacesAndNewlines),
                      existing.question.openedAt == timestamp,
                      existing.openingEvidence == confirmation.evidence
                else {
                    throw StorageError.invalidMeetingQuestion(
                        "question identity conflicts with persisted authority")
                }
                return existing
            }
            try Self.validateCurrentRootTopic(confirmation.topicID, in: database)
            try Self.validateMeetingQuestionEvidence(confirmation.evidence, in: database)
            let question = try MeetingQuestionContinuityPolicy.projectedQuestion(
                id: confirmation.questionID,
                topicID: confirmation.topicID,
                text: confirmation.text,
                openingEvidence: confirmation.evidence,
                openedAt: timestamp,
                events: [])
            let continuity = try MeetingQuestionContinuity(
                question: question,
                openingEvidence: confirmation.evidence,
                events: [])
            try MeetingQuestionRecord(
                question: question,
                openingEvidence: confirmation.evidence)
                .insert(database)
            try Self.insertMeetingQuestionEvidence(
                Array(confirmation.evidence.segmentIDs.dropFirst()),
                questionID: confirmation.questionID,
                in: database)
            return continuity
        }
    }

    /// Appends one explicit source-backed transition. Generated question cards
    /// cannot call this boundary without a separate user confirmation command.
    public func applyMeetingQuestionTransition(
        _ confirmation: MeetingQuestionTransitionConfirmation
    ) async throws -> MeetingQuestionContinuity {
        try await database.write { database in
            let current = try Self.loadMeetingQuestionContinuity(
                confirmation.questionID,
                in: database)
            if let existingIndex = current.events.firstIndex(where: {
                $0.id == confirmation.eventID
            }) {
                let existing = current.events[existingIndex]
                let predecessor = existingIndex == current.events.startIndex
                    ? current.question.openedAt
                    : current.events[current.events.index(before: existingIndex)].occurredAt
                let requested = Self.canonicalMeetingQuestionDate(confirmation.confirmedAt)
                let expectedOccurredAt = requested > predecessor
                    ? requested
                    : predecessor.addingTimeInterval(0.001)
                guard existing.questionID == confirmation.questionID,
                      existing.kind == confirmation.transition.eventKind,
                      existing.evidence == confirmation.evidence,
                      Self.meetingQuestionMilliseconds(existing.occurredAt)
                        == Self.meetingQuestionMilliseconds(expectedOccurredAt)
                else {
                    throw StorageError.invalidMeetingQuestion(
                        "question event identity conflicts with persisted history")
                }
                return current
            }
            try Self.validateMeetingQuestionEvidence(confirmation.evidence, in: database)
            let requested = Self.canonicalMeetingQuestionDate(confirmation.confirmedAt)
            let occurredAt = requested > current.question.updatedAt
                ? requested
                : current.question.updatedAt.addingTimeInterval(0.001)
            let event = MeetingQuestionEvent(
                id: confirmation.eventID,
                questionID: confirmation.questionID,
                kind: confirmation.transition.eventKind,
                evidence: confirmation.evidence,
                occurredAt: occurredAt)
            let events = current.events + [event]
            let question: MeetingQuestion
            do {
                question = try MeetingQuestionContinuityPolicy.projectedQuestion(
                    id: current.question.id,
                    topicID: current.question.topicID,
                    text: current.question.text,
                    openingEvidence: current.openingEvidence,
                    openedAt: current.question.openedAt,
                    events: events)
            } catch let error as MeetingQuestionContinuityValidationError {
                throw StorageError.invalidMeetingQuestion(String(describing: error))
            }
            try MeetingQuestionEventRecord(event).insert(database)
            try Self.insertMeetingQuestionEventEvidence(
                Array(event.evidence.segmentIDs.dropFirst()),
                eventID: event.id,
                in: database)
            return try MeetingQuestionContinuity(
                question: question,
                openingEvidence: current.openingEvidence,
                events: events)
        }
    }

    public func meetingQuestionContinuity(
        for questionID: MeetingQuestionID
    ) async throws -> MeetingQuestionContinuity {
        try await database.read { database in
            try Self.loadMeetingQuestionContinuity(questionID, in: database)
        }
    }

    static func loadMeetingQuestionContinuity(
        _ questionID: MeetingQuestionID,
        in database: Database
    ) throws -> MeetingQuestionContinuity {
        let key = questionID.rawValue.uuidString
        guard let record = try MeetingQuestionRecord.fetchOne(database, key: key),
              record.deletedAt == nil
        else {
            throw StorageError.invalidMeetingQuestion("question identity is unavailable")
        }
        let openingSegments = try MeetingQuestionEvidenceSegmentRecord
            .filter(Column("questionID") == key)
            .order(Column("ordinal"))
            .fetchAll(database)
            .map { try $0.persistedSegmentID }
        let eventRecords = try MeetingQuestionEventRecord
            .filter(Column("questionID") == key)
            .order(Column("occurredAt"), Column("id"))
            .fetchAll(database)
        let events = try eventRecords.map { eventRecord in
            let segmentIDs = try QuestionEventEvidenceSegmentRecord
                .filter(Column("eventID") == eventRecord.id)
                .order(Column("ordinal"))
                .fetchAll(database)
                .map { try $0.persistedSegmentID }
            return try eventRecord.event(additionalSegmentIDs: segmentIDs)
        }
        do {
            return try MeetingQuestionContinuity(
                question: record.question(),
                openingEvidence: record.openingEvidence(
                    additionalSegmentIDs: openingSegments),
                events: events)
        } catch let error as MeetingQuestionContinuityValidationError {
            throw StorageError.invalidMeetingQuestion(String(describing: error))
        }
    }
}

private extension MeetingStore {
    static func validateCurrentRootTopic(
        _ topicID: TopicID,
        in database: Database
    ) throws {
        guard let topic = try TopicRecord.fetchOne(
            database,
            key: topicID.rawValue.uuidString),
              topic.deletedAt == nil,
              topic.mergedIntoTopicID == nil
        else {
            throw StorageError.invalidMeetingQuestion(
                "question topic must be an exact current root")
        }
    }

    static func validateMeetingQuestionEvidence(
        _ evidence: MeetingQuestionEvidence,
        in database: Database
    ) throws {
        guard evidence.sourceTranscriptRevision >= 0,
              !evidence.segmentIDs.isEmpty,
              Set(evidence.segmentIDs).count == evidence.segmentIDs.count,
              let meeting = try MeetingRecord.fetchOne(
                  database,
                  key: evidence.meetingID.rawValue.uuidString),
              meeting.deletedAt == nil,
              meeting.transcriptRevision == evidence.sourceTranscriptRevision
        else {
            throw StorageError.invalidMeetingQuestion(
                "question evidence is stale or unavailable")
        }
        let keys = evidence.segmentIDs.map(\.uuidString)
        let placeholders = Array(repeating: "?", count: keys.count).joined(separator: ",")
        let count = try Int.fetchOne(
            database,
            sql: """
                SELECT COUNT(*)
                FROM segment
                WHERE id IN (\(placeholders))
                  AND meetingID = ?
                  AND deletedAt IS NULL
                  AND isFinal = 1
                  AND \(acceptedSegmentHasNoActiveCorrectionSQL)
                """,
            arguments: StatementArguments(
                keys + [evidence.meetingID.rawValue.uuidString])) ?? 0
        guard count == keys.count else {
            throw StorageError.invalidMeetingQuestion(
                "question evidence is stale or unavailable")
        }
    }

    static func insertMeetingQuestionEvidence(
        _ segmentIDs: [UUID],
        questionID: MeetingQuestionID,
        in database: Database
    ) throws {
        for (index, segmentID) in segmentIDs.enumerated() {
            try MeetingQuestionEvidenceSegmentRecord(
                questionID: questionID,
                segmentID: segmentID,
                ordinal: index + 1)
                .insert(database)
        }
    }

    static func insertMeetingQuestionEventEvidence(
        _ segmentIDs: [UUID],
        eventID: MeetingQuestionEventID,
        in database: Database
    ) throws {
        for (index, segmentID) in segmentIDs.enumerated() {
            try QuestionEventEvidenceSegmentRecord(
                eventID: eventID,
                segmentID: segmentID,
                ordinal: index + 1)
                .insert(database)
        }
    }

    static func canonicalMeetingQuestionDate(_ date: Date) -> Date {
        Date(
            timeIntervalSince1970: Double(meetingQuestionMilliseconds(date)) / 1_000)
    }

    static func meetingQuestionMilliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded())
    }
}
