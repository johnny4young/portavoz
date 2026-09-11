import Foundation
import GRDB

extension StorageSchema {
    /// v34 (Q12/D316): a dismissed skill offer stays dismissed.
    ///
    /// The AUTO contract makes `dismissed` terminal from `proposed`, but the
    /// execution tables only begin at confirmation — nothing durable existed
    /// for "the user said no". The offer key is the stable intent identity
    /// (skill + subject), deliberately not the random per-render proposal ID,
    /// so regenerating the banner can never resurrect a dismissed offer.
    static func registerSkillOfferDismissalMigration(
        in migrator: inout DatabaseMigrator
    ) {
        migrator.registerMigration("v34") { database in
            try database.create(table: "skillOfferDismissal") { table in
                table.primaryKey("offerKey", .text)
                table.column("skillID", .text).notNull().check(
                    sql: "length(skillID) BETWEEN 1 AND 80")
                table.column("dismissedAt", .datetime).notNull()
                table.check(sql: "length(offerKey) BETWEEN 1 AND 200")
            }
        }
    }
}
