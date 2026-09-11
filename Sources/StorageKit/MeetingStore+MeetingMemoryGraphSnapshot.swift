import Foundation
import GRDB
import PortavozCore

extension MeetingStore {
    public func meetingMemoryGraphProjectionSnapshot() async throws
        -> MeetingMemoryGraphProjectionSnapshot {
        try await database.read { database in
            guard try Self.meetingMemoryGraphProjectionIsReady(in: database) else {
                throw StorageError.invalidDerivedMaintenanceJob(
                    "memory graph projection is not ready")
            }
            return MeetingMemoryGraphProjectionSnapshot(
                meetingPeople: try Self.meetingPersonEdges(in: database),
                meetingTopics: try Self.meetingTopicEdges(in: database),
                meetingDecisions: try Self.meetingDecisionEdges(in: database),
                meetingCommitments: try Self.meetingCommitmentEdges(in: database),
                commitmentPeople: try Self.commitmentPersonEdges(in: database),
                meetingQuestions: try Self.meetingQuestionEdges(in: database),
                topicQuestions: try Self.topicQuestionEdges(in: database),
                meetingBlockers: try Self.meetingBlockerEdges(in: database),
                decisionCommitmentBlockers: try Self.decisionCommitmentBlockerEdges(
                    in: database),
                decisionTopics: try Self.decisionTopicEdges(in: database))
        }
    }

    private static func meetingPersonEdges(
        in database: Database
    ) throws -> [MeetingMemoryGraphProjectionSnapshot.MeetingPersonEdge] {
        try Row.fetchAll(
            database,
            sql: """
                SELECT meetingID, personID FROM meetingMemoryGraphMeetingPerson
                ORDER BY meetingID, personID
                """)
            .map {
                .init(
                    meetingID: MeetingID(rawValue: try requiredUUID($0["meetingID"])),
                    personID: PersonID(rawValue: try requiredUUID($0["personID"])))
            }
    }

    private static func meetingTopicEdges(
        in database: Database
    ) throws -> [MeetingMemoryGraphProjectionSnapshot.MeetingTopicEdge] {
        try Row.fetchAll(
            database,
            sql: """
                SELECT meetingID, topicID FROM meetingMemoryGraphMeetingTopic
                ORDER BY meetingID, topicID
                """)
            .map {
                .init(
                    meetingID: MeetingID(rawValue: try requiredUUID($0["meetingID"])),
                    topicID: TopicID(rawValue: try requiredUUID($0["topicID"])))
            }
    }

    private static func meetingDecisionEdges(
        in database: Database
    ) throws -> [MeetingMemoryGraphProjectionSnapshot.MeetingDecisionEdge] {
        try Row.fetchAll(
            database,
            sql: """
                SELECT meetingID, decisionID FROM meetingMemoryGraphMeetingDecision
                ORDER BY meetingID, decisionID
                """)
            .map {
                .init(
                    meetingID: MeetingID(rawValue: try requiredUUID($0["meetingID"])),
                    decisionID: DecisionID(rawValue: try requiredUUID($0["decisionID"])))
            }
    }

    private static func meetingCommitmentEdges(
        in database: Database
    ) throws -> [MeetingMemoryGraphProjectionSnapshot.MeetingCommitmentEdge] {
        try Row.fetchAll(
            database,
            sql: """
                SELECT meetingID, commitmentID FROM meetingMemoryGraphMeetingCommitment
                ORDER BY meetingID, commitmentID
                """)
            .map {
                .init(
                    meetingID: MeetingID(rawValue: try requiredUUID($0["meetingID"])),
                    commitmentID: CommitmentID(rawValue: try requiredUUID($0["commitmentID"])))
            }
    }

    private static func commitmentPersonEdges(
        in database: Database
    ) throws -> [MeetingMemoryGraphProjectionSnapshot.CommitmentPersonEdge] {
        try Row.fetchAll(
            database,
            sql: """
                SELECT commitmentID, personID FROM meetingMemoryGraphCommitmentPerson
                ORDER BY commitmentID, personID
                """)
            .map {
                .init(
                    commitmentID: CommitmentID(rawValue: try requiredUUID($0["commitmentID"])),
                    personID: PersonID(rawValue: try requiredUUID($0["personID"])))
            }
    }

    private static func meetingQuestionEdges(
        in database: Database
    ) throws -> [MeetingMemoryGraphProjectionSnapshot.MeetingQuestionEdge] {
        try Row.fetchAll(
            database,
            sql: """
                SELECT meetingID, questionID FROM meetingMemoryGraphMeetingQuestion
                ORDER BY meetingID, questionID
                """)
            .map {
                .init(
                    meetingID: MeetingID(rawValue: try requiredUUID($0["meetingID"])),
                    questionID: MeetingQuestionID(
                        rawValue: try requiredUUID($0["questionID"])))
            }
    }

    private static func topicQuestionEdges(
        in database: Database
    ) throws -> [MeetingMemoryGraphProjectionSnapshot.TopicQuestionEdge] {
        try Row.fetchAll(
            database,
            sql: """
                SELECT topicID, questionID FROM meetingMemoryGraphTopicQuestion
                ORDER BY topicID, questionID
                """)
            .map {
                .init(
                    topicID: TopicID(rawValue: try requiredUUID($0["topicID"])),
                    questionID: MeetingQuestionID(
                        rawValue: try requiredUUID($0["questionID"])))
            }
    }

    private static func decisionCommitmentBlockerEdges(
        in database: Database
    ) throws -> [MeetingMemoryGraphProjectionSnapshot.DecisionCommitmentBlockerEdge] {
        try Row.fetchAll(
            database,
            sql: """
                SELECT blockerID, decisionID, commitmentID
                FROM meetingMemoryGraphDecisionCommitmentBlocker
                ORDER BY blockerID
                """)
            .map {
                .init(
                    blockerID: DecisionCommitmentBlockerID(
                        rawValue: try requiredUUID($0["blockerID"])),
                    decisionID: DecisionID(
                        rawValue: try requiredUUID($0["decisionID"])),
                    commitmentID: CommitmentID(
                        rawValue: try requiredUUID($0["commitmentID"])))
            }
    }

    private static func meetingBlockerEdges(
        in database: Database
    ) throws -> [MeetingMemoryGraphProjectionSnapshot.MeetingBlockerEdge] {
        try Row.fetchAll(
            database,
            sql: """
                SELECT meetingID, blockerID
                FROM meetingMemoryGraphMeetingBlocker
                ORDER BY meetingID, blockerID
                """)
            .map {
                .init(
                    meetingID: MeetingID(rawValue: try requiredUUID($0["meetingID"])),
                    blockerID: DecisionCommitmentBlockerID(
                        rawValue: try requiredUUID($0["blockerID"])))
            }
    }

    private static func decisionTopicEdges(
        in database: Database
    ) throws -> [MeetingMemoryGraphProjectionSnapshot.DecisionTopicEdge] {
        try Row.fetchAll(
            database,
            sql: """
                SELECT decisionID, topicID
                FROM meetingMemoryGraphDecisionTopic
                ORDER BY decisionID, topicID
                """)
            .map {
                .init(
                    decisionID: DecisionID(rawValue: try requiredUUID($0["decisionID"])),
                    topicID: TopicID(rawValue: try requiredUUID($0["topicID"])))
            }
    }

    private static func requiredUUID(_ value: String) throws -> UUID {
        guard let uuid = UUID(uuidString: value) else {
            throw StorageError.invalidDerivedMaintenanceJob(
                "memory graph projection contains a malformed identity")
        }
        return uuid
    }
}
