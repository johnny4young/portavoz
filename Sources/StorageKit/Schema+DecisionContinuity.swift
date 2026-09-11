import GRDB

extension StorageSchema {
    static func registerDecisionContinuityMigration(
        in migrator: inout DatabaseMigrator
    ) {
        migrator.registerMigration("v26") { database in
            try createDecisionContinuityTable(in: database)
            try createDecisionContinuitySourceTables(in: database)
            try createDecisionContinuityEventTable(in: database)
            try createDecisionContinuityImmutabilityTriggers(in: database)
        }
    }

    private static func createDecisionContinuityTable(
        in database: Database
    ) throws {
        try database.create(table: "decisionContinuity") { table in
            table.primaryKey("id", .text)
            table.column("statement", .text).notNull().check(
                sql: "length(trim(statement)) > 0")
            // Generated observations remain in summaryDecisionEvidence. Only
            // explicitly confirmed truth enters this projection.
            table.column("status", .text).notNull().check(
                sql: "status IN ('confirmed', 'superseded', 'reversed')")
            table.column("createdAt", .datetime).notNull()
            table.column("updatedAt", .datetime).notNull().check(
                sql: "updatedAt >= createdAt")
            table.column("deletedAt", .datetime).check(
                sql: "deletedAt IS NULL OR deletedAt >= createdAt")
        }
        try database.create(
            index: "decisionContinuity_on_status_updatedAt",
            on: "decisionContinuity",
            columns: ["deletedAt", "status", "updatedAt", "id"])
    }

    private static func createDecisionContinuitySourceTables(
        in database: Database
    ) throws {
        try database.create(table: "decisionContinuitySource") { table in
            table.primaryKey("id", .text)
            table.column("decisionID", .text).notNull()
                .references("decisionContinuity", onDelete: .cascade)
            // Source IDs deliberately have no foreign keys: purge must not
            // erase why a user once confirmed this decision.
            table.column("summaryDecisionID", .text).notNull().unique()
            table.column("summaryID", .text).notNull()
            table.column("meetingID", .text).notNull()
            table.column("observedStatement", .text).notNull().check(
                sql: "length(trim(observedStatement)) > 0")
            table.column("sourceTranscriptRevision", .integer).notNull().check(
                sql: "sourceTranscriptRevision >= 0")
            table.column("observedAt", .datetime).notNull()
            table.column("linkedAt", .datetime).notNull().check(
                sql: "linkedAt >= observedAt")
        }
        try database.create(
            index: "decisionContinuitySource_on_decision",
            on: "decisionContinuitySource",
            columns: ["decisionID", "linkedAt", "observedAt", "meetingID", "id"])
        try database.create(
            index: "decisionContinuitySource_on_meeting",
            on: "decisionContinuitySource",
            columns: ["meetingID", "observedAt", "id"])

        try database.create(table: "decisionContinuityEvidenceSegment") { table in
            table.column("sourceID", .text).notNull()
                .references("decisionContinuitySource", onDelete: .cascade)
            // Preserve exact source identity after physical transcript purge.
            table.column("segmentID", .text).notNull()
            table.column("ordinal", .integer).notNull().check(sql: "ordinal >= 0")
            table.primaryKey(["sourceID", "ordinal"])
            table.uniqueKey(["sourceID", "segmentID"])
        }
        try database.create(
            index: "decisionContinuityEvidenceSegment_on_segment",
            on: "decisionContinuityEvidenceSegment",
            columns: ["segmentID"])
    }

    private static func createDecisionContinuityEventTable(
        in database: Database
    ) throws {
        try database.create(table: "decisionContinuityEvent") { table in
            table.primaryKey("id", .text)
            table.column("decisionID", .text).notNull()
                .references("decisionContinuity", onDelete: .cascade)
            table.column("kind", .text).notNull().check(
                sql: "kind IN ('confirm', 'supersede', 'reverse')")
            table.column("sourceID", .text)
                .references("decisionContinuitySource", onDelete: .restrict)
            table.column("relatedDecisionID", .text)
                .references("decisionContinuity", onDelete: .restrict)
            table.column("occurredAt", .datetime).notNull()
            table.check(sql: """
                (kind = 'confirm' AND sourceID IS NOT NULL AND relatedDecisionID IS NULL)
                OR (kind IN ('supersede', 'reverse')
                    AND sourceID IS NULL
                    AND relatedDecisionID IS NOT NULL
                    AND relatedDecisionID <> decisionID)
                """)
        }
        try database.create(
            index: "decisionContinuityEvent_on_history",
            on: "decisionContinuityEvent",
            columns: ["decisionID", "occurredAt", "id"])
        try database.execute(sql: """
            CREATE UNIQUE INDEX decisionContinuityEvent_one_confirm
                ON decisionContinuityEvent(decisionID)
                WHERE kind = 'confirm'
            """)
        try database.execute(sql: """
            CREATE UNIQUE INDEX decisionContinuityEvent_one_terminal
                ON decisionContinuityEvent(decisionID)
                WHERE kind IN ('supersede', 'reverse')
            """)
    }

