import GRDB

extension StorageSchema {
    static func createCompanionCardEvidenceTables(in db: Database) throws {
        try db.create(table: "companionCardEvidence") { t in
            t.primaryKey("id", .text)
            t.column("cardID", .text).notNull().unique().indexed()
                .references("companionCard", onDelete: .cascade)
            t.column("sourceTranscriptRevision", .integer).notNull().check(
                sql: "sourceTranscriptRevision >= 0")
            t.column("createdAt", .datetime).notNull()
        }
        try db.create(table: "companionCardEvidenceSegment") { t in
            t.primaryKey("id", .text)
            t.column("evidenceID", .text).notNull().indexed()
                .references("companionCardEvidence", onDelete: .cascade)
            t.column("role", .text).notNull().check(
                sql: "role IN ('question', 'answer')")
            t.column("segmentID", .text)
                .references("segment", onDelete: .setNull)
            t.column("ordinal", .integer).notNull().check(sql: "ordinal >= 0")
            t.column("createdAt", .datetime).notNull()
            t.uniqueKey(["evidenceID", "role", "ordinal"])
            t.uniqueKey(["evidenceID", "role", "segmentID"])
        }
    }
}
