import GRDB

extension StorageSchema {
    static func registerMeetingMemoryGraphMigration(
        in migrator: inout DatabaseMigrator
    ) {
        migrator.registerMigration("v27") { database in
            try createMeetingMemoryGraphTables(in: database)
            try seedMeetingMemoryGraphInvalidations(in: database)
            try createMeetingMemoryGraphInvalidationTriggers(in: database)
        }
    }

    private static func createMeetingMemoryGraphTables(
        in database: Database
    ) throws {
        try createMeetingMemoryGraphControlTables(in: database)
        try createMeetingMemoryGraphEdgeTables(in: database)
    }

    private static func createMeetingMemoryGraphControlTables(
        in database: Database
    ) throws {
        try database.execute(sql: """
            INSERT INTO derivedMaintenanceSource (kind, sourceGeneration, updatedAt)
            VALUES ('meeting-memory-graph', 0, CURRENT_TIMESTAMP)
            """)

        try database.create(table: "meetingMemoryGraphProjectionState") { table in
            table.primaryKey("id", .text).check(sql: "id = 'current'")
            table.column("profileFingerprint", .text).check(
                sql: "profileFingerprint IS NULL OR length(profileFingerprint) = 64")
            table.column("sourceGeneration", .integer).notNull().defaults(to: 0).check(
                sql: "sourceGeneration >= 0")
            table.column("updatedAt", .datetime).notNull()
        }
        try database.execute(sql: """
            INSERT INTO meetingMemoryGraphProjectionState (
                id, profileFingerprint, sourceGeneration, updatedAt
            ) VALUES ('current', NULL, 0, CURRENT_TIMESTAMP)
            """)

        try database.create(table: "meetingMemoryGraphInvalidation") { table in
            table.column("scopeKind", .text).notNull().check(
                sql: "scopeKind IN ('meeting', 'person', 'topic', 'decision', 'commitment')")
            table.column("scopeID", .text).notNull().check(
                sql: "length(trim(scopeID)) > 0")
            table.column("sourceGeneration", .integer).notNull().check(
                sql: "sourceGeneration >= 0")
            table.column("createdAt", .datetime).notNull()
            // One replay cursor per scope. New mutations advance the cursor
            // instead of retaining an unbounded derived-history log.
            table.primaryKey(["scopeKind", "scopeID"])
        }
        try database.create(
            index: "meetingMemoryGraphInvalidation_on_generation",
            on: "meetingMemoryGraphInvalidation",
            columns: ["sourceGeneration", "scopeKind", "scopeID"])
    }

    private static func createMeetingMemoryGraphEdgeTables(
        in database: Database
    ) throws {
        try database.create(table: "meetingMemoryGraphMeetingPerson") { table in
            table.column("meetingID", .text).notNull()
                .references("meeting", onDelete: .cascade)
            table.column("personID", .text).notNull()
                .references("person", onDelete: .cascade)
            table.primaryKey(["meetingID", "personID"])
        }
        try database.create(
            index: "meetingMemoryGraphMeetingPerson_on_person",
            on: "meetingMemoryGraphMeetingPerson",
            columns: ["personID", "meetingID"])

        try database.create(table: "meetingMemoryGraphMeetingTopic") { table in
            table.column("meetingID", .text).notNull()
                .references("meeting", onDelete: .cascade)
            table.column("topicID", .text).notNull()
                .references("topic", onDelete: .cascade)
            table.primaryKey(["meetingID", "topicID"])
        }
        try database.create(
            index: "meetingMemoryGraphMeetingTopic_on_topic",
            on: "meetingMemoryGraphMeetingTopic",
            columns: ["topicID", "meetingID"])

        try database.create(table: "meetingMemoryGraphMeetingDecision") { table in
            table.column("meetingID", .text).notNull()
                .references("meeting", onDelete: .cascade)
            table.column("decisionID", .text).notNull()
                .references("decisionContinuity", onDelete: .cascade)
            table.primaryKey(["meetingID", "decisionID"])
        }
        try database.create(
            index: "meetingMemoryGraphMeetingDecision_on_decision",
            on: "meetingMemoryGraphMeetingDecision",
            columns: ["decisionID", "meetingID"])

        try database.create(table: "meetingMemoryGraphMeetingCommitment") { table in
            table.column("meetingID", .text).notNull()
                .references("meeting", onDelete: .cascade)
            table.column("commitmentID", .text).notNull()
                .references("commitment", onDelete: .cascade)
            table.primaryKey(["meetingID", "commitmentID"])
        }
        try database.create(
            index: "meetingMemoryGraphMeetingCommitment_on_commitment",
            on: "meetingMemoryGraphMeetingCommitment",
            columns: ["commitmentID", "meetingID"])

        try database.create(table: "meetingMemoryGraphCommitmentPerson") { table in
            table.column("commitmentID", .text).notNull()
                .references("commitment", onDelete: .cascade)
            table.column("personID", .text).notNull()
                .references("person", onDelete: .cascade)
            table.primaryKey(["commitmentID", "personID"])
        }
        try database.create(
            index: "meetingMemoryGraphCommitmentPerson_on_person",
            on: "meetingMemoryGraphCommitmentPerson",
            columns: ["personID", "commitmentID"])
    }