    private static func createDecisionContinuityImmutabilityTriggers(
        in database: Database
    ) throws {
        try createDecisionProjectionTriggers(in: database)
        try createDecisionHistoryImmutabilityTriggers(in: database)
        try createDecisionEventValidationTriggers(in: database)
    }

    private static func createDecisionProjectionTriggers(
        in database: Database
    ) throws {
        try createTrigger(
            "decisionContinuity_immutable_identity_bu",
            timing: "BEFORE UPDATE OF id, statement, createdAt",
            table: "decisionContinuity",
            body: "SELECT RAISE(ABORT, 'decision identity is immutable');",
            when: valuesChanged(["id", "statement", "createdAt"]),
            in: database)
        try createTrigger(
            "decisionContinuity_projected_transition_bu",
            timing: "BEFORE UPDATE OF status, updatedAt",
            table: "decisionContinuity",
            body: """
                SELECT CASE WHEN NOT (
                    OLD.status = 'confirmed'
                    AND NEW.status IN ('superseded', 'reversed')
                    AND NEW.updatedAt > OLD.updatedAt
                    AND EXISTS (
                        SELECT 1 FROM decisionContinuityEvent
                        WHERE decisionID = OLD.id
                          AND kind = CASE NEW.status
                              WHEN 'superseded' THEN 'supersede'
                              ELSE 'reverse'
                          END
                          AND occurredAt = NEW.updatedAt
                    )
                ) THEN RAISE(ABORT, 'decision projection transition is invalid') END;
                """,
            when: valuesChanged(["status", "updatedAt"]),
            in: database)
    }

    private static func createDecisionHistoryImmutabilityTriggers(
        in database: Database
    ) throws {
        for table in [
            "decisionContinuitySource",
            "decisionContinuityEvidenceSegment",
            "decisionContinuityEvent"
        ] {
            try createTrigger(
                "\(table)_immutable_bu",
                timing: "BEFORE UPDATE",
                table: table,
                body: "SELECT RAISE(ABORT, 'decision history is immutable');",
                in: database)
        }
    }

    private static func createDecisionEventValidationTriggers(
        in database: Database
    ) throws {
        try createTrigger(
            "decisionContinuityEvent_confirm_source_bi",
            timing: "BEFORE INSERT",
            table: "decisionContinuityEvent",
            body: """
                SELECT CASE WHEN NEW.kind = 'confirm' AND NOT EXISTS (
                    SELECT 1
                    FROM decisionContinuitySource AS source
                    JOIN decisionContinuity AS decision
                      ON decision.id = source.decisionID
                    WHERE source.id = NEW.sourceID
                      AND source.decisionID = NEW.decisionID
                      AND source.observedStatement = decision.statement
                      AND source.linkedAt = NEW.occurredAt
                      AND decision.status = 'confirmed'
                      AND decision.createdAt = NEW.occurredAt
                      AND decision.updatedAt = NEW.occurredAt
                      AND decision.deletedAt IS NULL
                ) THEN RAISE(ABORT, 'decision confirmation source is foreign') END;
                """,
            in: database)
        try createTrigger(
            "decisionContinuityEvent_terminal_projection_bi",
            timing: "BEFORE INSERT",
            table: "decisionContinuityEvent",
            body: """
                SELECT CASE WHEN NEW.kind IN ('supersede', 'reverse') AND NOT (
                    EXISTS (
                        SELECT 1 FROM decisionContinuity AS target
                        WHERE target.id = NEW.decisionID
                          AND target.status = 'confirmed'
                          AND target.deletedAt IS NULL
                          AND NEW.occurredAt > target.updatedAt
                    )
                    AND EXISTS (
                        SELECT 1 FROM decisionContinuity AS successor
                        WHERE successor.id = NEW.relatedDecisionID
                          AND successor.status = 'confirmed'
                          AND successor.deletedAt IS NULL
                          AND NEW.occurredAt > successor.updatedAt
                    )
                ) THEN RAISE(ABORT, 'decision relationship is invalid') END;
                """,
            in: database)
    }
}
