import GRDB

extension StorageSchema {
    /// Durable confirmed skill execution (D293).
    ///
    /// Two tables in the shape the reminder lifecycle already established: an
    /// append-only event log that is the authority, and one current projection
    /// derived from it. The projection exists so a relaunch can answer "did
    /// this already run?" in one read without replaying history.
    static func registerSkillExecutionMigration(
        in migrator: inout DatabaseMigrator
    ) {
        migrator.registerMigration("v31") { database in
            try createSkillExecutionEventTable(in: database)
            try createSkillExecutionStateTable(in: database)
        }
    }

    private static func createSkillExecutionEventTable(
        in database: Database
    ) throws {
        try database.create(table: "skillExecutionEvent") { table in
            table.primaryKey("id", .text)
            table.column("proposalID", .text).notNull()
            // Chains each event to its predecessor so concurrent writers cannot
            // interleave a second history for one proposal.
            table.column("previousEventID", .text).unique()
                .references("skillExecutionEvent", onDelete: .restrict)
            table.column("kind", .text).notNull().check(
                sql: """
                    kind IN ('confirm', 'begin', 'succeed', 'fail', 'cancel')
                    """)
            table.column("attempt", .integer).notNull().check(
                sql: "attempt >= 1")
            // Content-free: the failure category, never the failure text, and
            // never anything derived from meeting material.
            table.column("failureCategory", .text)
            table.column("occurredAt", .datetime).notNull()
            table.check(sql: """
                (kind = 'fail' AND failureCategory IS NOT NULL)
                OR (kind <> 'fail' AND failureCategory IS NULL)
                """)
            table.uniqueKey(["proposalID", "id"])
            // One attempt produces at most one of each transition, so a
            // duplicated write is rejected by the database rather than by
            // hoping the caller checked first.
            table.uniqueKey(["proposalID", "attempt", "kind"])
        }
        try database.create(
            index: "skillExecutionEvent_on_history",
            on: "skillExecutionEvent",
            columns: ["proposalID", "occurredAt", "id"])
        // The history read orders by rowid, which needs no index: SQLite walks
        // the table in rowid order natively.
    }

    private static func createSkillExecutionStateTable(
        in database: Database
    ) throws {
        try database.create(table: "skillExecutionState") { table in
            table.primaryKey("proposalID", .text)
            table.column("skillID", .text).notNull().check(
                sql: "length(trim(skillID)) > 0")
            table.column("skillVersion", .integer).notNull().check(
                sql: "skillVersion >= 1")
            // The idempotency key is what makes a retry safe. It is unique
            // across the table, so two proposals can never claim one effect.
            table.column("idempotencyKey", .text).notNull().unique().check(
                sql: "length(trim(idempotencyKey)) > 0")
            table.column("state", .text).notNull().check(
                sql: """
                    state IN ('confirmed', 'executing', 'succeeded',
                              'failed', 'cancelled')
                    """)
            table.column("attempt", .integer).notNull().check(
                sql: "attempt >= 1")
            table.column("latestEventID", .text).notNull().unique()
                .references("skillExecutionEvent", onDelete: .restrict)
            table.column("createdAt", .datetime).notNull()
            table.column("updatedAt", .datetime).notNull().check(
                sql: "updatedAt >= createdAt")
            table.foreignKey(
                ["proposalID", "latestEventID"],
                references: "skillExecutionEvent",
                columns: ["proposalID", "id"],
                onDelete: .restrict)
        }
        try database.create(
            index: "skillExecutionState_on_pending",
            on: "skillExecutionState",
            columns: ["state", "updatedAt"])
    }
}
