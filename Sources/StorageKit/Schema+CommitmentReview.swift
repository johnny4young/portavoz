import GRDB

extension StorageSchema {
    static func registerCommitmentReviewMigration(
        in migrator: inout DatabaseMigrator
    ) {
        migrator.registerMigration("v21") { database in
            try database.create(table: "commitmentReviewDecision") { table in
                table.primaryKey("actionItemID", .text)
                    .references("actionItem", onDelete: .cascade)
                table.column("disposition", .text).notNull().check(
                    sql: "disposition IN ('dismissed', 'deferred')")
                table.column("revisitAt", .datetime)
                table.column("createdAt", .datetime).notNull()
                table.column("updatedAt", .datetime).notNull().check(
                    sql: "updatedAt >= createdAt")
                table.column("deletedAt", .datetime).check(
                    sql: "deletedAt IS NULL OR deletedAt >= createdAt")
                table.check(sql: """
                    (deletedAt IS NOT NULL AND revisitAt IS NULL)
                    OR (deletedAt IS NULL
                        AND disposition = 'dismissed'
                        AND revisitAt IS NULL)
                    OR (deletedAt IS NULL
                        AND disposition = 'deferred'
                        AND revisitAt IS NOT NULL
                        AND revisitAt > updatedAt)
                    """)
            }
            try database.create(
                index: "commitmentReviewDecision_on_revisit",
                on: "commitmentReviewDecision",
                columns: ["deletedAt", "disposition", "revisitAt", "updatedAt"])
            try database.execute(sql: """
                CREATE UNIQUE INDEX commitmentSource_unique_actionItem
                ON commitmentSource(actionItemID)
                WHERE actionItemID IS NOT NULL
                """)
        }
    }
}
