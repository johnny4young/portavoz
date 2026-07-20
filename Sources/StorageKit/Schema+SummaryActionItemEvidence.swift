import GRDB

extension StorageSchema {
    static func createSummaryActionItemEvidenceTables(in db: Database) throws {
        try db.create(table: "summaryActionItemEvidence") { t in
            t.primaryKey("id", .text)
            t.column("actionItemID", .text).notNull().unique().indexed()
                .references("actionItem", onDelete: .cascade)
            t.column("sourceTranscriptRevision", .integer).notNull().check(
                sql: "sourceTranscriptRevision >= 0")
            t.column("createdAt", .datetime).notNull()
        }
        try db.create(table: "summaryActionItemEvidenceSegment") { t in
            t.primaryKey("id", .text)
            t.column("evidenceID", .text).notNull().indexed()
                .references("summaryActionItemEvidence", onDelete: .cascade)
            t.column("segmentID", .text)
                .references("segment", onDelete: .setNull)
            t.column("ordinal", .integer).notNull().check(sql: "ordinal >= 0")
            t.column("createdAt", .datetime).notNull()
            t.uniqueKey(["evidenceID", "ordinal"])
            t.uniqueKey(["evidenceID", "segmentID"])
        }
    }
}
