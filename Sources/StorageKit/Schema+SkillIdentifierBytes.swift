import Foundation
import GRDB

extension StorageSchema {
    /// v51: the skill disablement set bounds `skillID` in UTF-8 bytes.
    ///
    /// `SkillDefinition.maximumIDByteCount` is a byte limit, and every other
    /// durable skill table (v40 dismissal/proposal, execution authority)
    /// checks `length(CAST(skillID AS BLOB))`. The v35 disablement table
    /// still checked `length(skillID)`, which SQLite counts in characters, so
    /// a multibyte identifier could be persisted here while being invalid in
    /// the rest of the Skill domain. SQLite cannot rewrite a CHECK in place;
    /// the table is rebuilt with its rows preserved. Existing rows already
    /// satisfy the tighter bound because every writer validated bytes first.
    static func registerSkillIdentifierByteBoundMigration(
        in migrator: inout DatabaseMigrator
    ) {
        migrator.registerMigration("v51") { database in
            try database.rename(table: "skillDisablement", to: "skillDisablement_v35")
            try database.create(table: "skillDisablement") { table in
                table.primaryKey("skillID", .text).check(sql: """
                    length(CAST(skillID AS BLOB)) BETWEEN 1 AND 80 \
                    AND trim(skillID) = skillID
                    """)
                table.column("disabledAt", .datetime).notNull()
            }
            try database.execute(sql: """
                INSERT INTO skillDisablement (skillID, disabledAt)
                SELECT skillID, disabledAt FROM skillDisablement_v35
                """)
            try database.drop(table: "skillDisablement_v35")
        }
    }
}
