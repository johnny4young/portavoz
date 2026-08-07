import GRDB

extension StorageSchema {
    /// v32 — explicitly confirmed decision↔topic authority.
    ///
    /// The memory graph may only check or select topology that authoritative
    /// storage already asserts (D270/D271). `topic → meeting → decision` is
    /// proximity, not aboutness, so the edge the three remaining graph jobs
    /// need gets its own authority: immutable source rows carrying the exact
    /// summary/meeting origin, append-only lifecycle events, and a disposable
    /// projection edge derived from nothing else.
    static func registerDecisionTopicAuthorityMigration(
        in migrator: inout DatabaseMigrator
    ) {
        migrator.registerMigration("v32") { database in
            try createDecisionTopicLinkTable(in: database)
            try createDecisionTopicLinkSourceTable(in: database)
            try createDecisionTopicLinkEventTable(in: database)
            try createDecisionTopicLinkImmutabilityTriggers(in: database)
            try createDecisionTopicGraphEdge(in: database)
        }
    }

    private static func createDecisionTopicLinkTable(
        in database: Database
    ) throws {
        try database.create(table: "decisionTopicLink") { table in
            table.primaryKey("id", .text)
            table.column("decisionID", .text).notNull()
                .references("decisionContinuity", onDelete: .restrict)
            table.column("topicID", .text).notNull()
                .references("topic", onDelete: .restrict)
            table.column("status", .text).notNull().check(
                sql: "status IN ('confirmed', 'retracted')")
            table.column("createdAt", .datetime).notNull()
            table.column("updatedAt", .datetime).notNull().check(
                sql: "updatedAt >= createdAt")
            table.column("deletedAt", .datetime).check(
                sql: "deletedAt IS NULL OR deletedAt >= createdAt")
        }
        // One *active* link per pair. Partial, not absolute: a retracted link
        // is terminal history, and a user who mis-retracted must be able to
        // confirm the same pair again as a new link. Every reader of active
        // links filters on exactly this predicate.
        try database.execute(sql: """
            CREATE UNIQUE INDEX decisionTopicLink_one_active
                ON decisionTopicLink(decisionID, topicID)
                WHERE status = 'confirmed' AND deletedAt IS NULL
            """)
        try database.create(
            index: "decisionTopicLink_on_topic",
            on: "decisionTopicLink",
            columns: ["topicID", "status", "decisionID"])
    }

    private static func createDecisionTopicLinkSourceTable(
        in database: Database
    ) throws {
        try database.create(table: "decisionTopicLinkSource") { table in
            table.primaryKey("id", .text)
            table.column("linkID", .text).notNull().unique()
                .references("decisionTopicLink", onDelete: .cascade)
            // Source IDs deliberately have no foreign keys: purging the
            // summary or meeting must not erase why a user linked this.
            table.column("summaryDecisionID", .text).notNull()
            table.column("summaryID", .text).notNull()
            table.column("meetingID", .text).notNull()
            table.column("observedStatement", .text).notNull().check(
                sql: "length(trim(observedStatement)) > 0")
            table.column("observedTopicLabel", .text).notNull().check(
                sql: "length(trim(observedTopicLabel)) > 0")
            table.column("sourceTranscriptRevision", .integer).notNull().check(
                sql: "sourceTranscriptRevision >= 0")
            table.column("observedAt", .datetime).notNull()
            table.column("linkedAt", .datetime).notNull().check(
                sql: "linkedAt >= observedAt")
        }
        try database.create(
            index: "decisionTopicLinkSource_on_meeting",
            on: "decisionTopicLinkSource",
            columns: ["meetingID", "observedAt", "id"])
    }

    private static func createDecisionTopicLinkEventTable(
        in database: Database
    ) throws {
        try database.create(table: "decisionTopicLinkEvent") { table in
            table.primaryKey("id", .text)
            table.column("linkID", .text).notNull()
                .references("decisionTopicLink", onDelete: .cascade)
            table.column("kind", .text).notNull().check(
                sql: "kind IN ('confirm', 'retract')")
            table.column("sourceID", .text)
                .references("decisionTopicLinkSource", onDelete: .restrict)
            table.column("occurredAt", .datetime).notNull()
            table.check(sql: """
                (kind = 'confirm' AND sourceID IS NOT NULL)
                OR (kind = 'retract' AND sourceID IS NULL)
                """)
        }
        try database.create(
            index: "decisionTopicLinkEvent_on_history",
            on: "decisionTopicLinkEvent",
            columns: ["linkID", "occurredAt", "id"])
        try database.execute(sql: """
            CREATE UNIQUE INDEX decisionTopicLinkEvent_one_confirm
                ON decisionTopicLinkEvent(linkID)
                WHERE kind = 'confirm'
            """)
        try database.execute(sql: """
            CREATE UNIQUE INDEX decisionTopicLinkEvent_one_retract
                ON decisionTopicLinkEvent(linkID)
                WHERE kind = 'retract'
            """)
    }

