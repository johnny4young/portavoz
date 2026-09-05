import GRDB

extension StorageSchema {
    static func registerCommitmentReminderMigration(
        in migrator: inout DatabaseMigrator
    ) {
        migrator.registerMigration("v23") { database in
            try createCommitmentReminderEventTable(in: database)
            try createCommitmentReminderStateTable(in: database)
            try createCommitmentReminderTriggers(in: database)
        }
    }

    private static func createCommitmentReminderEventTable(
        in database: Database
    ) throws {
        try database.create(table: "commitmentReminderEvent") { table in
            table.primaryKey("id", .text)
            table.column("commitmentID", .text).notNull()
                .references("commitment", onDelete: .cascade)
            table.column("previousEventID", .text).unique()
                .references("commitmentReminderEvent", onDelete: .restrict)
            table.column("kind", .text).notNull().check(
                sql: "kind IN ('schedule', 'present', 'snooze', 'dismiss', 'cancel')")
            table.column("scheduledFor", .datetime)
            table.column("sourceDueAt", .datetime)
            table.column("occurredAt", .datetime).notNull()
            table.check(sql: """
                (kind IN ('schedule', 'snooze')
                    AND scheduledFor IS NOT NULL
                    AND sourceDueAt IS NOT NULL
                    AND scheduledFor > occurredAt)
                OR (kind IN ('present', 'dismiss', 'cancel')
                    AND scheduledFor IS NULL
                    AND sourceDueAt IS NULL)
                """)
            table.uniqueKey(["commitmentID", "id"])
        }
        try database.create(
            index: "commitmentReminderEvent_on_history",
            on: "commitmentReminderEvent",
            columns: ["commitmentID", "occurredAt", "id"])
    }

    private static func createCommitmentReminderStateTable(
        in database: Database
    ) throws {
        try database.create(table: "commitmentReminderState") { table in
            table.primaryKey("commitmentID", .text)
                .references("commitment", onDelete: .cascade)
            table.column("status", .text).notNull().check(
                sql: "status IN ('scheduled', 'presented', 'dismissed', 'cancelled')")
            table.column("latestEventID", .text).notNull().unique()
            table.column("scheduledFor", .datetime)
            table.column("sourceDueAt", .datetime)
            table.column("createdAt", .datetime).notNull()
            table.column("updatedAt", .datetime).notNull().check(
                sql: "updatedAt >= createdAt")
            table.check(sql: """
                (status IN ('scheduled', 'presented')
                    AND scheduledFor IS NOT NULL
                    AND sourceDueAt IS NOT NULL)
                OR (status IN ('dismissed', 'cancelled')
                    AND scheduledFor IS NULL
                    AND sourceDueAt IS NULL)
                """)
            table.foreignKey(
                ["commitmentID", "latestEventID"],
                references: "commitmentReminderEvent",
                columns: ["commitmentID", "id"],
                onDelete: .restrict)
        }
        try database.create(
            index: "commitmentReminderState_on_due",
            on: "commitmentReminderState",
            columns: ["status", "scheduledFor", "commitmentID"])
    }

    private static func createCommitmentReminderTriggers(
        in database: Database
    ) throws {
        try createTrigger(
            "commitmentReminderEvent_immutable_bu",
            timing: "BEFORE UPDATE",
            table: "commitmentReminderEvent",
            body: "SELECT RAISE(ABORT, 'commitment reminder history is immutable');",
            in: database)
        try createTrigger(
            "commitmentReminderEvent_previous_commitment_bi",
            timing: "BEFORE INSERT",
            table: "commitmentReminderEvent",
            body: "SELECT RAISE(ABORT, 'commitment reminder history crossed commitments');",
            when: """
                NEW.previousEventID IS NOT NULL AND NOT EXISTS (
                    SELECT 1 FROM commitmentReminderEvent
                    WHERE id = NEW.previousEventID
                      AND commitmentID = NEW.commitmentID
                )
                """,
            in: database)
        try createTrigger(
            "commitmentReminderState_immutable_identity_bu",
            timing: "BEFORE UPDATE OF commitmentID, createdAt",
            table: "commitmentReminderState",
            body: "SELECT RAISE(ABORT, 'commitment reminder identity is immutable');",
            when: valuesChanged(["commitmentID", "createdAt"]),
            in: database)
        try createTrigger(
            "commitmentReminderState_monotonic_bu",
            timing: "BEFORE UPDATE",
            table: "commitmentReminderState",
            body: "SELECT RAISE(ABORT, 'commitment reminder time moved backwards');",
            when: "NEW.updatedAt < OLD.updatedAt",
            in: database)
    }
}
