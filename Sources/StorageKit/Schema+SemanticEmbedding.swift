import GRDB

extension StorageSchema {
    /// Registers compatibility metadata for the derived semantic vector space.
    /// Legacy vectors have no trustworthy identity, so only derived embedding
    /// state returns to the NULL rebuild cursor.
    static func registerSemanticEmbeddingProfileMigration(
        in migrator: inout DatabaseMigrator
    ) {
        migrator.registerMigration("v17") { db in
            try db.alter(table: "segment") { table in
                table.add(column: "embeddingFingerprint", .text)
            }
            try db.execute(sql: """
                UPDATE segment
                SET embedding = NULL, embeddingFingerprint = NULL
                WHERE embedding IS NOT NULL
                """)
        }
    }
}
