import GRDB

extension StorageSchema {
    /// v45 (D389): exact FTS authority for raw meeting notes. The index may
    /// contain every context-item row so GRDB can own one standard external-
    /// content trigger set, but product reads admit only live `.note` rows.
    /// Existing user notes are backfilled without rewriting source content.
    static func registerContextItemSearchMigration(
        in migrator: inout DatabaseMigrator
    ) {
        migrator.registerMigration("v45") { database in
            try database.create(
                virtualTable: "contextItemSearch",
                using: FTS5()
            ) { table in
                table.synchronize(withTable: "contextItem")
                table.tokenizer = .unicode61()
                table.column("content")
            }
            try database.execute(sql: """
                INSERT INTO contextItemSearch(contextItemSearch)
                VALUES ('rebuild')
                """)
        }
    }
}
