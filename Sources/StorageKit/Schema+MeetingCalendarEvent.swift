import GRDB
import PortavozCore

extension StorageSchema {
    /// The calendar event a recording was started from. Its identifier is local
    /// to this Mac, so the column stays out of `MeetingRecord`: never synced or
    /// exported, and a full-row meeting write cannot clear it.
    static func registerMeetingCalendarEventMigration(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v65") { db in
            try db.alter(table: "meeting") { table in
                table.add(column: "calendarEventID", .text).check(sql: """
                    calendarEventID IS NULL OR length(CAST(calendarEventID AS BLOB)) BETWEEN 1 AND \
                    \(UpcomingEvent.maximumIdentifierLength)
                    """)
            }
            try db.execute(sql: """
                CREATE INDEX meeting_on_calendarEventID ON meeting(calendarEventID, startedAt DESC, id)
                WHERE calendarEventID IS NOT NULL AND deletedAt IS NULL
                """)
            // A source chosen by the event's identifier survives a rename.
            try db.execute(sql: """
                DROP TRIGGER meetingBriefLine_after_meeting_identity;
                CREATE TRIGGER meetingBriefLine_after_meeting_tombstone
                AFTER UPDATE OF deletedAt ON meeting WHEN OLD.deletedAt IS NOT NEW.deletedAt
                BEGIN
                    DELETE FROM meetingBriefLine WHERE sourceID IN (
                        SELECT id FROM meetingBriefSource WHERE sourceMeetingID = NEW.id);
                    DELETE FROM meetingBriefSource WHERE sourceMeetingID = NEW.id;
                END;
                CREATE TRIGGER meetingBriefLine_after_meeting_title
                AFTER UPDATE OF title ON meeting WHEN OLD.title IS NOT NEW.title
                BEGIN
                    DELETE FROM meetingBriefLine WHERE sourceID IN (
                        SELECT id FROM meetingBriefSource
                        WHERE sourceMeetingID = NEW.id AND eventID IS NOT NEW.calendarEventID);
                    DELETE FROM meetingBriefSource
                    WHERE sourceMeetingID = NEW.id AND eventID IS NOT NEW.calendarEventID;
                END;
                """)
        }
    }
}
