import GRDB
import PortavozCore

extension StorageSchema {
    /// A translated reading of a meeting transcript, one per target language. Only
    /// translated rows are stored; the original transcript is never rewritten.
    static func registerTranscriptTranslationMigration(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v60") { db in
            try db.create(table: "transcriptTranslation") { table in
                table.column("meetingID", .text).notNull().references("meeting", onDelete: .cascade)
                table.column("targetLanguage", .text).notNull().check(sql: "targetLanguage IN ('en', 'es')")
                table.column("sourceTranscriptRevision", .integer).notNull()
                    .check(sql: "sourceTranscriptRevision >= 0")
                table.column("sourceCorrectionRevision", .text).notNull()
                    .check(sql: "sourceCorrectionRevision = 'accepted' OR length(sourceCorrectionRevision) = 64")
                table.column("createdAt", .datetime).notNull()
                table.primaryKey(["meetingID", "targetLanguage"])
            }
            try db.create(table: "transcriptTranslationLine") { table in
                table.column("meetingID", .text).notNull()
                table.column("targetLanguage", .text).notNull()
                table.column("rowID", .text).notNull().check(sql: "length(rowID) = 36")
                table.column("text", .text).notNull().check(
                    sql: "length(trim(text)) > 0 AND length(text) <= \(TranscriptTranslation.maximumLineLength)")
                table.primaryKey(["meetingID", "targetLanguage", "rowID"])
                table.foreignKey(
                    ["meetingID", "targetLanguage"], references: "transcriptTranslation",
                    columns: ["meetingID", "targetLanguage"], onDelete: .cascade)
            }
        }
    }
}
