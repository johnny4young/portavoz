import GRDB

extension StorageSchema {
    static func registerCaptureReportMigration(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v50") { database in
            try database.alter(table: "meeting") { table in
                // NULL preserves unknown evidence for every existing meeting.
                table.add(column: "captureReport", .blob)
            }
        }
    }
}
