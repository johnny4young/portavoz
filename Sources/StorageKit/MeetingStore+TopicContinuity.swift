import Foundation
import GRDB
import PortavozCore

extension MeetingStore {
    /// Exact normalized-alias candidates. Merged aliases resolve to their live
    /// UUID root; ambiguous aliases deliberately return several topics.
    public func topics(matchingAlias alias: String) async throws -> [Topic] {
        guard let normalized = TopicAliasNormalizer.normalize(alias) else { return [] }
        return try await database.read { database in
            let aliases = try TopicAliasRecord
                .filter(Column("normalizedAlias") == normalized)
                .filter(Column("deletedAt") == nil)
                .fetchAll(database)
            let topics = try Self.liveTopicRecords(in: database)
            var roots: [String: Topic] = [:]
            for alias in aliases where topics[alias.topicID] != nil {
                let root = try Self.topicRoot(alias.topicID, among: topics)
                roots[root.id] = try root.topic
            }
            return roots.values.sorted {
                let order = $0.preferredLabel.localizedCaseInsensitiveCompare(
                    $1.preferredLabel)
                if order != .orderedSame { return order == .orderedAscending }
                return $0.id.rawValue.uuidString < $1.id.rawValue.uuidString
            }
        }
    }

    /// Atomically creates one observed topic and confirms its exact evidence.
    /// Generated similarity can remain a rejected, explainable suggestion but
    /// never selects a target by itself.
    public func createTopicAndLink(
        _ proposal: TopicLinkProposal
    ) async throws -> ConfirmedTopicLink {
        try await database.write { database in
            try Self.confirmTopicProposal(
                proposal,
                mergeTargetID: nil,
                in: database)
        }
    }

    /// User-confirmed merge of one newly observed topic into one explicitly
    /// selected live root. Evidence and aliases stay on the observed source so
    /// a later split restores them without rewriting history.
    public func linkTopic(
        _ proposal: TopicLinkProposal,
        to topicID: TopicID
    ) async throws -> ConfirmedTopicLink {
        try await database.write { database in
            try Self.confirmTopicProposal(
                proposal,
                mergeTargetID: topicID,
                in: database)
        }
    }

    /// Explicitly redirects one active topic into another and appends immutable
    /// merge history in the same transaction.
    public func mergeTopics(
        sourceTopicID: TopicID,
        into targetTopicID: TopicID,
        eventID: TopicIdentityEventID = TopicIdentityEventID(),
        at proposedDate: Date = Date()
    ) async throws -> ConfirmedTopicIdentityChange {
        try await database.write { database in
            try Self.applyTopicIdentityChange(
                kind: .merge,
                sourceTopicID: sourceTopicID,
                targetTopicID: targetTopicID,
                eventID: eventID,
                proposedDate: proposedDate,
                in: database)
        }
    }

    /// Reverses the source topic's exact current redirect. Descendants remain
    /// attached to the restored source, preserving prior evidence and aliases.
    public func splitTopic(
        sourceTopicID: TopicID,
        from targetTopicID: TopicID,
        eventID: TopicIdentityEventID = TopicIdentityEventID(),
        at proposedDate: Date = Date()
    ) async throws -> ConfirmedTopicIdentityChange {
        try await database.write { database in
            try Self.applyTopicIdentityChange(
                kind: .split,
                sourceTopicID: sourceTopicID,
                targetTopicID: targetTopicID,
                eventID: eventID,
                proposedDate: proposedDate,
                in: database)
        }
    }

    /// Returns exact evidence for the requested topic's current merged family.
    /// Freshness is derived at read time; persisted provenance is never edited.
    public func topicEvidence(
        for topicID: TopicID
    ) async throws -> [TopicMeetingEvidence] {
        try await database.read { database in
            try Self.loadTopicEvidence(for: topicID, in: database)
        }
    }

    public func topicIdentityHistory(
        for topicID: TopicID
    ) async throws -> [TopicIdentityEvent] {
        try await database.read { database in
            try TopicIdentityEventRecord
                .filter(
                    Column("sourceTopicID") == topicID.rawValue.uuidString
                        || Column("targetTopicID") == topicID.rawValue.uuidString)
                .order(Column("occurredAt"), Column("id"))
                .fetchAll(database)
                .map { try $0.event }
        }
    }
}
