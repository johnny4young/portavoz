import Foundation
import GRDB
import PortavozCore

extension MeetingStore {
    public func meetingMemoryGraphRequiresMaintenance(
        targetFingerprint: String = MeetingMemoryGraphProjectionProfile.fingerprint
    ) async throws -> Bool {
        try await database.read { database in
            let active = try String.fetchOne(
                database,
                sql: """
                    SELECT profileFingerprint
                    FROM meetingMemoryGraphProjectionState
                    WHERE id = 'current'
                    """)
            if active?.lowercased() != targetFingerprint.lowercased() {
                return true
            }
            return try Bool.fetchOne(
                database,
                sql: """
                    SELECT EXISTS (
                        SELECT 1 FROM meetingMemoryGraphInvalidation
                    )
                    """) ?? false
        }
    }

    public func admitMeetingMemoryGraphMaintenance(
        targetFingerprint: String = MeetingMemoryGraphProjectionProfile.fingerprint,
        maxAttempts: Int = 3,
        at timestamp: Date = Date()
    ) async throws -> DerivedMaintenanceJob {
        try await admitDerivedMaintenance(
            kind: .meetingMemoryGraph,
            targetFingerprint: targetFingerprint,
            maxAttempts: maxAttempts,
            at: timestamp)
    }

    public func claimMeetingMemoryGraphMaintenance(
        targetFingerprint: String = MeetingMemoryGraphProjectionProfile.fingerprint,
        owner: String,
        leaseDuration: TimeInterval,
        at timestamp: Date = Date()
    ) async throws -> DerivedMaintenanceJob? {
        try await claimDerivedMaintenance(
            kind: .meetingMemoryGraph,
            targetFingerprint: targetFingerprint,
            owner: owner,
            leaseDuration: leaseDuration,
            at: timestamp)
    }

    public func heartbeatMeetingMemoryGraphMaintenance(
        _ id: DerivedMaintenanceJobID,
        owner: String,
        leaseDuration: TimeInterval,
        at timestamp: Date = Date()
    ) async throws {
        try await heartbeatDerivedMaintenance(
            id,
            kind: .meetingMemoryGraph,
            owner: owner,
            leaseDuration: leaseDuration,
            at: timestamp)
    }

    public func suspendMeetingMemoryGraphMaintenance(
        _ id: DerivedMaintenanceJobID,
        owner: String,
        at timestamp: Date = Date()
    ) async throws -> DerivedMaintenanceJob {
        try await suspendDerivedMaintenance(
            id, kind: .meetingMemoryGraph, owner: owner, at: timestamp)
    }

    public func completeMeetingMemoryGraphMaintenance(
        _ id: DerivedMaintenanceJobID,
        owner: String,
        at timestamp: Date = Date()
    ) async throws -> DerivedMaintenanceJob {
        try await completeDerivedMaintenance(
            id, kind: .meetingMemoryGraph, owner: owner, at: timestamp)
    }

    public func failMeetingMemoryGraphMaintenance(
        _ id: DerivedMaintenanceJobID,
        owner: String,
        errorCode: String,
        retryAt: Date,
        at timestamp: Date = Date()
    ) async throws -> DerivedMaintenanceJob {
        try await failDerivedMaintenance(
            id,
            kind: .meetingMemoryGraph,
            owner: owner,
            errorCode: errorCode,
            retryAt: retryAt,
            at: timestamp)
    }

    @discardableResult
    public func recoverExpiredMeetingMemoryGraphMaintenance(
        at timestamp: Date = Date()
    ) async throws -> Int {
        try await recoverExpiredDerivedMaintenance(
            kind: .meetingMemoryGraph,
            at: timestamp)
    }

    public func nextScheduledMeetingMemoryGraphMaintenanceDate(
        after timestamp: Date = Date()
    ) async throws -> Date? {
        try await nextScheduledDerivedMaintenanceDate(
            kind: .meetingMemoryGraph,
            after: timestamp)
    }

    public func hasDueMeetingMemoryGraphMaintenance(
        targetFingerprint: String = MeetingMemoryGraphProjectionProfile.fingerprint,
        at timestamp: Date = Date()
    ) async throws -> Bool {
        try await hasDueDerivedMaintenance(
            kind: .meetingMemoryGraph,
            targetFingerprint: targetFingerprint,
            at: timestamp)
    }

