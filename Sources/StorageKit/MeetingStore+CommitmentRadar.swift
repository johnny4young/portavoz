import Foundation
import GRDB
import PortavozCore

extension MeetingStore {
    /// One snapshot-consistent Radar read. Its statement count has a fixed
    /// upper bound: roots, sources, history, and any referenced people.
    /// It never hydrates Meeting Detail once per commitment.
    public func commitmentRadar(
        _ query: CommitmentRadarQuery
    ) async throws -> CommitmentRadarPage {
        try await database.read { database in
            let roots = try Self.commitmentRadarRoots(query, in: database)
            guard !roots.isEmpty else {
                return CommitmentRadarPage(items: [], totalCount: 0)
            }

            let commitmentKeys = roots.map(\.id)
            let sourceRows = try Self.commitmentRadarSources(
                commitmentKeys: commitmentKeys,
                limitPerCommitment: query.sourceLimitPerItem,
                in: database)
            let eventRows = try Self.commitmentRadarEvents(
                commitmentKeys: commitmentKeys,
                limitPerCommitment: query.historyLimitPerItem,
                in: database)
            let personNames = try Self.commitmentRadarPersonNames(
                roots: roots,
                eventRows: eventRows,
                in: database)

            let sourcesByCommitment = Dictionary(grouping: sourceRows, by: \.commitmentID)
            let eventsByCommitment = Dictionary(grouping: eventRows, by: \.commitmentID)
            let items = try roots.map { root -> CommitmentRadarItem in
                let sourceMaterial = sourcesByCommitment[root.id] ?? []
                let eventMaterial = eventsByCommitment[root.id] ?? []
                guard let sourceCount = sourceMaterial.first?.relatedRowCount,
                      let historyCount = eventMaterial.first?.relatedRowCount,
                      sourceCount > 0,
                      historyCount > 0
                else {
                    throw StorageError.invalidCommitment(
                        "Radar root is missing confirmed source or history")
                }
                let commitment = try root.commitment
                return CommitmentRadarItem(
                    commitment: commitment,
                    assigneeDisplayName: Self.commitmentRadarAssigneeName(
                        commitment.assignee,
                        personNames: personNames),
                    activity: try root.activity(query: query),
                    sources: try sourceMaterial.map { try $0.source },
                    sourceCount: sourceCount,
                    history: try eventMaterial.map {
                        try $0.historyEvent(personNames: personNames)
                    },
                    historyCount: historyCount)
            }
            return CommitmentRadarPage(
                items: items,
                totalCount: roots.first?.totalCount ?? 0)
        }
    }
}

private extension MeetingStore {
    static func commitmentRadarRoots(
        _ query: CommitmentRadarQuery,
        in database: Database
    ) throws -> [CommitmentRadarRootRow] {
        let predicates = commitmentRadarRootPredicates(query)
        let arguments: StatementArguments = [
            "personID": commitmentRadarPersonID(query.owner),
            "dayStart": query.dayStart,
            "dueSoonEnd": query.dueSoonEnd,
            "newSince": query.newSince,
            "itemLimit": query.itemLimit
        ]
        return try CommitmentRadarRootRow.fetchAll(
            database,
            sql: """
                WITH rankedEvent AS (
                    SELECT commitmentID,
                           kind,
                           occurredAt,
                           ROW_NUMBER() OVER (
                               PARTITION BY commitmentID
                               ORDER BY occurredAt DESC, id DESC
                           ) AS rowRank
                    FROM commitmentEvent
                )
                SELECT c.id,
                       c.assigneeKind,
                       c.canonicalPersonID,
                       c.title,
                       c.status,
                       c.dueAt,
                       c.createdAt,
                       c.updatedAt,
                       c.deletedAt,
                       latest.kind AS latestEventKind,
                       latest.occurredAt AS latestEventAt,
                       COUNT(*) OVER () AS totalCount
                FROM commitment c
                JOIN rankedEvent latest
                  ON latest.commitmentID = c.id
                 AND latest.rowRank = 1
                WHERE \(predicates.joined(separator: "\n  AND "))
                ORDER BY
                    CASE
                        WHEN c.status = 'confirmed'
                         AND c.dueAt IS NOT NULL
                         AND c.dueAt < :dayStart THEN 0
                        WHEN c.status = 'confirmed'
                         AND c.dueAt >= :dayStart
                         AND c.dueAt < :dueSoonEnd THEN 1
                        WHEN c.status = 'confirmed' THEN 2
                        ELSE 3
                    END,
                    CASE WHEN c.status = 'confirmed' THEN c.dueAt END ASC,
                    c.updatedAt DESC,
                    c.id ASC
                LIMIT :itemLimit
                """,
            arguments: arguments)
    }

