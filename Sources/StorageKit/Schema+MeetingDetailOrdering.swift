import GRDB

extension StorageSchema {
    /// v49: serve the live Meeting Detail transcript in its canonical order
    /// directly from SQLite instead of sorting the entire meeting in a
    /// temporary B-tree on every observation refresh.
    static func registerMeetingDetailOrderingMigration(
        in migrator: inout DatabaseMigrator
    ) {
        migrator.registerMigration("v49") { database in
            try database.execute(sql: """
                CREATE INDEX segment_on_live_meeting_order
                ON segment(meetingID, startTime, id)
                WHERE deletedAt IS NULL
                """)
        }
    }
}
