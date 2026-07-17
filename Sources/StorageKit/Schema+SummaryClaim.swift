import GRDB

extension StorageSchema {
    static func createSummaryClaimTables(in db: Database) throws {
        try db.create(table: "summaryClaim") { t in
            t.primaryKey("id", .text)
            t.column("summaryID", .text).notNull().indexed()
                .references("summary", onDelete: .cascade)
            t.column("kind", .text).notNull().check(sql: "kind = 'overview'")
            t.column("sourceTranscriptRevision", .integer).notNull().check(
                sql: "sourceTranscriptRevision >= 0")
            t.column("createdAt", .datetime).notNull()
            t.uniqueKey(["summaryID", "kind"])
        }
        try db.create(table: "summaryClaimSegment") { t in
            t.primaryKey("id", .text)
            t.column("claimID", .text).notNull().indexed()
                .references("summaryClaim", onDelete: .cascade)
            t.column("segmentID", .text)
                .references("segment", onDelete: .setNull)
            t.column("ordinal", .integer).notNull().check(sql: "ordinal >= 0")
            t.column("createdAt", .datetime).notNull()
            t.uniqueKey(["claimID", "ordinal"])
            t.uniqueKey(["claimID", "segmentID"])
        }
    }
}