    static func commitmentRadarRootPredicates(
        _ query: CommitmentRadarQuery
    ) -> [String] {
        var predicates = [
            "c.deletedAt IS NULL",
            "c.status != 'dismissed'"
        ]
        if let owner = commitmentRadarOwnerPredicate(query.owner) {
            predicates.append(owner)
        }
        if let due = commitmentRadarDuePredicate(query.due) {
            predicates.append(due)
        }
        if let activity = commitmentRadarActivityPredicate(query.activity) {
            predicates.append(activity)
        }
        return predicates
    }

    static func commitmentRadarOwnerPredicate(
        _ owner: CommitmentRadarOwnerFilter
    ) -> String? {
        switch owner {
        case .all:
            nil
        case .mine:
            "c.assigneeKind = 'me'"
        case .others:
            "c.assigneeKind = 'person'"
        case .unassigned:
            "c.assigneeKind = 'unassigned'"
        case .person:
            "c.assigneeKind = 'person' AND c.canonicalPersonID = :personID"
        }
    }

    static func commitmentRadarDuePredicate(
        _ due: CommitmentRadarDueFilter
    ) -> String? {
        switch due {
        case .all:
            nil
        case .dueSoon:
            "c.status = 'confirmed' AND c.dueAt >= :dayStart "
                + "AND c.dueAt < :dueSoonEnd"
        case .overdue:
            "c.status = 'confirmed' AND c.dueAt IS NOT NULL "
                + "AND c.dueAt < :dayStart"
        case .noDate:
            "c.status = 'confirmed' AND c.dueAt IS NULL"
        }
    }

    static func commitmentRadarActivityPredicate(
        _ activity: CommitmentRadarActivityFilter
    ) -> String? {
        switch activity {
        case .all:
            nil
        case .activity(.new):
            "c.status = 'confirmed' AND latest.kind = 'confirm' "
                + "AND latest.occurredAt >= :newSince"
        case .activity(.unchanged):
            "c.status = 'confirmed' AND latest.kind != 'reopen' "
                + "AND NOT (latest.kind = 'confirm' "
                + "AND latest.occurredAt >= :newSince)"
        case .activity(.completed):
            "c.status = 'done'"
        case .activity(.reopened):
            "c.status = 'confirmed' AND latest.kind = 'reopen'"
        }
    }

    static func commitmentRadarPersonID(
        _ owner: CommitmentRadarOwnerFilter
    ) -> String? {
        guard case .person(let id) = owner else { return nil }
        return id.rawValue.uuidString
    }

    static func commitmentRadarSources(
        commitmentKeys: [String],
        limitPerCommitment: Int,
        in database: Database
    ) throws -> [CommitmentRadarSourceRow] {
        let placeholders = databaseQuestionMarks(count: commitmentKeys.count)
        var arguments = StatementArguments(commitmentKeys)
        arguments += StatementArguments([limitPerCommitment])
        return try CommitmentRadarSourceRow.fetchAll(
            database,
            sql: """
                WITH sourceMaterial AS (
                    SELECT source.id,
                           source.commitmentID,
                           source.kind,
                           source.meetingID,
                           source.actionItemID,
                           source.contextItemID,
                           source.transcriptRevision,
                           source.firstSeenAt,
                           meeting.title AS meetingTitle,
                           CASE
                               WHEN meeting.id IS NOT NULL
                                AND meeting.deletedAt IS NULL THEN 1
                               ELSE 0
                           END AS isMeetingAvailable,
                           COUNT(evidence.ordinal) AS evidenceCount
                    FROM commitmentSource source
                    LEFT JOIN commitmentEvidenceSegment evidence
                      ON evidence.sourceID = source.id
                    LEFT JOIN meeting ON meeting.id = source.meetingID
                    WHERE source.commitmentID IN (\(placeholders))
                    GROUP BY source.id
                ), rankedSource AS (
                    SELECT *,
                           ROW_NUMBER() OVER (
                               PARTITION BY commitmentID
                               ORDER BY firstSeenAt ASC, id ASC
                           ) AS rowRank,
                           COUNT(*) OVER (
                               PARTITION BY commitmentID
                           ) AS relatedRowCount
                    FROM sourceMaterial
                )
                SELECT *
                FROM rankedSource
                WHERE rowRank <= ?
                ORDER BY commitmentID ASC, rowRank ASC
                """,
            arguments: arguments)
    }

