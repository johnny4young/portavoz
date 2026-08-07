import Foundation
import GRDB
import PortavozCore

extension MeetingStore {
    /// Which of the given generated observations are already confirmed, and
    /// the labels of the topics each decision is actively linked to.
    public func decisionObservationConfirmations(
        for observationIDs: [SummaryDecisionID]
    ) async throws -> [DecisionObservationConfirmationState] {
        guard !observationIDs.isEmpty else { return [] }
        let keys = observationIDs.map(\.rawValue.uuidString)
        return try await database.read { database in
            let sources = try DecisionContinuitySourceRecord
                .filter(keys.contains(Column("summaryDecisionID")))
                .fetchAll(database)
            return try sources.map { source in
                guard let observationRaw = UUID(uuidString: source.summaryDecisionID),
                      let decisionRaw = UUID(uuidString: source.decisionID)
                else {
                    throw StorageError.invalidDecisionContinuity(
                        "decision confirmation identity is malformed")
                }
                let labels = try String.fetchAll(
                    database,
                    sql: """
                        SELECT topic.preferredLabel
                        FROM decisionTopicLink AS link
                        JOIN topic ON topic.id = link.topicID
                        WHERE link.decisionID = ?
                          AND link.status = 'confirmed'
                          AND link.deletedAt IS NULL
                          AND topic.deletedAt IS NULL
                        ORDER BY link.createdAt, topic.preferredLabel
                        """,
                    arguments: [source.decisionID])
                return DecisionObservationConfirmationState(
                    observationID: SummaryDecisionID(rawValue: observationRaw),
                    decisionID: DecisionID(rawValue: decisionRaw),
                    topicLabels: labels)
            }
        }
    }

    /// Live, unmerged topics for the linking suggestion list.
    public func linkableTopics() async throws -> [LinkableTopic] {
        try await database.read { database in
            try TopicRecord
                .filter(Column("deletedAt") == nil)
                .filter(Column("mergedIntoTopicID") == nil)
                .order(Column("preferredLabel"))
                .fetchAll(database)
                .map { record in
                    guard let raw = UUID(uuidString: record.id) else {
                        throw StorageError.invalidTopicContinuity(
                            "topic identity is malformed")
                    }
                    return LinkableTopic(
                        id: TopicID(rawValue: raw),
                        preferredLabel: record.preferredLabel)
                }
        }
    }
}
