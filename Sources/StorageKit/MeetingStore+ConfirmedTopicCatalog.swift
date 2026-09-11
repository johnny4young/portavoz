import GRDB
import PortavozCore

extension MeetingStore {
    /// Bounded confirmed-topic discovery for explicit selectors. Alias hits on
    /// merged children resolve to their current live root inside SQLite, so the
    /// caller never hydrates or filters the whole topic catalog in memory.
    public func confirmedTopics(
        matching query: String?,
        limit: Int
    ) async throws -> [Topic] {
        guard (1...Self.maximumConfirmedTopicCatalogCount).contains(limit) else {
            throw StorageError.invalidTopicContinuity(
                "confirmed topic catalog limit is invalid")
        }
        if let query,
           query.count > Self.maximumConfirmedTopicCatalogQueryCharacterCount {
            throw StorageError.invalidTopicContinuity(
                "confirmed topic catalog query is too long")
        }
        let normalizedQuery = query.flatMap(TopicAliasNormalizer.normalize)
        return try await database.read { database in
            if let normalizedQuery {
                return try Self.confirmedTopics(
                    matching: normalizedQuery,
                    limit: limit,
                    in: database)
            }
            return try Self.confirmedTopics(limit: limit, in: database)
        }
    }
}

private extension MeetingStore {
    static let maximumConfirmedTopicCatalogCount = 50
    static let maximumConfirmedTopicCatalogQueryCharacterCount = 120

    static func confirmedTopics(
        limit: Int,
        in database: Database
    ) throws -> [Topic] {
        try TopicRecord.fetchAll(
            database,
            sql: """
                SELECT *
                FROM topic
                WHERE deletedAt IS NULL
                  AND mergedIntoTopicID IS NULL
                ORDER BY preferredLabel COLLATE NOCASE, createdAt, id
                LIMIT :limit
                """,
            arguments: ["limit": limit])
            .map { try $0.topic }
    }

    static func confirmedTopics(
        matching normalizedQuery: String,
        limit: Int,
        in database: Database
    ) throws -> [Topic] {
        let pattern = confirmedTopicCatalogPattern(normalizedQuery)
        return try TopicRecord.fetchAll(
            database,
            sql: """
                WITH RECURSIVE
                matchedTopic(id) AS (
                    SELECT DISTINCT alias.topicID
                    FROM topicAlias AS alias
                    JOIN topic AS observed ON observed.id = alias.topicID
                    WHERE alias.deletedAt IS NULL
                      AND observed.deletedAt IS NULL
                      AND alias.normalizedAlias LIKE :pattern ESCAPE '\\'
                ),
                familyRoot(id, mergedIntoTopicID, path) AS (
                    SELECT topic.id,
                           topic.mergedIntoTopicID,
                           ',' || topic.id || ','
                    FROM topic
                    JOIN matchedTopic ON matchedTopic.id = topic.id
                    WHERE topic.deletedAt IS NULL

                    UNION ALL

                    SELECT parent.id,
                           parent.mergedIntoTopicID,
                           familyRoot.path || parent.id || ','
                    FROM familyRoot
                    JOIN topic AS parent
                      ON parent.id = familyRoot.mergedIntoTopicID
                    WHERE parent.deletedAt IS NULL
                      AND instr(familyRoot.path, ',' || parent.id || ',') = 0
                ),
                roots(id) AS (
                    SELECT DISTINCT id
                    FROM familyRoot
                    WHERE mergedIntoTopicID IS NULL
                )
                SELECT topic.*
                FROM roots
                JOIN topic ON topic.id = roots.id
                WHERE topic.deletedAt IS NULL
                  AND topic.mergedIntoTopicID IS NULL
                ORDER BY topic.preferredLabel COLLATE NOCASE,
                         topic.createdAt,
                         topic.id
                LIMIT :limit
                """,
            arguments: ["pattern": pattern, "limit": limit])
            .map { try $0.topic }
    }

    static func confirmedTopicCatalogPattern(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        return "%\(escaped)%"
    }
}