    static func commitmentRadarEvents(
        commitmentKeys: [String],
        limitPerCommitment: Int,
        in database: Database
    ) throws -> [CommitmentRadarEventRow] {
        let placeholders = databaseQuestionMarks(count: commitmentKeys.count)
        var arguments = StatementArguments(commitmentKeys)
        arguments += StatementArguments([limitPerCommitment])
        return try CommitmentRadarEventRow.fetchAll(
            database,
            sql: """
                WITH rankedEvent AS (
                    SELECT event.id,
                           event.commitmentID,
                           event.kind,
                           event.assigneeKind,
                           event.canonicalPersonID,
                           event.dueAt,
                           event.sourceMeetingID,
                           event.occurredAt,
                           meeting.title AS sourceMeetingTitle,
                           CASE
                               WHEN meeting.id IS NOT NULL
                                AND meeting.deletedAt IS NULL THEN 1
                               ELSE 0
                           END AS isSourceMeetingAvailable,
                           ROW_NUMBER() OVER (
                               PARTITION BY event.commitmentID
                               ORDER BY event.occurredAt DESC, event.id DESC
                           ) AS rowRank,
                           COUNT(*) OVER (
                               PARTITION BY event.commitmentID
                           ) AS relatedRowCount
                    FROM commitmentEvent event
                    LEFT JOIN meeting ON meeting.id = event.sourceMeetingID
                    WHERE event.commitmentID IN (\(placeholders))
                )
                SELECT *
                FROM rankedEvent
                WHERE rowRank <= ?
                ORDER BY commitmentID ASC, rowRank ASC
                """,
            arguments: arguments)
    }

    static func commitmentRadarPersonNames(
        roots: [CommitmentRadarRootRow],
        eventRows: [CommitmentRadarEventRow],
        in database: Database
    ) throws -> [PersonID: String] {
        let keys = Set(
            roots.compactMap(\.canonicalPersonID)
                + eventRows.compactMap(\.canonicalPersonID))
        guard !keys.isEmpty else { return [:] }
        let records = try PersonRecord
            .filter(keys.contains(Column("id")))
            .fetchAll(database)
        return try Dictionary(uniqueKeysWithValues: records.map {
            let person = try $0.person
            return (person.id, person.preferredName)
        })
    }

    static func commitmentRadarAssigneeName(
        _ assignee: CommitmentAssignee,
        personNames: [PersonID: String]
    ) -> String? {
        guard case .person(let personID) = assignee else { return nil }
        return personNames[personID]
    }
}

private struct CommitmentRadarRootRow: Decodable, FetchableRecord {
    let id: String
    let assigneeKind: String
    let canonicalPersonID: String?
    let title: String
    let status: String
    let dueAt: Date?
    let createdAt: Date
    let updatedAt: Date
    let deletedAt: Date?
    let latestEventKind: String
    let latestEventAt: Date
    let totalCount: Int

    var commitment: Commitment {
        get throws {
            guard let status = CommitmentStatus(rawValue: status),
                  let assigneeKind = CommitmentAssigneeKind(rawValue: assigneeKind),
                  let assignee = CommitmentAssignee(
                      kind: assigneeKind,
                      canonicalPersonID: try PersistedIdentity.optional(
                          canonicalPersonID,
                          table: CommitmentRecord.databaseTableName,
                          column: "canonicalPersonID"
                      ).map { PersonID(rawValue: $0) })
            else {
                throw StorageError.invalidPersistedValue(
                    table: CommitmentRecord.databaseTableName,
                    column: "assigneeKind",
                    value: assigneeKind)
            }
            return Commitment(
                id: CommitmentID(rawValue: try PersistedIdentity.required(
                    id,
                    table: CommitmentRecord.databaseTableName,
                    column: "id")),
                title: title,
                status: status,
                assignee: assignee,
                dueAt: dueAt,
                createdAt: createdAt,
                updatedAt: updatedAt,
                deletedAt: deletedAt)
        }
    }

    func activity(query: CommitmentRadarQuery) throws -> CommitmentRadarActivity {
        guard let status = CommitmentStatus(rawValue: status),
              let latestKind = CommitmentEventKind(rawValue: latestEventKind)
        else {
            throw StorageError.invalidCommitment("Radar root has invalid lifecycle state")
        }
        switch status {
        case .done:
            guard latestKind == .complete else {
                throw StorageError.invalidCommitment(
                    "Radar root does not match its latest lifecycle event")
            }
            return .completed
        case .confirmed:
            guard [.confirm, .reassign, .reschedule, .reopen].contains(latestKind) else {
                throw StorageError.invalidCommitment(
                    "Radar root does not match its latest lifecycle event")
            }
            if latestKind == .reopen { return .reopened }
            if latestKind == .confirm, latestEventAt >= query.newSince { return .new }
            return .unchanged
        case .dismissed:
            throw StorageError.invalidCommitment(
                "Dismissed commitments cannot enter Radar")
        }
    }
}

