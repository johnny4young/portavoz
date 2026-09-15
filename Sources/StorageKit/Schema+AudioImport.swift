import GRDB

extension StorageSchema {
    static func registerAudioImportMigration(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v52") { db in
            try db.create(
                index: "processingJob_on_importOwner", on: "processingJob",
                columns: ["id", "meetingID"], unique: true)
            try db.create(table: "audioImportInput") { table in
                table.primaryKey("meetingID", .text).references("meeting", onDelete: .cascade)
                table.column("jobID", .text).notNull().unique()
                table.column("inputFingerprint", .text).notNull()
                table.column("payloadDigest", .text).notNull()
                table.column("payload", .blob).notNull().check(sql: "length(payload) <= 1048576")
                table.foreignKey(
                    ["jobID", "meetingID"], references: "processingJob",
                    columns: ["id", "meetingID"], onDelete: .cascade)
            }
        }
    }
}
