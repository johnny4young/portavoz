import GRDB

extension StorageSchema {
    /// Full-text search over saved dictations. GRDB's triggers keep it in step
    /// with every insert, delivery update, delete and retention purge.
    static func registerDictationSearchMigration(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v55") { db in
            try createDictationSearchIndex(in: db)
        }
    }

    static func createDictationSearchIndex(in db: Database) throws {
        try db.create(virtualTable: "dictationRecordSearch", using: FTS5()) { table in
            table.synchronize(withTable: "dictationRecord")
            table.tokenizer = .unicode61()
            table.column("text")
            table.column("originalText")
        }
        try db.execute(sql: "INSERT INTO dictationRecordSearch(dictationRecordSearch) VALUES ('rebuild')")
    }
}
