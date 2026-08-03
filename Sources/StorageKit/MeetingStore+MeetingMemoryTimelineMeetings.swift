import GRDB

extension MeetingStore {
    static func timelineMeetingRows(
        for resolved: TimelineResolvedSubject,
        in database: Database
    ) throws -> [Row] {
        switch resolved.subject {
        case .topic:
            try topicTimelineMeetingRows(key: resolved.key, in: database)
        case .person:
            try personTimelineMeetingRows(key: resolved.key, in: database)
        }
    }

    private static func topicTimelineMeetingRows(
        key: String,
        in database: Database
    ) throws -> [Row] {
        try Row.fetchAll(
            database,
            sql: """
                WITH related(meetingID) AS (
                    SELECT meetingID
                    FROM meetingMemoryGraphMeetingTopic
                    WHERE topicID = ?
                    UNION
                    SELECT meetingEdge.meetingID
                    FROM meetingMemoryGraphTopicQuestion AS topicEdge
                    JOIN meetingMemoryGraphMeetingQuestion AS meetingEdge
                      ON meetingEdge.questionID = topicEdge.questionID
                    WHERE topicEdge.topicID = ?
                )
                SELECT meeting.id, meeting.title, meeting.startedAt
                FROM related
                JOIN meeting ON meeting.id = related.meetingID
                WHERE meeting.deletedAt IS NULL
                ORDER BY meeting.startedAt, meeting.id
                """,
            arguments: [key, key])
    }

    private static func personTimelineMeetingRows(
        key: String,
        in database: Database
    ) throws -> [Row] {
        try Row.fetchAll(
            database,
            sql: """
                WITH related(meetingID) AS (
                    SELECT meetingID
                    FROM meetingMemoryGraphMeetingPerson
                    WHERE personID = ?
                    UNION
                    SELECT meetingEdge.meetingID
                    FROM meetingMemoryGraphCommitmentPerson AS ownerEdge
                    JOIN meetingMemoryGraphMeetingCommitment AS meetingEdge
                      ON meetingEdge.commitmentID = ownerEdge.commitmentID
                    WHERE ownerEdge.personID = ?
                    UNION
                    SELECT event.sourceMeetingID
                    FROM meetingMemoryGraphCommitmentPerson AS ownerEdge
                    JOIN commitmentEvent AS event
                      ON event.commitmentID = ownerEdge.commitmentID
                    WHERE ownerEdge.personID = ?
                      AND event.sourceMeetingID IS NOT NULL
                    UNION
                    SELECT blockerMeeting.meetingID
                    FROM meetingMemoryGraphCommitmentPerson AS ownerEdge
                    JOIN meetingMemoryGraphDecisionCommitmentBlocker AS blocker
                      ON blocker.commitmentID = ownerEdge.commitmentID
                    JOIN meetingMemoryGraphMeetingBlocker AS blockerMeeting
                      ON blockerMeeting.blockerID = blocker.blockerID
                    WHERE ownerEdge.personID = ?
                )
                SELECT meeting.id, meeting.title, meeting.startedAt
                FROM related
                JOIN meeting ON meeting.id = related.meetingID
                WHERE meeting.deletedAt IS NULL
                ORDER BY meeting.startedAt, meeting.id
                """,
            arguments: [key, key, key, key])
    }
}
