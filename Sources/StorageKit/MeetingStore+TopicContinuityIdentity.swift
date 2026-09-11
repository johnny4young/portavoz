import Foundation
import GRDB
import PortavozCore

extension MeetingStore {
    static func applyTopicIdentityChange(
        kind: TopicIdentityEventKind,
        sourceTopicID: TopicID,
        targetTopicID: TopicID,
        eventID: TopicIdentityEventID,
        proposedDate: Date,
        in database: Database
    ) throws -> ConfirmedTopicIdentityChange {
        guard sourceTopicID != targetTopicID else {
            throw StorageError.invalidTopicContinuity(
                "a topic cannot change identity against itself")
        }
        if let replay = try replayedTopicIdentityChange(
            kind: kind,
            sourceTopicID: sourceTopicID,
            targetTopicID: targetTopicID,
            eventID: eventID,
            in: database) {
            return replay
        }

        guard var source = try liveTopic(sourceTopicID, in: database),
              let target = try liveTopic(targetTopicID, in: database)
        else {
            throw StorageError.invalidTopicContinuity("topic is unavailable")
        }
        try validateTopicIdentityTransition(kind, source: source, target: target)

        let timestamp = try topicIdentityTimestamp(
            proposedDate,
            source: source,
            target: target,
            in: database)
        let event = TopicIdentityEvent(
            id: eventID,
            kind: kind,
            sourceTopicID: sourceTopicID,
            targetTopicID: targetTopicID,
            occurredAt: timestamp)
        try TopicIdentityEventRecord(event).insert(database)
        source.mergedIntoTopicID = kind == .merge ? target.id : nil
        source.updatedAt = timestamp
        try source.update(database)
        guard let persisted = try TopicIdentityEventRecord.fetchOne(
            database,
            key: event.id.rawValue.uuidString)
        else {
            throw StorageError.invalidTopicContinuity(
                "topic identity history was not persisted")
        }
        return ConfirmedTopicIdentityChange(
            source: try source.topic,
            target: try target.topic,
            event: try persisted.event)
    }

    static func replayedTopicIdentityChange(
        kind: TopicIdentityEventKind,
        sourceTopicID: TopicID,
        targetTopicID: TopicID,
        eventID: TopicIdentityEventID,
        in database: Database
    ) throws -> ConfirmedTopicIdentityChange? {
        guard let existing = try TopicIdentityEventRecord.fetchOne(
            database,
            key: eventID.rawValue.uuidString)
        else { return nil }
        guard existing.kind == kind.rawValue,
              existing.sourceTopicID == sourceTopicID.rawValue.uuidString,
              existing.targetTopicID == targetTopicID.rawValue.uuidString,
              let source = try liveTopic(sourceTopicID, in: database),
              let target = try liveTopic(targetTopicID, in: database)
        else {
            throw StorageError.invalidTopicContinuity(
                "identity event was reused with different content")
        }
        return ConfirmedTopicIdentityChange(
            source: try source.topic,
            target: try target.topic,
            event: try existing.event)
    }

    static func validateTopicIdentityTransition(
        _ kind: TopicIdentityEventKind,
        source: TopicRecord,
        target: TopicRecord
    ) throws {
        switch kind {
        case .merge:
            guard source.mergedIntoTopicID == nil,
                  target.mergedIntoTopicID == nil
            else {
                throw StorageError.invalidTopicContinuity(
                    "merge requires two current topic roots")
            }
        case .split:
            guard source.mergedIntoTopicID == target.id else {
                throw StorageError.invalidTopicContinuity(
                    "topic is not merged into the selected target")
            }
        }
    }

    static func liveTopicRecords(
        in database: Database
    ) throws -> [String: TopicRecord] {
        Dictionary(
            uniqueKeysWithValues: try TopicRecord
                .filter(Column("deletedAt") == nil)
                .fetchAll(database)
                .map { ($0.id, $0) })
    }

    /// A merge chain deeper than this is only reachable through corrupt
    /// redirects; the cap turns a persisted cycle into a detectable terminal
    /// state instead of an unbounded recursive walk.
    private static let topicRedirectDepthLimit = 10_000

