import GRDB
import PortavozCore

extension StorageSchema {
    /// Dictation statistics: their own consent, daily totals per app, and the
    /// recently counted dictation identities that keep a retry from counting twice.
    static func registerDictationStatsMigration(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v58") { db in
            try db.create(table: "dictationStatsPolicy") { table in
                table.primaryKey("id", .integer).check(sql: "id = 1")
                table.column("isEnabled", .boolean).notNull().check(sql: "isEnabled IN (0, 1)")
            }
            try db.execute(sql: "INSERT INTO dictationStatsPolicy (id, isEnabled) VALUES (1, 0)")
            try db.create(table: "dictationStatsDay") { table in
                table.column("day", .text).notNull().check(sql: "length(day) = 10")
                table.column("applicationName", .text).notNull()
                    .check(sql: "length(applicationName) <= \(DictationRecord.maximumLabelLength)")
                table.column("dictations", .integer).notNull().check(sql: "dictations >= 0")
                table.column("words", .integer).notNull().check(sql: "words >= 0")
                table.column("spokenMs", .integer).notNull().check(sql: "spokenMs >= 0")
                table.column("notDelivered", .integer).notNull().check(sql: "notDelivered >= 0")
                table.primaryKey(["day", "applicationName"])
            }
            try db.create(table: "dictationStatsCounted") { table in
                table.primaryKey("dictationID", .text).check(sql: "length(dictationID) = 36")
                table.column("day", .text).notNull()
                table.column("applicationName", .text).notNull()
                table.column("delivered", .boolean).notNull()
                table.column("countedAt", .datetime).notNull()
            }
        }
    }
}