private struct CommitmentRadarSourceRow: Decodable, FetchableRecord {
    let id: String
    let commitmentID: String
    let kind: String
    let meetingID: String?
    let actionItemID: String?
    let contextItemID: String?
    let transcriptRevision: Int?
    let firstSeenAt: Date
    let meetingTitle: String?
    let isMeetingAvailable: Bool
    let evidenceCount: Int
    let relatedRowCount: Int

    var source: CommitmentRadarSource {
        get throws {
            guard let sourceKind = CommitmentSourceKind(rawValue: kind) else {
                throw StorageError.invalidPersistedValue(
                    table: CommitmentSourceRecord.databaseTableName,
                    column: "kind",
                    value: kind)
            }
            return CommitmentRadarSource(
                id: CommitmentSourceID(rawValue: try PersistedIdentity.required(
                    id,
                    table: CommitmentSourceRecord.databaseTableName,
                    column: "id")),
                kind: sourceKind,
                meetingID: try PersistedIdentity.optional(
                    meetingID,
                    table: CommitmentSourceRecord.databaseTableName,
                    column: "meetingID"
                ).map { MeetingID(rawValue: $0) },
                meetingTitle: meetingTitle,
                actionItemID: try PersistedIdentity.optional(
                    actionItemID,
                    table: CommitmentSourceRecord.databaseTableName,
                    column: "actionItemID"),
                contextItemID: try PersistedIdentity.optional(
                    contextItemID,
                    table: CommitmentSourceRecord.databaseTableName,
                    column: "contextItemID"),
                transcriptRevision: transcriptRevision,
                firstSeenAt: firstSeenAt,
                evidenceCount: evidenceCount,
                isMeetingAvailable: isMeetingAvailable)
        }
    }
}

private struct CommitmentRadarEventRow: Decodable, FetchableRecord {
    let id: String
    let commitmentID: String
    let kind: String
    let assigneeKind: String?
    let canonicalPersonID: String?
    let dueAt: Date?
    let sourceMeetingID: String?
    let occurredAt: Date
    let sourceMeetingTitle: String?
    let isSourceMeetingAvailable: Bool
    let relatedRowCount: Int

    func historyEvent(
        personNames: [PersonID: String]
    ) throws -> CommitmentRadarHistoryEvent {
        guard let eventKind = CommitmentEventKind(rawValue: kind) else {
            throw StorageError.invalidPersistedValue(
                table: CommitmentEventRecord.databaseTableName,
                column: "kind",
                value: kind)
        }
        let personID = try PersistedIdentity.optional(
            canonicalPersonID,
            table: CommitmentEventRecord.databaseTableName,
            column: "canonicalPersonID"
        ).map { PersonID(rawValue: $0) }
        let assignee: CommitmentAssignee?
        if let assigneeKind {
            guard let kind = CommitmentAssigneeKind(rawValue: assigneeKind),
                  let decoded = CommitmentAssignee(
                      kind: kind,
                      canonicalPersonID: personID)
            else {
                throw StorageError.invalidPersistedValue(
                    table: CommitmentEventRecord.databaseTableName,
                    column: "assigneeKind",
                    value: assigneeKind)
            }
            assignee = decoded
        } else {
            guard personID == nil else {
                throw StorageError.invalidPersistedValue(
                    table: CommitmentEventRecord.databaseTableName,
                    column: "canonicalPersonID",
                    value: canonicalPersonID ?? "")
            }
            assignee = nil
        }
        return CommitmentRadarHistoryEvent(
            id: CommitmentEventID(rawValue: try PersistedIdentity.required(
                id,
                table: CommitmentEventRecord.databaseTableName,
                column: "id")),
            kind: eventKind,
            assignee: assignee,
            assigneeDisplayName: assignee.flatMap {
                MeetingStore.commitmentRadarAssigneeName(
                    $0,
                    personNames: personNames)
            },
            dueAt: dueAt,
            sourceMeetingID: try PersistedIdentity.optional(
                sourceMeetingID,
                table: CommitmentEventRecord.databaseTableName,
                column: "sourceMeetingID"
            ).map { MeetingID(rawValue: $0) },
            sourceMeetingTitle: sourceMeetingTitle,
            isSourceMeetingAvailable: isSourceMeetingAvailable,
            occurredAt: occurredAt)
    }
}
