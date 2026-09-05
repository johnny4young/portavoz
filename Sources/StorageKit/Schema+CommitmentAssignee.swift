import GRDB

extension StorageSchema {
    static func registerCommitmentAssigneeMigration(
        in migrator: inout DatabaseMigrator
    ) {
        migrator.registerMigration("v22") { database in
            try database.alter(table: "commitment") { table in
                table.add(column: "assigneeKind", .text)
                    .notNull()
                    .defaults(to: "unassigned")
            }
            try database.execute(sql: """
                UPDATE commitment
                SET assigneeKind = 'person'
                WHERE canonicalPersonID IS NOT NULL
                """)

            try database.alter(table: "commitmentEvent") { table in
                table.add(column: "assigneeKind", .text)
            }
            // v20 makes event history immutable at runtime. This migration is
            // the one controlled rewrite that types the legacy owner payload;
            // restore the guard before any application write can run.
            try database.execute(sql: "DROP TRIGGER commitmentEvent_immutable_bu")
            try database.execute(sql: """
                UPDATE commitmentEvent
                SET assigneeKind = CASE
                    WHEN canonicalPersonID IS NULL THEN 'unassigned'
                    ELSE 'person'
                END
                WHERE kind IN ('confirm', 'reassign')
                """)
            try createTrigger(
                "commitmentEvent_immutable_bu",
                timing: "BEFORE UPDATE",
                table: "commitmentEvent",
                body: "SELECT RAISE(ABORT, 'commitment history is immutable');",
                in: database)

            try database.create(
                index: "commitment_on_assignee_status",
                on: "commitment",
                columns: [
                    "assigneeKind", "canonicalPersonID", "deletedAt", "status", "dueAt"
                ])
            try createCommitmentAssigneeTriggers(in: database)
        }
    }

    private static func createCommitmentAssigneeTriggers(
        in database: Database
    ) throws {
        let commitmentIsInvalid = """
            NOT (
                (NEW.assigneeKind = 'person' AND NEW.canonicalPersonID IS NOT NULL)
                OR (NEW.assigneeKind IN ('me', 'unassigned')
                    AND NEW.canonicalPersonID IS NULL)
            )
            """
        try createTrigger(
            "commitment_assignee_valid_bi",
            timing: "BEFORE INSERT",
            table: "commitment",
            body: "SELECT RAISE(ABORT, 'invalid commitment assignee');",
            when: commitmentIsInvalid,
            in: database)
        try createTrigger(
            "commitment_assignee_valid_bu",
            timing: "BEFORE UPDATE OF assigneeKind, canonicalPersonID",
            table: "commitment",
            body: "SELECT RAISE(ABORT, 'invalid commitment assignee');",
            when: commitmentIsInvalid,
            in: database)

        let eventIsInvalid = """
            NOT (
                (NEW.kind IN ('confirm', 'reassign') AND (
                    (NEW.assigneeKind = 'person' AND NEW.canonicalPersonID IS NOT NULL)
                    OR (NEW.assigneeKind IN ('me', 'unassigned')
                        AND NEW.canonicalPersonID IS NULL)
                ))
                OR (NEW.kind NOT IN ('confirm', 'reassign')
                    AND NEW.assigneeKind IS NULL
                    AND NEW.canonicalPersonID IS NULL)
            )
            """
        try createTrigger(
            "commitmentEvent_assignee_valid_bi",
            timing: "BEFORE INSERT",
            table: "commitmentEvent",
            body: "SELECT RAISE(ABORT, 'invalid commitment event assignee');",
            when: eventIsInvalid,
            in: database)
    }
}
