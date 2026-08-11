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
}
