import GRDB
import PortavozCore

extension StorageSchema {
    /// The previous occurrence chosen for each occurrence of an upcoming event
    /// (recurring events share their identifier) and a disposable
    /// cache of what each person said in it. Triggers clear the lines when the
    /// source meeting's content changes and drop the choice when it is renamed.
    static func registerMeetingBriefLinesMigration(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v62") { db in
            try db.create(table: "meetingBriefSource") { table in
                table.autoIncrementedPrimaryKey("id")
                table.column("eventID", .text).notNull().check(sql: """
                    length(CAST(eventID AS BLOB)) BETWEEN 1 AND \(UpcomingEvent.maximumIdentifierLength)
                    """)
                table.column("eventStartAt", .datetime).notNull().indexed()
                table.column("sourceMeetingID", .text).notNull().indexed()
                    .references("meeting", onDelete: .cascade)
                table.column("preparedAt", .datetime).notNull()
                // NULL means the lines need a rebuild; a built source may hold none.
                table.column("linesBuiltAt", .datetime)
                table.uniqueKey(["eventID", "eventStartAt"])
            }
            try db.create(table: "meetingBriefLine") { table in
                table.column("sourceID", .integer).notNull()
                    .references("meetingBriefSource", onDelete: .cascade)
                table.column("ordinal", .integer).notNull().check(sql: "ordinal >= 0")
                table.column("speakerID", .text).notNull()
                table.column("kind", .text).notNull()
                    .check(sql: "kind IN ('quote', 'commitment', 'question')")
                table.column("text", .text).notNull().check(sql: "length(trim(text)) > 0")
                table.column("segmentID", .text)
                table.column("time", .double).notNull().check(sql: "time >= 0")
                table.column("status", .text).notNull()
                    .check(sql: "status IN ('said', 'unresolved', 'open', 'closed')")
                table.column("dueAt", .datetime)
                table.primaryKey(["sourceID", "ordinal"])
                table.check(sql: """
                    (kind = 'quote' AND status = 'said')
                    OR (kind = 'commitment' AND status IN ('open', 'closed'))
                    OR (kind = 'question' AND status IN ('unresolved', 'closed'))
                    """)
                table.check(sql: "dueAt IS NULL OR status = 'open'")
            }
            // A rebuild reads one meeting's questions.
            try db.create(
                index: "meetingQuestion_on_sourceMeeting",
                on: "meetingQuestion",
                columns: ["sourceMeetingID"])
            try createMeetingBriefLinesInvalidationTriggers(in: db)
        }
    }

    private static func createMeetingBriefLinesInvalidationTriggers(in db: Database) throws {
        for trigger in meetingBriefLinesInvalidationTriggers() {
            try db.execute(sql: """
                CREATE TRIGGER meetingBriefLine_after_\(trigger.name)
                \(trigger.event)
                BEGIN
                    \(trigger.body)
                END
                """)
        }
    }

    private static func meetingBriefLinesInvalidationTriggers() -> [(name: String, event: String, body: String)] {
        func change(_ table: String, _ columns: [String]) -> String {
            "AFTER UPDATE OF \(columns.joined(separator: ", ")) ON \(table) WHEN \(valuesChanged(columns))"
        }
        // Migrations run with foreign keys off, so the child rows cannot rely on the cascade.
        func sources(_ meetings: String) -> String {
            "SELECT id FROM meetingBriefSource WHERE sourceMeetingID IN (\(meetings))"
        }
        func stale(_ meetings: String) -> String {
            """
            DELETE FROM meetingBriefLine WHERE sourceID IN (\(sources(meetings)));
            UPDATE meetingBriefSource SET linesBuiltAt = NULL
            WHERE linesBuiltAt IS NOT NULL AND sourceMeetingID IN (\(meetings));
            """
        }
        func forget(_ meetings: String) -> String {
            """
            DELETE FROM meetingBriefLine WHERE sourceID IN (\(sources(meetings)));
            DELETE FROM meetingBriefSource WHERE sourceMeetingID IN (\(meetings));
            """
        }
        func stales(_ column: String) -> (new: String, old: String, both: String) {
            (stale("NEW.\(column)"), stale("OLD.\(column)"), stale("OLD.\(column), NEW.\(column)"))
        }
        let own = stales("meetingID")
        let question = stales("sourceMeetingID")
        let commitment = stale(
            "SELECT meetingID FROM commitmentSource WHERE commitmentID = NEW.id AND meetingID IS NOT NULL")
        return [
            ("segment_insert", "AFTER INSERT ON segment", own.new),
            ("segment_delete", "AFTER DELETE ON segment", own.old),
            ("segment_update", change(
                "segment", ["meetingID", "speakerID", "text", "startTime", "endTime", "isFinal", "deletedAt"]),
             own.both),
            ("speaker_insert", "AFTER INSERT ON speaker", own.new),
            ("speaker_delete", "AFTER DELETE ON speaker", own.old),
            ("speaker_update", change(
                "speaker", ["meetingID", "displayName", "isMe", "personID", "deletedAt"]), own.both),
            ("meeting_revision", change("meeting", ["transcriptRevision"]), stale("NEW.id")),
            // The previous occurrence was chosen by title, so the next preparation chooses again.
            ("meeting_identity", change("meeting", ["title", "deletedAt"]), forget("NEW.id")),
            ("correction_insert", "AFTER INSERT ON transcriptCorrection", own.new),
            ("correction_delete", "AFTER DELETE ON transcriptCorrection", own.old),
            ("correction_update", change(
                "transcriptCorrection",
                ["meetingID", "kind", "baseTranscriptRevision", "supersedesCorrectionID", "deletedAt"]),
             own.both),
            ("summary_insert", "AFTER INSERT ON summary", own.new),
            ("summary_delete", "AFTER DELETE ON summary", own.old),
            ("summary_update", change("summary", ["deletedAt"]), own.new),
            ("actionItem_insert", "AFTER INSERT ON actionItem", own.new),
            ("actionItem_delete", "AFTER DELETE ON actionItem", own.old),
            ("actionItem_update", change(
                "actionItem", ["meetingID", "text", "ownerSpeakerID", "isDone", "deletedAt"]), own.both),
            ("question_insert", "AFTER INSERT ON meetingQuestion", question.new),
            ("question_delete", "AFTER DELETE ON meetingQuestion", question.old),
            ("question_update", change(
                "meetingQuestion", ["sourceMeetingID", "status", "deletedAt"]), question.both),
            ("commitment_update", change("commitment", ["status", "dueAt", "deletedAt"]), commitment),
            ("commitmentSource_insert", "AFTER INSERT ON commitmentSource", own.new),
            ("commitmentSource_delete", "AFTER DELETE ON commitmentSource", own.old)
        ]
    }
}