    /// SQL twin of `topicRoot(_:among:)` for rebuild-scale call sites: walks
    /// one topic's redirect chain with a recursive CTE instead of loading the
    /// whole topic table per scope (the superlinear rebuild driver measured by
    /// GRAPH-6). Failure semantics mirror the in-memory walk for the chain it
    /// touches — a redirect cycle and a redirect to a tombstoned or missing
    /// topic both throw; a missing or tombstoned starting topic returns nil.
    /// Unlike the in-memory walk, broken chains in *other* families are not
    /// visited, so they no longer fail this scope.
    static func topicFamilyRootID(
        _ topicKey: String,
        in database: Database
    ) throws -> String? {
        let row = try Row.fetchOne(
            database,
            sql: """
                WITH RECURSIVE chain(id, mergedIntoTopicID, depth) AS (
                    SELECT topic.id, topic.mergedIntoTopicID, 0
                    FROM topic
                    WHERE topic.id = ? AND topic.deletedAt IS NULL
                    UNION ALL
                    SELECT topic.id, topic.mergedIntoTopicID, chain.depth + 1
                    FROM chain
                    JOIN topic ON topic.id = chain.mergedIntoTopicID
                    WHERE topic.deletedAt IS NULL
                      AND chain.depth < \(topicRedirectDepthLimit)
                )
                SELECT id, mergedIntoTopicID, depth FROM chain
                ORDER BY depth DESC LIMIT 1
                """,
            arguments: [topicKey])
        guard let row else { return nil }
        guard (row["depth"] as Int? ?? 0) < Self.topicRedirectDepthLimit else {
            throw StorageError.invalidTopicContinuity(
                "persisted topic redirects contain a cycle")
        }
        guard (row["mergedIntoTopicID"] as String?) == nil else {
            throw StorageError.invalidTopicContinuity(
                "topic redirect target is unavailable")
        }
        return row["id"]
    }

    /// Every live topic whose redirect chain reaches `rootID` — the family a
    /// merge or split scope must republish. `UNION` (not `UNION ALL`) makes a
    /// corrupt downward cycle terminate instead of recursing forever.
    static func topicFamilyMemberIDs(
        rootID: String,
        in database: Database
    ) throws -> [String] {
        try String.fetchAll(
            database,
            sql: """
                WITH RECURSIVE family(id) AS (
                    SELECT id FROM topic WHERE id = ? AND deletedAt IS NULL
                    UNION
                    SELECT topic.id
                    FROM topic
                    JOIN family ON topic.mergedIntoTopicID = family.id
                    WHERE topic.deletedAt IS NULL
                )
                SELECT id FROM family ORDER BY id
                """,
            arguments: [rootID])
    }

    static func liveTopic(
        _ topicID: TopicID,
        in database: Database
    ) throws -> TopicRecord? {
        try TopicRecord
            .filter(Column("id") == topicID.rawValue.uuidString)
            .filter(Column("deletedAt") == nil)
            .fetchOne(database)
    }

    static func activeTopic(
        _ topicID: TopicID,
        in database: Database
    ) throws -> TopicRecord {
        guard let record = try liveTopic(topicID, in: database),
              record.mergedIntoTopicID == nil
        else {
            throw StorageError.invalidTopicContinuity(
                "topic is unavailable or already merged")
        }
        return record
    }

    static func topicRoot(
        _ topicKey: String,
        among topics: [String: TopicRecord]
    ) throws -> TopicRecord {
        var key = topicKey
        var visited: Set<String> = []
        while let record = topics[key] {
            guard visited.insert(key).inserted else {
                throw StorageError.invalidTopicContinuity(
                    "persisted topic redirects contain a cycle")
            }
            guard let next = record.mergedIntoTopicID else { return record }
            key = next
        }
        throw StorageError.invalidTopicContinuity(
            "topic redirect target is unavailable")
    }

    static func topicIdentityTimestamp(
        _ proposedDate: Date,
        source: TopicRecord,
        target: TopicRecord,
        in database: Database
    ) throws -> Date {
        let lastEvent = try Date.fetchOne(
            database,
            sql: """
                SELECT MAX(occurredAt)
                FROM topicIdentityEvent
                WHERE sourceTopicID IN (?, ?)
                   OR targetTopicID IN (?, ?)
                """,
            arguments: [source.id, target.id, source.id, target.id])
        let floor = [source.updatedAt, target.updatedAt, lastEvent]
            .compactMap { $0 }
            .max() ?? proposedDate
        return canonicalTopicDate(max(
            canonicalTopicDate(proposedDate),
            canonicalTopicDate(floor).addingTimeInterval(0.001)))
    }

    static func canonicalTopicDate(_ date: Date) -> Date {
        let milliseconds = (date.timeIntervalSince1970 * 1_000).rounded()
        return Date(timeIntervalSince1970: milliseconds / 1_000)
    }

    static func sameTopicDate(_ lhs: Date, _ rhs: Date) -> Bool {
        lhs.databaseValue == rhs.databaseValue
    }

}
