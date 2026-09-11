import Foundation
import GRDB

extension StorageSchema {
    /// Tighten new identities without rejecting or discarding historical denials.
    /// The old writer admitted 80 characters, so a table-copy byte CHECK can
    /// prevent the entire library from opening. Keep those rows in place;
    /// only new inserts and identifier changes acquire the byte constraint.
    static func registerSkillIdentifierByteBoundMigration(
        in migrator: inout DatabaseMigrator
    ) {
        migrator.registerMigration("v51") { database in
            for (suffix, event) in [("insert", "INSERT"), ("update", "UPDATE OF skillID")] {
                try database.execute(sql: """
                    CREATE TRIGGER skillDisablement_byte_bound_\(suffix)
                    BEFORE \(event) ON skillDisablement
                    WHEN length(CAST(NEW.skillID AS BLOB)) NOT BETWEEN 1 AND 80
                    BEGIN
                        SELECT RAISE(ABORT, 'skillID exceeds its UTF-8 byte bound');
                    END
                    """)
            }
        }
    }
}