    /// Rebuilds a bounded set of typed graph scopes and settles exactly the
    /// invalidation generations included by the claimed durable operation.
    public func projectMeetingMemoryGraphBatch(
        jobID: DerivedMaintenanceJobID,
        owner: String,
        targetFingerprint: String = MeetingMemoryGraphProjectionProfile.fingerprint,
        through sourceGeneration: Int,
        limit: Int = 128,
        at timestamp: Date = Date()
    ) async throws -> MeetingMemoryGraphProjectionResult {
        guard targetFingerprint.count == 64,
              targetFingerprint.allSatisfy({ $0.isHexDigit }),
              sourceGeneration >= 0,
              limit > 0
        else {
            throw StorageError.invalidDerivedMaintenanceJob(
                "memory graph projection inputs are invalid")
        }
        return try await database.write { database in
            try Self.validateOwnedDerivedMaintenancePublication(
                DerivedMaintenancePublicationClaim(
                    id: jobID,
                    kind: .meetingMemoryGraph,
                    targetFingerprint: targetFingerprint,
                    sourceGeneration: sourceGeneration,
                    owner: owner,
                    timestamp: timestamp),
                in: database)
            let reset = try Self.prepareMeetingMemoryGraphProfile(
                targetFingerprint: targetFingerprint.lowercased(),
                sourceGeneration: sourceGeneration,
                at: timestamp,
                in: database)
            let scopes = try Self.pendingMeetingMemoryGraphScopes(
                through: sourceGeneration,
                limit: limit,
                in: database)
            var publishedEdges = 0
            for scope in scopes {
                publishedEdges += try Self.rebuildMeetingMemoryGraphScope(
                    scope,
                    in: database)
                try database.execute(
                    sql: """
                        DELETE FROM meetingMemoryGraphInvalidation
                        WHERE scopeKind = ?
                          AND scopeID = ?
                          AND sourceGeneration <= ?
                        """,
                    arguments: [scope.kind.rawValue, scope.id, scope.generation])
            }
            try database.execute(
                sql: """
                    UPDATE meetingMemoryGraphProjectionState
                    SET sourceGeneration = CASE WHEN NOT EXISTS (
                            SELECT 1 FROM meetingMemoryGraphInvalidation
                            WHERE sourceGeneration <= ?
                        ) THEN MAX(sourceGeneration, ?)
                        ELSE sourceGeneration
                        END,
                        updatedAt = ?
                    WHERE id = 'current'
                    """,
                arguments: [sourceGeneration, sourceGeneration, timestamp])
            return MeetingMemoryGraphProjectionResult(
                rebuiltScopes: scopes.count,
                publishedEdges: publishedEdges,
                resetProjection: reset)
        }
    }

