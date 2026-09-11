import GRDB

extension StorageSchema {
    /// Registers the stable newest-first keyset index shared by bounded
    /// library projections and whole-library backup staging.
    static func registerLiveMeetingOrderingMigration(
        in migrator: inout DatabaseMigrator
    ) {
        migrator.registerMigration("v16") { db in
            try db.execute(sql: """
                CREATE INDEX meeting_on_live_startedAt_id
                ON meeting(startedAt DESC, id ASC)
                WHERE deletedAt IS NULL
                """)
        }
    }
}
