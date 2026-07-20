import GRDB

extension StorageSchema {
    static func createSummaryClaimFeedbackTable(in db: Database) throws {
        let whitespace = "char(9) || char(10) || char(11) || char(12) || char(13) || ' '"
        try db.create(table: "summaryClaimFeedback") { t in
            t.primaryKey("claimID", .text)
                .references("summaryClaim", onDelete: .cascade)
            t.column("kind", .text).notNull().check(
                sql: "kind IN ('correction', 'unsupported')")
            t.column("correctionText", .text)
            t.column("createdAt", .datetime).notNull()
            t.column("updatedAt", .datetime).notNull()
            t.column("deletedAt", .datetime)
            t.check(sql: "(deletedAt IS NOT NULL AND correctionText IS NULL) OR "
                + "(deletedAt IS NULL AND kind = 'unsupported' AND correctionText IS NULL) OR "
                + "(deletedAt IS NULL AND kind = 'correction' "
                + "AND length(trim(correctionText, \(whitespace))) BETWEEN 1 AND 2000)")
        }
    }
}
