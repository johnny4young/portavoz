import Foundation
import GRDB
import PortavozCore

extension MeetingStore {
    /// Bounded, title-only catalog reads for protected local entity consumers.
    /// Identifier resolution preserves caller order;
    /// text matching stays in SQLite and never hydrates the whole library.
    public func automationMeetings(
        identifiers: [MeetingID]?,
        matchingTitle: String?,
        limit: Int
    ) async throws -> [Meeting] {
        let limit = Self.automationEntityLimit(limit)
        guard limit > 0 else { return [] }
        return try await database.read { database in
            if let identifiers {
                let identifiers = Self.uniqueAutomationIdentifiers(
                    identifiers,
                    limit: limit)
                guard !identifiers.isEmpty else { return [] }
                let keys = identifiers.map { $0.rawValue.uuidString }
                let rows = try MeetingRecord.fetchAll(
                    database,
                    sql: """
                        SELECT *
                        FROM meeting
                        WHERE deletedAt IS NULL
                          AND id IN (\(databaseQuestionMarks(count: keys.count)))
                        """,
                    arguments: StatementArguments(keys))
                let meetings = try rows.map { try $0.meeting }
                let byID = Dictionary(uniqueKeysWithValues: meetings.map { ($0.id, $0) })
                return identifiers.compactMap { byID[$0] }
            }

            let pattern = Self.automationEntityPattern(matchingTitle)
            let predicate = pattern == nil
                ? ""
                : "AND title LIKE :pattern ESCAPE '\\' COLLATE NOCASE"
            return try MeetingRecord.fetchAll(
                database,
                sql: """
                    SELECT *
                    FROM meeting
                    WHERE deletedAt IS NULL
                      \(predicate)
                    ORDER BY startedAt DESC, id
                    LIMIT :limit
                    """,
                arguments: ["pattern": pattern, "limit": limit])
                .map { try $0.meeting }
        }
    }

    /// Canonical people only. Observed speaker labels never become entities
    /// until the user has explicitly confirmed the person identity.
    public func automationPeople(
        identifiers: [PersonID]?,
        matchingName: String?,
        limit: Int
    ) async throws -> [Person] {
        let limit = Self.automationEntityLimit(limit)
        guard limit > 0 else { return [] }
        return try await database.read { database in
            if let identifiers {
                let identifiers = Self.uniqueAutomationIdentifiers(
                    identifiers,
                    limit: limit)
                guard !identifiers.isEmpty else { return [] }
                let keys = identifiers.map { $0.rawValue.uuidString }
                let rows = try PersonRecord.fetchAll(
                    database,
                    sql: """
                        SELECT *
                        FROM person
                        WHERE deletedAt IS NULL
                          AND id IN (\(databaseQuestionMarks(count: keys.count)))
                        """,
                    arguments: StatementArguments(keys))
                let people = try rows.map { try $0.person }
                let byID = Dictionary(uniqueKeysWithValues: people.map { ($0.id, $0) })
                return identifiers.compactMap { byID[$0] }
            }

            let pattern = Self.automationEntityPattern(matchingName)
            let predicate = pattern == nil
                ? ""
                : "AND preferredName LIKE :pattern ESCAPE '\\' COLLATE NOCASE"
            return try PersonRecord.fetchAll(
                database,
                sql: """
                    SELECT *
                    FROM person
                    WHERE deletedAt IS NULL
                      \(predicate)
                    ORDER BY preferredName COLLATE NOCASE, createdAt, id
                    LIMIT :limit
                    """,
                arguments: ["pattern": pattern, "limit": limit])
                .map { try $0.person }
        }
    }

    /// User-confirmed commitments only. Dismissed candidates and tombstones
    /// never surface as Shortcuts/Siri values.
    public func automationCommitments(
        identifiers: [CommitmentID]?,
        matchingTitle: String?,
        limit: Int
    ) async throws -> [Commitment] {
        let limit = Self.automationEntityLimit(limit)
        guard limit > 0 else { return [] }
        return try await database.read { database in
            if let identifiers {
                let identifiers = Self.uniqueAutomationIdentifiers(
                    identifiers,
                    limit: limit)
                guard !identifiers.isEmpty else { return [] }
                let keys = identifiers.map { $0.rawValue.uuidString }
                let rows = try CommitmentRecord.fetchAll(
                    database,
                    sql: """
                        SELECT *
                        FROM commitment
                        WHERE deletedAt IS NULL
                          AND status != 'dismissed'
                          AND id IN (\(databaseQuestionMarks(count: keys.count)))
                        """,
                    arguments: StatementArguments(keys))
                let commitments = try rows.map { try $0.commitment }
                let byID = Dictionary(
                    uniqueKeysWithValues: commitments.map { ($0.id, $0) })
                return identifiers.compactMap { byID[$0] }
            }

            let pattern = Self.automationEntityPattern(matchingTitle)
            let predicate = pattern == nil
                ? ""
                : "AND title LIKE :pattern ESCAPE '\\' COLLATE NOCASE"
            return try CommitmentRecord.fetchAll(
                database,
                sql: """
                    SELECT *
                    FROM commitment
                    WHERE deletedAt IS NULL
                      AND status != 'dismissed'
                      \(predicate)
                    ORDER BY updatedAt DESC, id
                    LIMIT :limit
                    """,
                arguments: ["pattern": pattern, "limit": limit])
                .map { try $0.commitment }
        }
    }
}

private extension MeetingStore {
    static let maximumAutomationEntityCount = 50

    static func automationEntityLimit(_ requested: Int) -> Int {
        min(max(0, requested), maximumAutomationEntityCount)
    }

    static func uniqueAutomationIdentifiers<ID: Hashable>(
        _ identifiers: [ID],
        limit: Int
    ) -> [ID] {
        var seen = Set<ID>()
        return Array(identifiers.filter { seen.insert($0).inserted }.prefix(limit))
    }

    static func automationEntityPattern(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        return "%\(escaped)%"
    }
}
