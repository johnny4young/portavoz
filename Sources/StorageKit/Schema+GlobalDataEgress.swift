import GRDB

extension StorageSchema {
    /// v43 (D385): content-free receipts for cross-library operations that
    /// cannot honestly be attributed to one meeting. The first admitted
    /// operation is local manual Ask; its narrow checks prevent this table
    /// from becoming a generic bypass around meeting-owned receipts.
    static func registerGlobalDataEgressMigration(
        in migrator: inout DatabaseMigrator
    ) {
        migrator.registerMigration("v43") { database in
            try database.create(table: "globalDataEgressEvent") { table in
                table.primaryKey("id", .text)
                table.column("operation", .text).notNull().check(
                    sql: "operation = 'ask-answer-generation'")
                table.column("destinationScope", .text).notNull().check(
                    sql: "destinationScope = 'local-device'")
                table.column("destinationHost", .text).notNull().check(
                    sql: "length(trim(destinationHost)) > 0")
                table.column("dataClassification", .text).notNull().check(
                    sql: "dataClassification = 'meeting-answer-material'")
                table.column("consentSource", .text).notNull().check(
                    sql: "consentSource = 'summary-engine-settings'")
                table.column("providerID", .text).notNull().check(
                    sql: "length(trim(providerID)) > 0")
                table.column("modelID", .text).notNull().check(
                    sql: "length(trim(modelID)) > 0")
                table.column("attemptedAt", .datetime).notNull()
            }
            try database.create(
                index: "globalDataEgressEvent_on_attemptedAt",
                on: "globalDataEgressEvent",
                columns: ["attemptedAt"])
        }
    }
}
