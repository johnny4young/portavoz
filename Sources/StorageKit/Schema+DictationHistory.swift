import GRDB
import PortavozCore

extension StorageSchema {
    /// Private dictation history: one consent row and the saved dictations.
    /// No audio, window titles or surrounding text are stored.
    static func registerDictationHistoryMigration(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v54") { db in
            try db.create(table: "dictationHistoryPolicy") { table in
                table.primaryKey("id", .integer).check(sql: "id = 1")
                table.column("isEnabled", .boolean).notNull().check(sql: "isEnabled IN (0, 1)")
                table.column("keepsOriginal", .boolean).notNull().check(sql: "keepsOriginal IN (0, 1)")
                table.column("retentionDays", .integer).notNull().check(sql: "retentionDays IN (7, 30, 90)")
                table.column("generation", .integer).notNull().check(sql: "generation >= 0")
            }
            try db.execute(sql: """
                INSERT INTO dictationHistoryPolicy (id, isEnabled, keepsOriginal, retentionDays, generation)
                VALUES (1, 0, 0, 30, 0)
                """)
            let label = DictationRecord.maximumLabelLength
            try db.create(table: "dictationRecord") { table in
                table.primaryKey("id", .text).check(sql: "length(id) = 36")
                table.column("createdAt", .datetime).notNull()
                table.column("durationMs", .integer).notNull().check(sql: "durationMs >= 0")
                table.column("text", .text).notNull().check(
                    sql: "length(trim(text)) > 0 AND length(text) <= \(DictationRecord.maximumTextLength)")
                table.column("originalText", .text).check(
                    sql: "originalText IS NULL OR length(originalText) <= \(DictationRecord.maximumTextLength)")
                table.column("mode", .text).notNull().check(sql: "mode IN ('literal', 'clean')")
                table.column("language", .text).check(sql: "language IS NULL OR language IN ('es', 'en')")
                table.column("engine", .text).notNull().check(sql: "length(engine) BETWEEN 1 AND \(label)")
                table.column("applicationName", .text).check(
                    sql: "applicationName IS NULL OR length(applicationName) <= \(label)")
                table.column("applicationBundleID", .text).check(
                    sql: "applicationBundleID IS NULL OR length(applicationBundleID) <= \(label)")
                table.column("delivery", .text).notNull().check(
                    sql: "delivery IN ('verified', 'dispatched', 'not-delivered')")
            }
            try db.create(
                index: "dictationRecord_on_createdAt_id", on: "dictationRecord",
                columns: ["createdAt", "id"])
        }
    }
}
