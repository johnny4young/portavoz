import Foundation
import GRDB
import PortavozCore

extension StorageSchema {
    /// v33 (T28b/D313): the searchable projection of active `replaceText`
    /// corrections — one row per segment, so citation identity never changes.
    ///
    /// This is a disposable projection over the immutable correction tables:
    /// every correction write rebuilds the affected meeting's rows in the
    /// same transaction, and the correction-search refresh can rebuild it
    /// from history at any time. The FTS mirror is maintained by
    /// GRDB-generated triggers, exactly like v1's `segmentSearch`.
    static func registerSegmentCorrectedTextMigration(
        in migrator: inout DatabaseMigrator
    ) {
        migrator.registerMigration("v33") { database in
            try database.create(table: "segmentCorrectedText") { table in
                table.primaryKey("segmentID", .text)
                    .references("segment", onDelete: .cascade)
                table.column("meetingID", .text).notNull().indexed()
                    .references("meeting", onDelete: .cascade)
                table.column("correctionID", .text).notNull().unique()
                    .references("transcriptCorrection", onDelete: .cascade)
                table.column("baseTranscriptRevision", .integer).notNull()
                    .check(sql: "baseTranscriptRevision >= 0")
                table.column("text", .text).notNull()
                    .check(sql: "length(trim(text)) > 0")
                table.column("language", .text)
                    .check(sql: "language IS NULL OR length(trim(language)) > 0")
                table.column("updatedAt", .datetime).notNull()
            }
            try database.create(
                virtualTable: "segmentCorrectedSearch",
                using: FTS5()
            ) { table in
                table.synchronize(withTable: "segmentCorrectedText")
                table.tokenizer = .unicode61()
                table.column("text")
            }

            // Libraries corrected before v33 must find their corrected text
            // without waiting for the next correction write.
            let meetingKeys = try String.fetchAll(
                database,
                sql: "SELECT DISTINCT meetingID FROM transcriptCorrection")
            for key in meetingKeys {
                guard let uuid = UUID(uuidString: key) else { continue }
                try MeetingStore.refreshTranscriptCorrectionSearchProjection(
                    meetingID: MeetingID(rawValue: uuid),
                    in: database)
            }
        }
    }

    /// v37 (D330): a device-local semantic vector for the current corrected
    /// text lane. Accepted vectors remain on `segment`, so restore can expose
    /// the immutable accepted representation without rebuilding it.
    static func registerSegmentCorrectedEmbeddingMigration(
        in migrator: inout DatabaseMigrator
    ) {
        migrator.registerMigration("v37") { database in
            try database.alter(table: "segmentCorrectedText") { table in
                table.add(column: "embedding", .blob)
                table.add(column: "embeddingFingerprint", .text)
            }
        }
    }

    /// v38: cardinality-changing transcript corrections receive a disposable
    /// search identity without impersonating accepted segments. Source rows
    /// preserve ordered accepted provenance for every split part and merge.
    static func registerTranscriptStructuralSearchMigration(
        in migrator: inout DatabaseMigrator
    ) {
        migrator.registerMigration("v38") { database in
            try database.create(table: "transcriptStructuralSearchRow") { table in
                table.primaryKey("resultID", .text)
                table.column("meetingID", .text).notNull().indexed()
                    .references("meeting", onDelete: .cascade)
                table.column("correctionID", .text).notNull().indexed()
                    .references("transcriptCorrection", onDelete: .cascade)
                table.column("baseTranscriptRevision", .integer).notNull()
                    .check(sql: "baseTranscriptRevision >= 0")
                table.column("kind", .text).notNull()
                    .check(sql: "kind IN ('split', 'merge')")
                table.column("text", .text).notNull()
                    .check(sql: "length(trim(text)) > 0")
                table.column("language", .text)
                    .check(sql: "language IS NULL OR length(trim(language)) > 0")
                table.column("startTime", .double).notNull()
                    .check(sql: "startTime >= 0")
                table.column("endTime", .double).notNull()
                    .check(sql: "endTime > startTime")
                table.column("updatedAt", .datetime).notNull()
                table.column("embedding", .blob)
                table.column("embeddingFingerprint", .text)
            }
            try database.create(table: "transcriptStructuralSearchSource") { table in
                table.column("resultID", .text).notNull()
                    .references("transcriptStructuralSearchRow", onDelete: .cascade)
                table.column("ordinal", .integer).notNull()
                    .check(sql: "ordinal >= 0")
                table.column("segmentID", .text).notNull().indexed()
                    .references("segment", onDelete: .cascade)
                table.primaryKey(["resultID", "ordinal"])
                table.uniqueKey(["resultID", "segmentID"])
            }
            try database.create(
                virtualTable: "transcriptStructuralSearch",
                using: FTS5()
            ) { table in
                table.synchronize(withTable: "transcriptStructuralSearchRow")
                table.tokenizer = .unicode61()
                table.column("text")
            }

            let meetingKeys = try String.fetchAll(
                database,
                sql: "SELECT DISTINCT meetingID FROM transcriptCorrection")
            for key in meetingKeys {
                guard let uuid = UUID(uuidString: key) else { continue }
                try MeetingStore.refreshTranscriptCorrectionSearchProjection(
                    meetingID: MeetingID(rawValue: uuid),
                    in: database)
            }
        }
    }
}
