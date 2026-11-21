import GRDB
import PortavozCore

extension StorageSchema {
    /// A disposable per-meeting cache of who spoke when. Triggers drop a
    /// meeting's row whenever its attribution or audio length changes, and
    /// the next read rebuilds it from segments, so it never needs a backfill.
    static func registerVoiceColumnsMigration(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v61") { db in
            try db.create(table: "meetingVoiceColumns") { table in
                table.primaryKey("meetingID", .text).references("meeting", onDelete: .cascade)
                table.column("duration", .double).notNull().check(sql: "duration >= 0")
                table.column("columns", .blob).notNull()
                    .check(sql: "length(columns) <= \(VoiceColumns.maximumCount)")
                table.column("updatedAt", .datetime).notNull()
            }
            try db.create(table: "meetingVoiceColumnsVoice") { table in
                table.column("meetingID", .text).notNull()
                    .references("meetingVoiceColumns", column: "meetingID", onDelete: .cascade)
                table.column("voiceIndex", .integer).notNull()
                    .check(sql: "voiceIndex >= 0 AND voiceIndex < \(VoiceColumns.maximumVoices)")
                table.column("speakerID", .text).notNull()
                table.column("talkSeconds", .double).notNull().check(sql: "talkSeconds >= 0")
                table.column("firstHeard", .double).notNull().check(sql: "firstHeard >= 0")
                table.primaryKey(["meetingID", "voiceIndex"])
            }
            try createVoiceColumnsInvalidationTriggers(in: db)
        }
    }

    private static func createVoiceColumnsInvalidationTriggers(in db: Database) throws {
        func change(_ table: String, _ columns: [String]) -> String {
            "AFTER UPDATE OF \(columns.joined(separator: ", ")) ON \(table) WHEN \(valuesChanged(columns))"
        }
        // Migrations run with foreign keys off, so the child rows cannot rely on the cascade.
        func drop(_ meetings: String) -> String {
            ["meetingVoiceColumnsVoice", "meetingVoiceColumns"]
                .map { "DELETE FROM \($0) WHERE meetingID IN (\(meetings));" }
                .joined(separator: "\n")
        }
        let new = drop("NEW.meetingID")
        let old = drop("OLD.meetingID")
        let both = drop("OLD.meetingID, NEW.meetingID")
        let triggers: [(name: String, event: String, body: String)] = [
            ("segment_insert", "AFTER INSERT ON segment", new),
            ("segment_delete", "AFTER DELETE ON segment", old),
            ("segment_update", change(
                "segment", ["meetingID", "speakerID", "startTime", "endTime", "isFinal", "deletedAt"]), both),
            ("speaker_insert", "AFTER INSERT ON speaker", new),
            ("speaker_update", change("speaker", ["meetingID", "deletedAt"]), both),
            ("speaker_delete", "AFTER DELETE ON speaker", old),
            ("meeting_revision", change("meeting", ["transcriptRevision"]),
             drop("NEW.id")),
            ("correction_insert", "AFTER INSERT ON transcriptCorrection", new),
            ("correction_delete", "AFTER DELETE ON transcriptCorrection", old),
            ("correction_update", change(
                "transcriptCorrection",
                ["meetingID", "kind", "baseTranscriptRevision", "supersedesCorrectionID", "deletedAt"]), both),
            ("audio_insert", "AFTER INSERT ON audioAsset", new),
            ("audio_delete", "AFTER DELETE ON audioAsset", old),
            ("audio_update", change(
                "audioAsset", ["meetingID", "durationSeconds", "supersededAt", "deletedAt"]), both)
        ]
        for trigger in triggers {
            try db.execute(sql: """
                CREATE TRIGGER meetingVoiceColumns_after_\(trigger.name)
                \(trigger.event)
                BEGIN
                    \(trigger.body)
                END
                """)
        }
    }
}
