import Foundation
import GRDB
import PortavozCore

extension MeetingStore {
    struct QuestionTimelineCandidate {
        let id: UUID
        let kind: MeetingMemoryTimelineItemKind
        let change: MeetingMemoryTimelineQuestionChange
        let questionID: MeetingQuestionID
        let text: String
        let evidenceSource: MeetingQuestionEvidence
        let occurredAt: Date
    }

    static func appendQuestionTimelineItems(
        topicIDs: [String],
        through: MeetingMemoryTimelineMeeting,
        candidateLimit: Int,
        accumulator: inout TimelineAccumulator,
        in database: Database
    ) throws {
        guard !topicIDs.isEmpty else { return }
        let throughKey = through.id.rawValue.uuidString
        var arguments = StatementArguments(topicIDs)
        arguments += StatementArguments([throughKey])
        arguments += StatementArguments([candidateLimit + 1])
        let keys = try String.fetchAll(
            database,
            sql: """
                SELECT topicEdge.questionID
                FROM meetingMemoryGraphTopicQuestion AS topicEdge
                JOIN meetingMemoryGraphMeetingQuestion AS meetingEdge
                  ON meetingEdge.questionID = topicEdge.questionID
                WHERE topicEdge.topicID IN (\(timelinePlaceholders(topicIDs.count)))
                  AND meetingEdge.meetingID = ?
                ORDER BY topicEdge.questionID
                LIMIT ?
                """,
            arguments: arguments)
        if keys.count > candidateLimit {
            accumulator.candidateOverflow = true
        }
        for key in keys.prefix(candidateLimit) {
            let questionID = MeetingQuestionID(
                rawValue: try requiredTimelineUUID(key))
            let continuity = try loadMeetingQuestionContinuity(
                questionID,
                in: database)
            if continuity.openingEvidence.meetingID == through.id {
                try appendQuestionTimelineItem(
                    QuestionTimelineCandidate(
                        id: continuity.question.id.rawValue,
                        kind: .unresolvedQuestion,
                        change: .opened,
                        questionID: continuity.question.id,
                        text: continuity.question.text,
                        evidenceSource: continuity.openingEvidence,
                        occurredAt: continuity.question.openedAt),
                    accumulator: &accumulator,
                    in: database)
            }
            for event in continuity.events where event.evidence.meetingID == through.id {
                try appendQuestionTimelineItem(
                    QuestionTimelineCandidate(
                        id: event.id.rawValue,
                        kind: timelineKind(for: event.kind),
                        change: timelineChange(for: event.kind),
                        questionID: continuity.question.id,
                        text: continuity.question.text,
                        evidenceSource: event.evidence,
                        occurredAt: event.occurredAt),
                    accumulator: &accumulator,
                    in: database)
            }
        }
    }

    static func appendQuestionTimelineItem(
        _ candidate: QuestionTimelineCandidate,
        accumulator: inout TimelineAccumulator,
        in database: Database
    ) throws {
        switch try timelineEvidence(for: candidate.evidenceSource, in: database) {
        case .current(let evidence):
            accumulator.items.append(MeetingMemoryTimelineItem(
                id: candidate.id,
                kind: candidate.kind,
                entity: .question(candidate.questionID),
                text: candidate.text,
                questionChange: candidate.change,
                origin: .confirmed,
                occurredAt: candidate.occurredAt,
                evidence: evidence))
        case .stale:
            accumulator.omit(.stale)
        case .unavailable:
            accumulator.omit(.unavailable)
        }
    }

    static func timelineKind(
        for eventKind: MeetingQuestionEventKind
    ) -> MeetingMemoryTimelineItemKind {
        switch eventKind {
        case .resolve: .questionResolved
        case .reopen: .questionReopened
        case .dismiss: .questionDismissed
        }
    }

    static func timelineChange(
        for eventKind: MeetingQuestionEventKind
    ) -> MeetingMemoryTimelineQuestionChange {
        switch eventKind {
        case .resolve: .resolved
        case .reopen: .reopened
        case .dismiss: .dismissed
        }
    }

    static func timelineEvidence(
        for source: DecisionSource,
        in database: Database
    ) throws -> TimelineEvidenceStatus {
        switch source.availability {
        case .stale: return .stale
        case .unavailable: return .unavailable
        case .current:
            return try timelineEvidence(
                meetingID: source.meetingID,
                transcriptRevision: source.sourceTranscriptRevision,
                segmentIDs: source.evidence.map(\.segmentID),
                in: database)
        }
    }

