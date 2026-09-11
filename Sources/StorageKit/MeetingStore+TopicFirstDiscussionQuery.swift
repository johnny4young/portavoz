import Foundation
import GRDB
import PortavozCore

extension MeetingStore {
    /// Returns the earliest explicitly confirmed discussion for one exact
    /// topic family. The graph must agree with the authoritative earliest
    /// evidence but never decides which mention is first.
    public func topicFirstDiscussion(
        _ query: TopicFirstDiscussionQuery
    ) async throws -> MeetingMemoryGraphQueryResult {
        try await database.read { database in
            try Self.loadTopicFirstDiscussion(query, in: database)
        }
    }

    static func loadTopicFirstDiscussion(
        _ query: TopicFirstDiscussionQuery,
        in database: Database
    ) throws -> MeetingMemoryGraphQueryResult {
        guard query.isValid else { return .abstained(.invalidQuery) }
        guard try meetingMemoryGraphProjectionIsReady(in: database) else {
            return .abstained(.projectionNotReady)
        }
        if let status = query.filter.status, status != .confirmed {
            return .abstained(.noMatchingFacts)
        }
        let topics = try liveTopicRecords(in: database)
        let queryKey = query.topicID.rawValue.uuidString
        guard topics[queryKey] != nil else {
            return .abstained(.topicUnavailable)
        }
        let root = try topicRoot(queryKey, among: topics)
        let occurrences = try loadTopicEvidenceOccurrences(
            for: query.topicID,
            in: database)
        let earliest: TopicEvidenceOccurrence
        switch firstDiscussionOccurrence(
            in: occurrences,
            matching: query.filter
        ) {
        case .occurrence(let occurrence):
            earliest = occurrence
        case .abstained(let reason):
            return .abstained(reason)
        }

        return try topicFirstDiscussionFact(
            earliest,
            root: root,
            in: database)
    }

    private static func firstDiscussionOccurrence(
        in occurrences: [TopicEvidenceOccurrence],
        matching filter: MeetingMemoryGraphFactFilter
    ) -> TopicFirstDiscussionOccurrenceSelection {
        if filter.isUnrestricted {
            return occurrences.first.map {
                .occurrence($0)
            } ?? .abstained(.evidenceUnavailable)
        }
        for occurrence in occurrences {
            guard let occurredAt = occurrence.occurredAt else {
                return .abstained(.evidenceUnavailable)
            }
            if filter.includes(occurredAt: occurredAt, status: .confirmed) {
                return .occurrence(occurrence)
            }
        }
        return .abstained(.noMatchingFacts)
    }

    private static func topicFirstDiscussionFact(
        _ earliest: TopicEvidenceOccurrence,
        root: TopicRecord,
        in database: Database
    ) throws -> MeetingMemoryGraphQueryResult {
        let earliestEvidence = earliest.evidence

        switch earliestEvidence.availability {
        case .stale:
            return .abstained(.staleEvidenceOnly)
        case .unavailable:
            return .abstained(.evidenceUnavailable)
        case .current:
            break
        }
        guard try graphContainsTopicMeetingEdge(
            topicID: root.id,
            meetingID: earliestEvidence.meetingID,
            in: database)
        else { return .abstained(.projectionInconsistent) }

        let evidenceStatus = try timelineEvidence(
            meetingID: earliestEvidence.meetingID,
            transcriptRevision: earliestEvidence.sourceTranscriptRevision,
            segmentIDs: [earliestEvidence.segmentID],
            in: database)
        guard case .current(let evidence) = evidenceStatus,
              let source = evidence.first
        else {
            return firstDiscussionAbstention(for: evidenceStatus)
        }
        let topic = try root.topic
        let generation = try meetingMemoryGraphProjectionGeneration(in: database)
        return .facts(MeetingMemoryGraphFactPage(
            facts: [MeetingMemoryGraphFact(
                id: .topicEvidence(earliestEvidence.id),
                kind: .topicDiscussedInMeeting,
                subject: .topic(topic.id),
                object: .meeting(earliestEvidence.meetingID),
                subjectText: topic.preferredLabel,
                objectText: source.meetingTitle,
                status: .confirmed,
                occurredAt: earliest.occurredAt
                    ?? source.meetingStartedAt.addingTimeInterval(source.startTime),
                evidence: evidence,
                primaryEvidenceSegmentID: earliestEvidence.segmentID)],
            hasMore: false,
            projectionGeneration: generation,
            omittedStaleCount: 0,
            omittedUnavailableCount: 0))
    }

    private static func graphContainsTopicMeetingEdge(
        topicID: String,
        meetingID: MeetingID,
        in database: Database
    ) throws -> Bool {
        try Bool.fetchOne(
            database,
            sql: """
                SELECT EXISTS (
                    SELECT 1
                    FROM meetingMemoryGraphMeetingTopic
                    WHERE topicID = ? AND meetingID = ?
                )
                """,
            arguments: [topicID, meetingID.rawValue.uuidString]) ?? false
    }

    static func meetingMemoryGraphProjectionGeneration(
        in database: Database
    ) throws -> Int {
        try Int.fetchOne(
            database,
            sql: """
                SELECT sourceGeneration
                FROM meetingMemoryGraphProjectionState
                WHERE id = 'current'
                """) ?? 0
    }

    private static func firstDiscussionAbstention(
        for status: TimelineEvidenceStatus
    ) -> MeetingMemoryGraphQueryResult {
        switch status {
        case .current:
            return .abstained(.projectionInconsistent)
        case .stale:
            return .abstained(.staleEvidenceOnly)
        case .unavailable:
            return .abstained(.evidenceUnavailable)
        }
    }
}

private enum TopicFirstDiscussionOccurrenceSelection {
    case occurrence(TopicEvidenceOccurrence)
    case abstained(MeetingMemoryGraphQueryAbstention)
}