    private static func seedMeetingMemoryGraphInvalidations(
        in database: Database
    ) throws {
        let hasAuthority = try Bool.fetchOne(database, sql: """
            SELECT EXISTS (SELECT 1 FROM meeting)
                OR EXISTS (SELECT 1 FROM person)
                OR EXISTS (SELECT 1 FROM topic)
                OR EXISTS (SELECT 1 FROM decisionContinuity)
                OR EXISTS (SELECT 1 FROM commitment)
            """) ?? false
        guard hasAuthority else { return }
        try database.execute(sql: """
            UPDATE derivedMaintenanceSource
            SET sourceGeneration = 1, updatedAt = CURRENT_TIMESTAMP
            WHERE kind = 'meeting-memory-graph';

            INSERT INTO meetingMemoryGraphInvalidation (
                scopeKind, scopeID, sourceGeneration, createdAt
            )
            SELECT 'meeting', id, 1, CURRENT_TIMESTAMP FROM meeting
            UNION ALL SELECT 'person', id, 1, CURRENT_TIMESTAMP FROM person
            UNION ALL SELECT 'topic', id, 1, CURRENT_TIMESTAMP FROM topic
            UNION ALL SELECT 'decision', id, 1, CURRENT_TIMESTAMP
                FROM decisionContinuity
            UNION ALL SELECT 'commitment', id, 1, CURRENT_TIMESTAMP
                FROM commitment;
            """)
    }

