import GRDB

extension StorageSchema {
    /// Where listening to each meeting stopped; local to this Mac, never synced.
    static func registerPlaybackPositionMigration(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v63") { db in
            try db.create(table: "meetingPlaybackPosition") { table in
                table.primaryKey("meetingID", .text).references("meeting", onDelete: .cascade)
                table.column("positionSeconds", .double).notNull().check(sql: "positionSeconds >= 0")
                table.column("heardAt", .datetime)
                table.column("updatedAt", .datetime).notNull()
            }
        }
    }
}
