import GRDB

extension MeetingStore {
    static func rebuildMeetingMemoryGraphBlockers(
        meetingID: String,
        in database: Database
    ) throws -> Int {
        try database.execute(
            sql: """
                INSERT INTO meetingMemoryGraphMeetingBlocker (meetingID, blockerID)
                SELECT blocker.sourceMeetingID, blocker.id
                FROM decisionCommitmentBlocker AS blocker
                JOIN meeting ON meeting.id = blocker.sourceMeetingID
                JOIN decisionContinuity AS decision ON decision.id = blocker.decisionID
                JOIN commitment ON commitment.id = blocker.commitmentID
                WHERE blocker.sourceMeetingID = ?
                  AND blocker.deletedAt IS NULL
                  AND meeting.deletedAt IS NULL
                  AND decision.deletedAt IS NULL
                  AND commitment.deletedAt IS NULL
                UNION
                SELECT event.sourceMeetingID, event.blockerID
                FROM decisionCommitmentBlockerEvent AS event
                JOIN decisionCommitmentBlocker AS blocker ON blocker.id = event.blockerID
                JOIN meeting ON meeting.id = event.sourceMeetingID
                JOIN decisionContinuity AS decision ON decision.id = blocker.decisionID
                JOIN commitment ON commitment.id = blocker.commitmentID
                WHERE event.sourceMeetingID = ?
                  AND blocker.deletedAt IS NULL
                  AND meeting.deletedAt IS NULL
                  AND decision.deletedAt IS NULL
                  AND commitment.deletedAt IS NULL
                """,
            arguments: [meetingID, meetingID])
        return database.changesCount
    }
}
