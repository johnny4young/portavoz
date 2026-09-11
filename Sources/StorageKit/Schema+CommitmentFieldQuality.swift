import GRDB

extension StorageSchema {
    static func registerCommitmentFieldQualityMigration(
        in migrator: inout DatabaseMigrator
    ) {
        migrator.registerMigration("v24") { database in
            try database.create(table: "commitmentFieldPresentation") { table in
                table.primaryKey("id", .text)
                // Deliberately not a foreign key: deleting or regenerating the
                // generated source must not rewrite content-free field history.
                table.column("actionItemID", .text).notNull().unique()
                table.column("language", .text).notNull().check(
                    sql: "language IN ('english', 'spanish', 'mixed', 'other-or-unknown')")
                table.column("suggestedOwnerToken", .text)
                table.column("suggestedDueAt", .datetime)
                table.column("firstPresentedAt", .datetime).notNull()
            }
            try database.create(
                index: "commitmentFieldPresentation_on_firstPresentedAt",
                on: "commitmentFieldPresentation",
                columns: ["firstPresentedAt", "id"])
            try createTrigger(
                "commitmentFieldPresentation_immutable_bu",
                timing: "BEFORE UPDATE",
                table: "commitmentFieldPresentation",
                body: "SELECT RAISE(ABORT, 'commitment field presentation is immutable');",
                in: database)
        }
    }
}
