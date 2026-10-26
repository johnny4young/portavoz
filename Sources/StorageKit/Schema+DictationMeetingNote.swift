import GRDB

extension StorageSchema {
    /// Which meeting note was copied from which dictation. The note itself is an
    /// ordinary meeting note; this local link only records where it came from.
    static func registerDictationMeetingNoteMigration(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v57") { db in
            try db.create(table: "dictationMeetingNote") { table in
                table.column("dictationID", .text).notNull()
                    .references("dictationRecord", onDelete: .cascade)
                table.column("meetingID", .text).notNull()
                    .references("meeting", onDelete: .cascade)
                table.column("contextItemID", .text).notNull().unique()
                    .references("contextItem", onDelete: .cascade)
                table.column("createdAt", .datetime).notNull()
                table.primaryKey(["dictationID", "meetingID"])
            }
        }
    }
}
