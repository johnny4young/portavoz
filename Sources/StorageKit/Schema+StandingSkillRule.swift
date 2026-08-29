import GRDB
import PortavozCore

extension StorageSchema {
    /// v46 (D435): device-local, content-free authority for user-authored
    /// standing rules. Execution history remains in the existing immutable
    /// Skill receipt tables and therefore survives rule deletion.
    static func registerStandingSkillRuleMigration(
        in migrator: inout DatabaseMigrator
    ) {
        migrator.registerMigration("v46") { database in
            try database.create(table: "standingSkillRule") { table in
                table.primaryKey("id", .text).check(
                    sql: "length(id) = 36")
                table.column("skillID", .text).notNull().check(sql: """
                    length(CAST(skillID AS BLOB)) BETWEEN 1 AND
                        \(SkillDefinition.maximumIDByteCount)
                    AND trim(skillID) = skillID
                    """)
                table.column("skillVersion", .integer).notNull().check(
                    sql: "skillVersion >= 1")
                table.column("trigger", .text).notNull().check(sql: """
                    trigger = 'upcoming-calendar-event'
                    """)
                table.column("subjectPredicate", .text).notNull().check(sql: """
                    subjectPredicate = 'any-upcoming-calendar-event'
                    """)
                table.column("action", .text).notNull().check(sql: """
                    action = 'prepare-pre-meeting-brief'
                    """)
                table.column("maximumDailyExecutions", .integer)
                    .notNull().check(sql: """
                        maximumDailyExecutions BETWEEN 1 AND
                            \(StandingSkillRule.maximumDailyExecutionCount)
                        """)
                table.column("isEnabled", .boolean).notNull().check(
                    sql: "isEnabled IN (0, 1)")
                table.column("createdAt", .datetime).notNull()
                table.column("updatedAt", .datetime).notNull()
                table.uniqueKey(["trigger", "subjectPredicate", "action"])
            }
        }
    }
}
