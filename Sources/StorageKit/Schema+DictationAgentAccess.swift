import GRDB

extension StorageSchema {
    /// Consent for local agents (the MCP server) to read the dictation history.
    /// It lives in the database because the server runs in another process.
    static func registerDictationAgentAccessMigration(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v56") { db in
            try db.alter(table: "dictationHistoryPolicy") { table in
                table.add(column: "exposesToAgents", .boolean).notNull().defaults(to: false)
                    .check(sql: "exposesToAgents IN (0, 1)")
            }
        }
    }
}
