import GRDB

extension StorageSchema {
    static func createSummaryDecisionEvidenceTables(in db: Database) throws {
        try db.create(table: "summaryDecisionEvidence") { t in
            t.primaryKey("id", .text)
            t.column("summaryID", .text).notNull().indexed()
                .references("summary", onDelete: .cascade)
            t.column("sectionOrdinal", .integer).notNull().check(
                sql: "sectionOrdinal >= 0")
            t.column("bulletOrdinal", .integer).notNull().check(
                sql: "bulletOrdinal >= 0")
            t.column("sourceTranscriptRevision", .integer).notNull().check(
                sql: "sourceTranscriptRevision >= 0")
            t.column("createdAt", .datetime).notNull()
            t.uniqueKey(["summaryID", "sectionOrdinal", "bulletOrdinal"])
        }
        try db.create(table: "summaryDecisionEvidenceSegment") { t in
            t.primaryKey("id", .text)
            t.column("decisionID", .text).notNull().indexed()
                .references("summaryDecisionEvidence", onDelete: .cascade)
            t.column("segmentID", .text)
                .references("segment", onDelete: .setNull)
            t.column("ordinal", .integer).notNull().check(sql: "ordinal >= 0")
            t.column("createdAt", .datetime).notNull()
            t.uniqueKey(["decisionID", "ordinal"])
            t.uniqueKey(["decisionID", "segmentID"])
        }
    }
}