    private static func createDecisionTopicLinkImmutabilityTriggers(
        in database: Database
    ) throws {
        try createTrigger(
            "decisionTopicLink_immutable_identity_bu",
            timing: "BEFORE UPDATE OF id, decisionID, topicID, createdAt",
            table: "decisionTopicLink",
            body: "SELECT RAISE(ABORT, 'decision-topic link identity is immutable');",
            when: valuesChanged(["id", "decisionID", "topicID", "createdAt"]),
            in: database)
        try createTrigger(
            "decisionTopicLink_projected_transition_bu",
            timing: "BEFORE UPDATE OF status, updatedAt",
            table: "decisionTopicLink",
            body: """
                SELECT CASE WHEN NOT (
                    OLD.status = 'confirmed'
                    AND NEW.status = 'retracted'
                    AND NEW.updatedAt > OLD.updatedAt
                    AND EXISTS (
                        SELECT 1 FROM decisionTopicLinkEvent
                        WHERE linkID = OLD.id
                          AND kind = 'retract'
                          AND occurredAt = NEW.updatedAt
                    )
                ) THEN RAISE(ABORT, 'decision-topic link transition is invalid') END;
                """,
            when: valuesChanged(["status", "updatedAt"]),
            in: database)
        for table in ["decisionTopicLinkSource", "decisionTopicLinkEvent"] {
            try createTrigger(
                "\(table)_immutable_bu",
                timing: "BEFORE UPDATE",
                table: table,
                body: "SELECT RAISE(ABORT, 'decision-topic link history is immutable');",
                in: database)
        }
        // The structural aboutness guarantee, enforced below Swift: a confirm
        // event is legal only over a source that (a) belongs to this link,
        // (b) quotes the decision's own statement, and (c) names a generated
        // observation the decision itself already owns as evidence. Nothing
        // that merely co-occurred in a meeting can satisfy (c).
        try createTrigger(
            "decisionTopicLinkEvent_confirm_source_bi",
            timing: "BEFORE INSERT",
            table: "decisionTopicLinkEvent",
            body: """
                SELECT CASE WHEN NEW.kind = 'confirm' AND NOT EXISTS (
                    SELECT 1
                    FROM decisionTopicLinkSource AS source
                    JOIN decisionTopicLink AS link
                      ON link.id = source.linkID
                    JOIN decisionContinuity AS decision
                      ON decision.id = link.decisionID
                    JOIN topic ON topic.id = link.topicID
                    WHERE source.id = NEW.sourceID
                      AND source.linkID = NEW.linkID
                      AND source.observedStatement = decision.statement
                      AND source.linkedAt = NEW.occurredAt
                      AND link.status = 'confirmed'
                      AND link.createdAt = NEW.occurredAt
                      AND link.updatedAt = NEW.occurredAt
                      AND link.deletedAt IS NULL
                      AND decision.deletedAt IS NULL
                      AND topic.deletedAt IS NULL
                      AND topic.mergedIntoTopicID IS NULL
                      AND EXISTS (
                          SELECT 1 FROM decisionContinuitySource AS owned
                          WHERE owned.summaryDecisionID = source.summaryDecisionID
                            AND owned.decisionID = link.decisionID
                      )
                ) THEN RAISE(ABORT, 'decision-topic confirmation source is foreign') END;
                """,
            in: database)
        try createTrigger(
            "decisionTopicLinkEvent_retract_bi",
            timing: "BEFORE INSERT",
            table: "decisionTopicLinkEvent",
            body: """
                SELECT CASE WHEN NEW.kind = 'retract' AND NOT EXISTS (
                    SELECT 1 FROM decisionTopicLink AS link
                    WHERE link.id = NEW.linkID
                      AND link.status = 'confirmed'
                      AND link.deletedAt IS NULL
                      AND NEW.occurredAt > link.updatedAt
                ) THEN RAISE(ABORT, 'decision-topic retraction target is invalid') END;
                """,
            in: database)
    }

    /// Disposable projection edge, rebuilt from the authority alone. Created in
    /// the same migration so a v32 store can never hold links the graph cannot
    /// see. Empty at migration time — the authority is new — so no invalidation
    /// seeding is needed.
    private static func createDecisionTopicGraphEdge(
        in database: Database
    ) throws {
        try database.create(table: "meetingMemoryGraphDecisionTopic") { table in
            table.column("decisionID", .text).notNull()
                .references("decisionContinuity", onDelete: .cascade)
            table.column("topicID", .text).notNull()
                .references("topic", onDelete: .cascade)
            table.primaryKey(["decisionID", "topicID"])
        }
        try database.create(
            index: "meetingMemoryGraphDecisionTopic_on_topic",
            on: "meetingMemoryGraphDecisionTopic",
            columns: ["topicID", "decisionID"])
        for (suffix, timing, scopes) in [
            ("ai", "AFTER INSERT", """
                SELECT 'decision' AS scopeKind, NEW.decisionID AS scopeID
                UNION ALL SELECT 'topic', NEW.topicID
                """),
            ("au", "AFTER UPDATE OF status, deletedAt", """
                SELECT 'decision' AS scopeKind, NEW.decisionID AS scopeID
                UNION ALL SELECT 'topic', NEW.topicID
                """),
            ("ad", "AFTER DELETE", """
                SELECT 'decision' AS scopeKind, OLD.decisionID AS scopeID
                UNION ALL SELECT 'topic', OLD.topicID
                """)
        ] {
            try createMemoryGraphTrigger(
                "memoryGraphDecisionTopicLink_\(suffix)",
                timing: timing,
                table: "decisionTopicLink",
                scopes: scopes,
                in: database)
        }
    }
}