    static func timelineEvidence(
        for source: CommitmentSource,
        in database: Database
    ) throws -> TimelineEvidenceStatus {
        guard let meetingID = source.meetingID,
              let revision = source.transcriptRevision,
              !source.evidence.isEmpty,
              source.evidence.allSatisfy({ $0.segmentID != nil })
        else { return .unavailable }
        return try timelineEvidence(
            meetingID: meetingID,
            transcriptRevision: revision,
            segmentIDs: source.evidence.compactMap(\.segmentID),
            in: database)
    }

    static func timelineEvidence(
        for source: CommitmentEventEvidence,
        in database: Database
    ) throws -> TimelineEvidenceStatus {
        try timelineEvidence(
            meetingID: source.meetingID,
            transcriptRevision: source.sourceTranscriptRevision,
            segmentIDs: source.segmentIDs,
            in: database)
    }

    static func timelineEvidence(
        for source: MeetingQuestionEvidence,
        in database: Database
    ) throws -> TimelineEvidenceStatus {
        try timelineEvidence(
            meetingID: source.meetingID,
            transcriptRevision: source.sourceTranscriptRevision,
            segmentIDs: source.segmentIDs,
            in: database)
    }

    static func timelineEvidence(
        for sources: [DecisionSource],
        meetingID: MeetingID,
        in database: Database
    ) throws -> TimelineEvidenceStatus {
        let statuses = try sources
            .filter { $0.meetingID == meetingID }
            .map { try timelineEvidence(for: $0, in: database) }
        return bestTimelineEvidence(statuses)
    }

    static func timelineEvidence(
        for sources: [CommitmentSource],
        meetingID: MeetingID,
        in database: Database
    ) throws -> TimelineEvidenceStatus {
        let statuses = try sources
            .filter { $0.meetingID == meetingID }
            .map { try timelineEvidence(for: $0, in: database) }
        return bestTimelineEvidence(statuses)
    }

    static func bestTimelineEvidence<S: Sequence>(
        _ statuses: S
    ) -> TimelineEvidenceStatus where S.Element == TimelineEvidenceStatus {
        var sawStale = false
        var sawUnavailable = false
        for status in statuses {
            switch status {
            case .current:
                return status
            case .stale:
                sawStale = true
            case .unavailable:
                sawUnavailable = true
            }
        }
        if sawUnavailable { return .unavailable }
        if sawStale { return .stale }
        return .unavailable
    }

    static func timelineEvidence(
        meetingID: MeetingID,
        transcriptRevision: Int,
        segmentIDs: [UUID],
        in database: Database
    ) throws -> TimelineEvidenceStatus {
        let meetingKey = meetingID.rawValue.uuidString
        guard !segmentIDs.isEmpty,
              Set(segmentIDs).count == segmentIDs.count,
              let meeting = try MeetingRecord.fetchOne(database, key: meetingKey),
              meeting.deletedAt == nil
        else { return .unavailable }
        let segmentKeys = segmentIDs.map(\.uuidString)
        let records = try SegmentRecord.fetchAll(
            database,
            sql: """
                SELECT *
                FROM segment
                WHERE id IN (\(timelinePlaceholders(segmentKeys.count)))
                  AND meetingID = ?
                  AND deletedAt IS NULL
                  AND isFinal = 1
                  AND \(acceptedSegmentHasNoActiveCorrectionSQL)
                """,
            arguments: StatementArguments(segmentKeys + [meetingKey]))
        let recordsByID = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        guard recordsByID.count == segmentKeys.count else { return .unavailable }
        guard meeting.transcriptRevision == transcriptRevision else { return .stale }
        let evidence = try segmentKeys.map { segmentKey -> MeetingMemoryTimelineEvidence in
            guard let record = recordsByID[segmentKey] else {
                throw StorageError.invalidDerivedMaintenanceJob(
                    "memory timeline evidence changed during one SQLite snapshot")
            }
            let segment = try record.segment
            return MeetingMemoryTimelineEvidence(
                meetingID: meetingID,
                meetingTitle: meeting.title,
                meetingStartedAt: meeting.startedAt,
                transcriptRevision: transcriptRevision,
                segmentID: segment.id,
                startTime: segment.startTime,
                endTime: segment.endTime,
                text: segment.text,
                language: segment.language)
        }
        return .current(evidence)
    }

}
