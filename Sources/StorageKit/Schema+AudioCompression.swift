import GRDB

extension StorageSchema {
    static func registerAudioCompressionDirectoryMigration(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v53") { db in
            // Duplicate directory owners remain valid persisted evidence and
            // must be rejected by admission rather than by the migration.
            try db.create(
                index: "meeting_on_audioDirectory", on: "meeting",
                columns: ["audioDirectory"], unique: false)
        }
    }
}