    // swiftlint:disable:next function_body_length
    private static func createMeetingMemoryGraphInvalidationTriggers(
        in database: Database
    ) throws {
        try createMemoryGraphTrigger(
            "memoryGraphMeeting_au",
            timing: "AFTER UPDATE OF transcriptRevision, deletedAt",
            table: "meeting",
            scopes: "SELECT 'meeting' AS scopeKind, NEW.id AS scopeID",
            when: valuesChanged(["transcriptRevision", "deletedAt"]), in: database)
        try createMemoryGraphTrigger(
            "memoryGraphMeeting_ad", timing: "AFTER DELETE", table: "meeting",
            scopes: "SELECT 'meeting' AS scopeKind, OLD.id AS scopeID", in: database)

        try createMemoryGraphTrigger(
            "memoryGraphSpeaker_ai", timing: "AFTER INSERT", table: "speaker",
            scopes: "SELECT 'meeting' AS scopeKind, NEW.meetingID AS scopeID", in: database)
        try createMemoryGraphTrigger(
            "memoryGraphSpeaker_au",
            timing: "AFTER UPDATE OF meetingID, personID, deletedAt", table: "speaker",
            scopes: """
                SELECT 'meeting' AS scopeKind, OLD.meetingID AS scopeID
                UNION SELECT 'meeting', NEW.meetingID
                """,
            when: valuesChanged(["meetingID", "personID", "deletedAt"]), in: database)
        try createMemoryGraphTrigger(
            "memoryGraphSpeaker_ad", timing: "AFTER DELETE", table: "speaker",
            scopes: "SELECT 'meeting' AS scopeKind, OLD.meetingID AS scopeID", in: database)

        try createMemoryGraphTrigger(
            "memoryGraphPerson_ai", timing: "AFTER INSERT", table: "person",
            scopes: "SELECT 'person' AS scopeKind, NEW.id AS scopeID", in: database)
        try createMemoryGraphTrigger(
            "memoryGraphPerson_au", timing: "AFTER UPDATE OF deletedAt", table: "person",
            scopes: "SELECT 'person' AS scopeKind, NEW.id AS scopeID",
            when: valuesChanged(["deletedAt"]), in: database)
        try createMemoryGraphTrigger(
            "memoryGraphPerson_ad", timing: "AFTER DELETE", table: "person",
            scopes: "SELECT 'person' AS scopeKind, OLD.id AS scopeID", in: database)

        try createMemoryGraphTrigger(
            "memoryGraphTopic_ai", timing: "AFTER INSERT", table: "topic",
            scopes: "SELECT 'topic' AS scopeKind, NEW.id AS scopeID", in: database)
        try createMemoryGraphTrigger(
            "memoryGraphTopic_au",
            timing: "AFTER UPDATE OF mergedIntoTopicID, deletedAt", table: "topic",
            scopes: """
                SELECT 'topic' AS scopeKind, NEW.id AS scopeID
                UNION SELECT 'topic', OLD.mergedIntoTopicID
                UNION SELECT 'topic', NEW.mergedIntoTopicID
                """,
            when: valuesChanged(["mergedIntoTopicID", "deletedAt"]), in: database)
        try createMemoryGraphTrigger(
            "memoryGraphTopic_ad", timing: "AFTER DELETE", table: "topic",
            scopes: "SELECT 'topic' AS scopeKind, OLD.id AS scopeID", in: database)
        try createMemoryGraphTrigger(
            "memoryGraphTopicEvidence_ai", timing: "AFTER INSERT",
            table: "topicMeetingEvidence",
            scopes: "SELECT 'topic' AS scopeKind, NEW.topicID AS scopeID", in: database)
        try createMemoryGraphTrigger(
            "memoryGraphTopicEvidence_ad", timing: "AFTER DELETE",
            table: "topicMeetingEvidence",
            scopes: "SELECT 'topic' AS scopeKind, OLD.topicID AS scopeID", in: database)
        try createMemoryGraphTrigger(
            "memoryGraphTopicIdentityEvent_ai", timing: "AFTER INSERT",
            table: "topicIdentityEvent",
            scopes: """
                SELECT 'topic' AS scopeKind, NEW.sourceTopicID AS scopeID
                UNION SELECT 'topic', NEW.targetTopicID
                """,
            in: database)

        try createMemoryGraphTrigger(
            "memoryGraphDecision_ai", timing: "AFTER INSERT", table: "decisionContinuity",
            scopes: "SELECT 'decision' AS scopeKind, NEW.id AS scopeID", in: database)
        try createMemoryGraphTrigger(
            "memoryGraphDecision_au",
            timing: "AFTER UPDATE OF deletedAt", table: "decisionContinuity",
            scopes: "SELECT 'decision' AS scopeKind, NEW.id AS scopeID",
            when: valuesChanged(["deletedAt"]), in: database)
        try createMemoryGraphTrigger(
            "memoryGraphDecision_ad", timing: "AFTER DELETE", table: "decisionContinuity",
            scopes: "SELECT 'decision' AS scopeKind, OLD.id AS scopeID", in: database)
        try createMemoryGraphTrigger(
            "memoryGraphDecisionSource_ai", timing: "AFTER INSERT",
            table: "decisionContinuitySource",
            scopes: "SELECT 'decision' AS scopeKind, NEW.decisionID AS scopeID", in: database)
        try createMemoryGraphTrigger(
            "memoryGraphDecisionSource_ad", timing: "AFTER DELETE",
            table: "decisionContinuitySource",
            scopes: "SELECT 'decision' AS scopeKind, OLD.decisionID AS scopeID", in: database)

        try createMemoryGraphTrigger(
            "memoryGraphCommitment_ai", timing: "AFTER INSERT", table: "commitment",
            scopes: "SELECT 'commitment' AS scopeKind, NEW.id AS scopeID", in: database)
        try createMemoryGraphTrigger(
            "memoryGraphCommitment_au",
            timing: "AFTER UPDATE OF canonicalPersonID, assigneeKind, deletedAt",
            table: "commitment",
            scopes: "SELECT 'commitment' AS scopeKind, NEW.id AS scopeID",
            when: valuesChanged([
                "canonicalPersonID", "assigneeKind", "deletedAt"
            ]), in: database)
        try createMemoryGraphTrigger(
            "memoryGraphCommitment_ad", timing: "AFTER DELETE", table: "commitment",
            scopes: "SELECT 'commitment' AS scopeKind, OLD.id AS scopeID", in: database)
        try createMemoryGraphTrigger(
            "memoryGraphCommitmentSource_ai", timing: "AFTER INSERT",
            table: "commitmentSource",
            scopes: "SELECT 'commitment' AS scopeKind, NEW.commitmentID AS scopeID",
            in: database)
        try createMemoryGraphTrigger(
            "memoryGraphCommitmentSource_ad", timing: "AFTER DELETE",
            table: "commitmentSource",
            scopes: "SELECT 'commitment' AS scopeKind, OLD.commitmentID AS scopeID",
            in: database)
    }

    static func createMemoryGraphTrigger(
        _ name: String,
        timing: String,
        table: String,
        scopes: String,
        when condition: String? = nil,
        in database: Database
    ) throws {
        let body = """
            UPDATE derivedMaintenanceSource
            SET sourceGeneration = sourceGeneration + 1,
                updatedAt = CURRENT_TIMESTAMP
            WHERE kind = 'meeting-memory-graph';

            INSERT INTO meetingMemoryGraphInvalidation (
                scopeKind, scopeID, sourceGeneration, createdAt
            )
            SELECT scope.scopeKind,
                   scope.scopeID,
                   source.sourceGeneration,
                   CURRENT_TIMESTAMP
            FROM (\(scopes)) AS scope
            JOIN derivedMaintenanceSource AS source
              ON source.kind = 'meeting-memory-graph'
            WHERE scope.scopeID IS NOT NULL
            ON CONFLICT(scopeKind, scopeID) DO UPDATE SET
                sourceGeneration = excluded.sourceGeneration,
                createdAt = excluded.createdAt;
            """
        try createTrigger(
            name,
            timing: timing,
            table: table,
            body: body,
            when: condition,
            in: database)
    }
}