    public func pendingMeetingMemoryGraphInvalidationCount() async throws -> Int {
        try await database.read { database in
            try Int.fetchOne(
                database,
                sql: "SELECT COUNT(*) FROM meetingMemoryGraphInvalidation") ?? 0
        }
    }

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
                commitmentPeople: try Self.commitmentPersonEdges(in: database))
        }
    }

    private struct PendingMemoryGraphScope {
        let kind: MeetingMemoryGraphScopeKind
        let id: String
        let generation: Int
    }

    static func meetingMemoryGraphProjectionIsReady(
        in database: Database
    ) throws -> Bool {
        try Bool.fetchOne(
            database,
            sql: """
                SELECT state.profileFingerprint = ?
                   AND state.sourceGeneration = source.sourceGeneration
                   AND NOT EXISTS (
                       SELECT 1 FROM meetingMemoryGraphInvalidation
                   )
                FROM meetingMemoryGraphProjectionState AS state
                JOIN derivedMaintenanceSource AS source
                  ON source.kind = 'meeting-memory-graph'
                WHERE state.id = 'current'
                """,
            arguments: [MeetingMemoryGraphProjectionProfile.fingerprint]) ?? false
    }

    private static func prepareMeetingMemoryGraphProfile(
        targetFingerprint: String,
        sourceGeneration: Int,
        at timestamp: Date,
        in database: Database
    ) throws -> Bool {
        let current = try String.fetchOne(
            database,
            sql: """
                SELECT profileFingerprint
                FROM meetingMemoryGraphProjectionState
                WHERE id = 'current'
                """)
        guard current?.lowercased() != targetFingerprint else { return false }

        for table in [
            "meetingMemoryGraphMeetingPerson",
            "meetingMemoryGraphMeetingTopic",
            "meetingMemoryGraphMeetingDecision",
            "meetingMemoryGraphMeetingCommitment",
            "meetingMemoryGraphCommitmentPerson"
        ] {
            try database.execute(sql: "DELETE FROM \(table)")
        }
        try seedEveryMeetingMemoryGraphScope(
            generation: sourceGeneration,
            at: timestamp,
            in: database)
        try database.execute(
            sql: """
                UPDATE meetingMemoryGraphProjectionState
                SET profileFingerprint = ?, sourceGeneration = 0, updatedAt = ?
                WHERE id = 'current'
                """,
            arguments: [targetFingerprint, timestamp])
        return true
    }

    private static func seedEveryMeetingMemoryGraphScope(
        generation: Int,
        at timestamp: Date,
        in database: Database
    ) throws {
        for (scope, table) in [
            ("meeting", "meeting"),
            ("person", "person"),
            ("topic", "topic"),
            ("decision", "decisionContinuity"),
            ("commitment", "commitment")
        ] {
            try database.execute(
                sql: """
                    INSERT INTO meetingMemoryGraphInvalidation (
                        scopeKind, scopeID, sourceGeneration, createdAt
                    )
                    SELECT ?, id, ?, ? FROM \(table) WHERE 1
                    ON CONFLICT(scopeKind, scopeID) DO UPDATE SET
                        sourceGeneration = MAX(
                            meetingMemoryGraphInvalidation.sourceGeneration,
                            excluded.sourceGeneration),
                        createdAt = CASE
                            WHEN excluded.sourceGeneration
                                >= meetingMemoryGraphInvalidation.sourceGeneration
                            THEN excluded.createdAt
                            ELSE meetingMemoryGraphInvalidation.createdAt
                        END
                    """,
                arguments: [scope, generation, timestamp])
        }
    }

    private static func pendingMeetingMemoryGraphScopes(
        through sourceGeneration: Int,
        limit: Int,
        in database: Database
    ) throws -> [PendingMemoryGraphScope] {
        try Row.fetchAll(
            database,
            sql: """
                SELECT scopeKind, scopeID, sourceGeneration
                FROM meetingMemoryGraphInvalidation
                WHERE sourceGeneration <= ?
                ORDER BY sourceGeneration, scopeKind, scopeID
                LIMIT ?
                """,
            arguments: [sourceGeneration, limit])
            .map { row in
                guard let kind = MeetingMemoryGraphScopeKind(
                    rawValue: row["scopeKind"] as String)
                else {
                    throw StorageError.invalidDerivedMaintenanceJob(
                        "memory graph invalidation kind is malformed")
                }
                return PendingMemoryGraphScope(
                    kind: kind,
                    id: row["scopeID"],
                    generation: row["sourceGeneration"])
            }
    }

    private static func rebuildMeetingMemoryGraphScope(
        _ scope: PendingMemoryGraphScope,
        in database: Database
    ) throws -> Int {
        switch scope.kind {
        case .meeting:
            try rebuildMeetingMemoryGraphMeeting(scope.id, in: database)
        case .person:
            try rebuildMeetingMemoryGraphPerson(scope.id, in: database)
        case .topic:
            try rebuildMeetingMemoryGraphTopic(scope.id, in: database)
        case .decision:
            try rebuildMeetingMemoryGraphDecision(scope.id, in: database)
        case .commitment:
            try rebuildMeetingMemoryGraphCommitment(scope.id, in: database)
        }
    }

    private static func rebuildMeetingMemoryGraphMeeting(
        _ meetingID: String,
        in database: Database
    ) throws -> Int {
        for table in [
            "meetingMemoryGraphMeetingPerson",
            "meetingMemoryGraphMeetingTopic",
            "meetingMemoryGraphMeetingDecision",
            "meetingMemoryGraphMeetingCommitment"
        ] {
            try database.execute(
                sql: "DELETE FROM \(table) WHERE meetingID = ?",
                arguments: [meetingID])
        }
        var published = 0
        try database.execute(
            sql: """
                INSERT INTO meetingMemoryGraphMeetingPerson (meetingID, personID)
                SELECT DISTINCT speaker.meetingID, speaker.personID
                FROM speaker
                JOIN meeting ON meeting.id = speaker.meetingID
                JOIN person ON person.id = speaker.personID
                WHERE speaker.meetingID = ?
                  AND speaker.deletedAt IS NULL
                  AND meeting.deletedAt IS NULL
                  AND person.deletedAt IS NULL
                """,
            arguments: [meetingID])
        published += database.changesCount
        published += try rebuildMeetingMemoryGraphTopics(
            forMeetingID: meetingID,
            in: database)
        try database.execute(
            sql: """
                INSERT INTO meetingMemoryGraphMeetingDecision (meetingID, decisionID)
                SELECT DISTINCT source.meetingID, source.decisionID
                FROM decisionContinuitySource AS source
                JOIN meeting ON meeting.id = source.meetingID
                JOIN decisionContinuity AS decision ON decision.id = source.decisionID
                WHERE source.meetingID = ?
                  AND meeting.deletedAt IS NULL
                  AND decision.deletedAt IS NULL
                """,
            arguments: [meetingID])
        published += database.changesCount
        try database.execute(
            sql: """
                INSERT INTO meetingMemoryGraphMeetingCommitment (meetingID, commitmentID)
                SELECT DISTINCT source.meetingID, source.commitmentID
                FROM commitmentSource AS source
                JOIN meeting ON meeting.id = source.meetingID
                JOIN commitment ON commitment.id = source.commitmentID
                WHERE source.meetingID = ?
                  AND meeting.deletedAt IS NULL
                  AND commitment.deletedAt IS NULL
                """,
            arguments: [meetingID])
        return published + database.changesCount
    }

    private static func rebuildMeetingMemoryGraphPerson(
        _ personID: String,
        in database: Database
    ) throws -> Int {
        try database.execute(
            sql: "DELETE FROM meetingMemoryGraphMeetingPerson WHERE personID = ?",
            arguments: [personID])
        try database.execute(
            sql: "DELETE FROM meetingMemoryGraphCommitmentPerson WHERE personID = ?",
            arguments: [personID])
        try database.execute(
            sql: """
                INSERT INTO meetingMemoryGraphMeetingPerson (meetingID, personID)
                SELECT DISTINCT speaker.meetingID, speaker.personID
                FROM speaker
                JOIN meeting ON meeting.id = speaker.meetingID
                JOIN person ON person.id = speaker.personID
                WHERE speaker.personID = ?
                  AND speaker.deletedAt IS NULL
                  AND meeting.deletedAt IS NULL
                  AND person.deletedAt IS NULL
                """,
            arguments: [personID])
        let meetingEdges = database.changesCount
        try database.execute(
            sql: """
                INSERT INTO meetingMemoryGraphCommitmentPerson (commitmentID, personID)
                SELECT commitment.id, commitment.canonicalPersonID
                FROM commitment
                JOIN person ON person.id = commitment.canonicalPersonID
                WHERE commitment.canonicalPersonID = ?
                  AND commitment.assigneeKind = 'person'
                  AND commitment.deletedAt IS NULL
                  AND person.deletedAt IS NULL
                """,
            arguments: [personID])
        return meetingEdges + database.changesCount
    }

    private static func rebuildMeetingMemoryGraphTopic(
        _ topicID: String,
        in database: Database
    ) throws -> Int {
        let topics = try liveTopicRecords(in: database)
        guard topics[topicID] != nil else {
            try database.execute(
                sql: "DELETE FROM meetingMemoryGraphMeetingTopic WHERE topicID = ?",
                arguments: [topicID])
            return 0
        }
        let root = try topicRoot(topicID, among: topics)
        let familyIDs = try topics.values.compactMap { record -> String? in
            try topicRoot(record.id, among: topics).id == root.id
                ? record.id
                : nil
        }
        try database.execute(
            sql: """
                DELETE FROM meetingMemoryGraphMeetingTopic
                WHERE topicID IN (\(placeholders(familyIDs.count)))
                """,
            arguments: StatementArguments(familyIDs))
        try database.execute(
            sql: """
                INSERT INTO meetingMemoryGraphMeetingTopic (meetingID, topicID)
                SELECT DISTINCT evidence.meetingID, ?
                FROM topicMeetingEvidence AS evidence
                JOIN meeting ON meeting.id = evidence.meetingID
                WHERE evidence.topicID IN (\(placeholders(familyIDs.count)))
                  AND meeting.deletedAt IS NULL
                """,
            arguments: StatementArguments([root.id] + familyIDs))
        return database.changesCount
    }

    /// Topic evidence remains attached to reversible observed identities. The
    /// disposable edge always targets the current live family root so a merge
    /// or split changes traversal without rewriting authoritative history.
    private static func rebuildMeetingMemoryGraphTopics(
        forMeetingID meetingID: String,
        in database: Database
    ) throws -> Int {
        let topics = try liveTopicRecords(in: database)
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
        let rootIDs = try Set(observedTopicIDs.compactMap { topicID -> String? in
            guard topics[topicID] != nil else { return nil }
            return try topicRoot(topicID, among: topics).id
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

    private static func rebuildMeetingMemoryGraphDecision(
        _ decisionID: String,
        in database: Database
    ) throws -> Int {
        try database.execute(
            sql: "DELETE FROM meetingMemoryGraphMeetingDecision WHERE decisionID = ?",
            arguments: [decisionID])
        try database.execute(
            sql: """
                INSERT INTO meetingMemoryGraphMeetingDecision (meetingID, decisionID)
                SELECT DISTINCT source.meetingID, source.decisionID
                FROM decisionContinuitySource AS source
                JOIN meeting ON meeting.id = source.meetingID
                JOIN decisionContinuity AS decision ON decision.id = source.decisionID
                WHERE source.decisionID = ?
                  AND meeting.deletedAt IS NULL
                  AND decision.deletedAt IS NULL
                """,
            arguments: [decisionID])
        return database.changesCount
    }

    private static func rebuildMeetingMemoryGraphCommitment(
        _ commitmentID: String,
        in database: Database
    ) throws -> Int {
        try database.execute(
            sql: "DELETE FROM meetingMemoryGraphMeetingCommitment WHERE commitmentID = ?",
            arguments: [commitmentID])
        try database.execute(
            sql: "DELETE FROM meetingMemoryGraphCommitmentPerson WHERE commitmentID = ?",
            arguments: [commitmentID])
        try database.execute(
            sql: """
                INSERT INTO meetingMemoryGraphMeetingCommitment (meetingID, commitmentID)
                SELECT DISTINCT source.meetingID, source.commitmentID
                FROM commitmentSource AS source
                JOIN meeting ON meeting.id = source.meetingID
                JOIN commitment ON commitment.id = source.commitmentID
                WHERE source.commitmentID = ?
                  AND meeting.deletedAt IS NULL
                  AND commitment.deletedAt IS NULL
                """,
            arguments: [commitmentID])
        let meetingEdges = database.changesCount
        try database.execute(
            sql: """
                INSERT INTO meetingMemoryGraphCommitmentPerson (commitmentID, personID)
                SELECT commitment.id, commitment.canonicalPersonID
                FROM commitment
                JOIN person ON person.id = commitment.canonicalPersonID
                WHERE commitment.id = ?
                  AND commitment.assigneeKind = 'person'
                  AND commitment.deletedAt IS NULL
                  AND person.deletedAt IS NULL
                """,
            arguments: [commitmentID])
        return meetingEdges + database.changesCount
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

    private static func requiredUUID(_ value: String) throws -> UUID {
        guard let uuid = UUID(uuidString: value) else {
            throw StorageError.invalidDerivedMaintenanceJob(
                "memory graph projection contains a malformed identity")
        }
        return uuid
    }
}
