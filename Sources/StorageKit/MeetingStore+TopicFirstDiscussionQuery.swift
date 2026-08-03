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
        guard try meetingMemoryGraphProjectionIsReady(in: database) else {
            return .abstained(.projectionNotReady)
        }
        let topics = try liveTopicRecords(in: database)
        let queryKey = query.topicID.rawValue.uuidString
        guard topics[queryKey] != nil else {
            return .abstained(.topicUnavailable)
        }
        let root = try topicRoot(queryKey, among: topics)
        guard let earliest = try loadTopicEvidence(
            for: query.topicID,
            in: database).first
        else { return .abstained(.evidenceUnavailable) }

        switch earliest.availability {
        case .stale:
            return .abstained(.staleEvidenceOnly)
        case .unavailable:
            return .abstained(.evidenceUnavailable)
        case .current:
            break
        }
        guard try graphContainsTopicMeetingEdge(
            topicID: root.id,
            meetingID: earliest.meetingID,
            in: database)
        else { return .abstained(.projectionInconsistent) }

        let evidenceStatus = try timelineEvidence(
            meetingID: earliest.meetingID,
            transcriptRevision: earliest.sourceTranscriptRevision,
            segmentIDs: [earliest.segmentID],
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
                id: .topicEvidence(earliest.id),
                kind: .topicDiscussedInMeeting,
                subject: .topic(topic.id),
                object: .meeting(earliest.meetingID),
                subjectText: topic.preferredLabel,
                objectText: source.meetingTitle,
                status: .confirmed,
                occurredAt: source.meetingStartedAt.addingTimeInterval(
                    source.startTime),
                evidence: evidence,
                primaryEvidenceSegmentID: earliest.segmentID)],
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

    private static func meetingMemoryGraphProjectionGeneration(
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
