import Foundation
import GRDB

extension StorageSchema {
    /// v35 (D317): one durable, device-local control plane for skills.
    ///
    /// The singleton pause row and sparse disablement set are content-free.
    /// They live beside the execution authority so the app, CLI, and future
    /// surfaces cannot disagree about whether an effect is allowed to start.
    static func registerSkillControlMigration(
        in migrator: inout DatabaseMigrator
    ) {
        migrator.registerMigration("v35") { database in
            try database.create(table: "skillControl") { table in
                table.primaryKey("id", .integer).check(sql: "id = 1")
                table.column("isPaused", .boolean).notNull().check(
                    sql: "isPaused IN (0, 1)")
                table.column("updatedAt", .datetime).notNull()
            }
            try database.execute(
                sql: "INSERT INTO skillControl (id, isPaused, updatedAt) VALUES (1, 0, ?)",
                arguments: [Date(timeIntervalSince1970: 0)])

            try database.create(table: "skillDisablement") { table in
                table.primaryKey("skillID", .text).check(
                    sql: "length(skillID) BETWEEN 1 AND 80 AND trim(skillID) = skillID")
                table.column("disabledAt", .datetime).notNull()
            }

            // The management pane reads only the newest bounded receipts.
            // This index prevents the LIMIT from hiding a full-table sort as
            // local execution history grows.
            try database.execute(sql: """
                CREATE INDEX skillExecutionState_on_recent
                ON skillExecutionState(updatedAt DESC, proposalID ASC)
                """)
        }
    }
}
