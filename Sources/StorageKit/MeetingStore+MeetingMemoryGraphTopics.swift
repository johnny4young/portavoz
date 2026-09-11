import GRDB

extension MeetingStore {
    static func rebuildMeetingMemoryGraphTopic(
        _ topicID: String,
        in database: Database
    ) throws -> Int {
        // Family resolution stays inside SQL (recursive CTE): loading every
        // live topic per scope was the superlinear rebuild driver GRAPH-6
        // measured (414 -> 48.9 edges/s between 1k and 10k meetings).
        guard let rootID = try topicFamilyRootID(topicID, in: database) else {
            try clearUnavailableMeetingMemoryGraphTopic(topicID, in: database)
            return 0
        }
        let familyIDs = try topicFamilyMemberIDs(rootID: rootID, in: database)
        try clearMeetingMemoryGraphTopicEvidenceEdges(
            familyIDs,
            in: database)
        let meetingEdges = try publishMeetingMemoryGraphTopicMeetings(
            rootID: rootID,
            familyIDs: familyIDs,
            in: database)
        let questionEdges = try publishMeetingMemoryGraphTopicQuestions(
            rootID: rootID,
            familyIDs: familyIDs,
            in: database)
        let decisionEdges = try rebuildMeetingMemoryGraphTopicDecisions(
            rootID: rootID,
            familyIDs: familyIDs,
            in: database)
        return meetingEdges + questionEdges + decisionEdges
    }

    /// Topic evidence remains attached to reversible observed identities. The
    /// disposable edge always targets the current live family root so a merge
    /// or split changes traversal without rewriting authoritative history.
    static func rebuildMeetingMemoryGraphTopics(
        forMeetingID meetingID: String,
        in database: Database
    ) throws -> Int {
        let observedTopicIDs = try String.fetchAll(
            database,
            sql: """
                SELECT DISTINCT evidence.topicID
                FROM topicMeetingEvidence AS evidence
                JOIN meeting ON meeting.id = evidence.meetingID
                WHERE evidence.meetingID = ?
                  AND meeting.deletedAt IS NULL
                """,
            arguments: [meetingID])
        let rootIDs = try Set(observedTopicIDs.compactMap { topicID in
            try topicFamilyRootID(topicID, in: database)
        })
        var published = 0
        for rootID in rootIDs.sorted() {
            try database.execute(
                sql: """
                    INSERT OR IGNORE INTO meetingMemoryGraphMeetingTopic (
                        meetingID, topicID
                    ) VALUES (?, ?)
                    """,
                arguments: [meetingID, rootID])
            published += database.changesCount
        }
        return published
    }

    /// Derived from the decision-topic authority alone (D270/D271): only an
    /// explicitly confirmed, live link produces an edge, and the edge targets
    /// the topic family's current root so a merge changes traversal without
    /// rewriting authoritative history. No meeting co-occurrence appears here.
    static func rebuildMeetingMemoryGraphDecisionTopics(
        decisionID: String,
        in database: Database
    ) throws -> Int {
        let linkedTopicIDs = try String.fetchAll(
            database,
            sql: """
                SELECT DISTINCT link.topicID
                FROM decisionTopicLink AS link
                JOIN decisionContinuity AS decision ON decision.id = link.decisionID
                WHERE link.decisionID = ?
                  AND link.status = 'confirmed'
                  AND link.deletedAt IS NULL
                  AND decision.deletedAt IS NULL
                """,
            arguments: [decisionID])
        let rootIDs = try Set(linkedTopicIDs.compactMap { topicID in
            try topicFamilyRootID(topicID, in: database)
        })
        var published = 0
        for rootID in rootIDs.sorted() {
            try database.execute(
                sql: """
                    INSERT OR IGNORE INTO meetingMemoryGraphDecisionTopic (
                        decisionID, topicID
                    ) VALUES (?, ?)
                    """,
                arguments: [decisionID, rootID])
            published += database.changesCount
        }
        return published
    }

    private static func clearUnavailableMeetingMemoryGraphTopic(
        _ topicID: String,
        in database: Database
    ) throws {
        try database.execute(
            sql: "DELETE FROM meetingMemoryGraphMeetingTopic WHERE topicID = ?",
            arguments: [topicID])
        try database.execute(
            sql: "DELETE FROM meetingMemoryGraphTopicQuestion WHERE topicID = ?",
            arguments: [topicID])
        try database.execute(
            sql: "DELETE FROM meetingMemoryGraphDecisionTopic WHERE topicID = ?",
            arguments: [topicID])
    }

    private static func clearMeetingMemoryGraphTopicEvidenceEdges(
        _ familyIDs: [String],
        in database: Database
    ) throws {
        try database.execute(
            sql: """
                DELETE FROM meetingMemoryGraphMeetingTopic
                WHERE topicID IN (\(placeholders(familyIDs.count)))
                """,
            arguments: StatementArguments(familyIDs))
        try database.execute(
            sql: """
                DELETE FROM meetingMemoryGraphTopicQuestion
                WHERE topicID IN (\(placeholders(familyIDs.count)))
                """,
            arguments: StatementArguments(familyIDs))
    }

    private static func publishMeetingMemoryGraphTopicMeetings(
        rootID: String,
        familyIDs: [String],
        in database: Database
    ) throws -> Int {
        try database.execute(
            sql: """
                INSERT INTO meetingMemoryGraphMeetingTopic (meetingID, topicID)
                SELECT DISTINCT evidence.meetingID, ?
                FROM topicMeetingEvidence AS evidence
                JOIN meeting ON meeting.id = evidence.meetingID
                WHERE evidence.topicID IN (\(placeholders(familyIDs.count)))
                  AND meeting.deletedAt IS NULL
                """,
            arguments: StatementArguments([rootID] + familyIDs))
        return database.changesCount
    }

    private static func publishMeetingMemoryGraphTopicQuestions(
        rootID: String,
        familyIDs: [String],
        in database: Database
    ) throws -> Int {
        try database.execute(
            sql: """
                INSERT INTO meetingMemoryGraphTopicQuestion (topicID, questionID)
                SELECT ?, question.id
                FROM meetingQuestion AS question
                WHERE question.topicID IN (\(placeholders(familyIDs.count)))
                  AND question.deletedAt IS NULL
                """,
            arguments: StatementArguments([rootID] + familyIDs))
        return database.changesCount
    }

    private static func rebuildMeetingMemoryGraphTopicDecisions(
        rootID: String,
        familyIDs: [String],
        in database: Database
    ) throws -> Int {
        try database.execute(
            sql: """
                DELETE FROM meetingMemoryGraphDecisionTopic
                WHERE topicID IN (\(placeholders(familyIDs.count)))
                """,
            arguments: StatementArguments(familyIDs))
        try database.execute(
            sql: """
                INSERT OR IGNORE INTO meetingMemoryGraphDecisionTopic (
                    decisionID, topicID
                )
                SELECT DISTINCT link.decisionID, ?
                FROM decisionTopicLink AS link
                JOIN decisionContinuity AS decision ON decision.id = link.decisionID
                WHERE link.topicID IN (\(placeholders(familyIDs.count)))
                  AND link.status = 'confirmed'
                  AND link.deletedAt IS NULL
                  AND decision.deletedAt IS NULL
                """,
            arguments: StatementArguments([rootID] + familyIDs))
        return database.changesCount
    }
}
