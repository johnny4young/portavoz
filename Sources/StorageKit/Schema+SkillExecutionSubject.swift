import GRDB
import PortavozCore

extension StorageSchema {
    /// v41 (D341): exact typed subject authority for newly confirmed Skill
    /// executions plus the current content-free failure category in the state
    /// projection. Existing receipts keep working; a legacy row simply has no
    /// recovery subject until its exact owner is confirmed again.
    static func registerSkillExecutionSubjectMigration(
        in migrator: inout DatabaseMigrator
    ) {
        migrator.registerMigration("v41") { database in
            try addCurrentSkillFailureCategory(in: database)
            try createSkillExecutionSubject(in: database)
        }
    }

    private static func addCurrentSkillFailureCategory(
        in database: Database
    ) throws {
        try database.alter(table: "skillExecutionState") { table in
            table.add(column: "failureCategory", .text).check(sql: """
                failureCategory IS NULL OR failureCategory IN (
                    'critical', 'recoverable', 'degradable',
                    'external', 'destructive'
                )
                """)
        }
        try database.execute(sql: """
            UPDATE skillExecutionState
            SET failureCategory = (
                SELECT failureCategory
                FROM skillExecutionEvent
                WHERE skillExecutionEvent.id =
                    skillExecutionState.latestEventID
            )
            WHERE state = 'failed'
            """)
        try database.execute(sql: """
            CREATE TRIGGER skillExecutionState_failure_insert
            BEFORE INSERT ON skillExecutionState
            WHEN (NEW.state = 'failed') !=
                 (NEW.failureCategory IS NOT NULL)
            BEGIN
                SELECT RAISE(ABORT, 'invalid skill failure projection');
            END
            """)
        try database.execute(sql: """
            CREATE TRIGGER skillExecutionState_failure_update
            BEFORE UPDATE OF state, failureCategory ON skillExecutionState
            WHEN (NEW.state = 'failed') !=
                 (NEW.failureCategory IS NOT NULL)
            BEGIN
                SELECT RAISE(ABORT, 'invalid skill failure projection');
            END
            """)
    }

    private static func createSkillExecutionSubject(
        in database: Database
    ) throws {
        try database.create(table: "skillExecutionSubject") { table in
            table.primaryKey("proposalID", .text)
                .references("skillExecutionState", onDelete: .cascade)
            table.column("subjectKind", .text).notNull().check(sql: """
                subjectKind IN ('meeting', 'commitment', 'calendar-event')
                """)
            table.column("meetingID", .text)
                .references("meeting", onDelete: .cascade)
            table.column("commitmentID", .text)
                .references("commitment", onDelete: .cascade)
            table.column("calendarEventID", .text)
            table.check(sql: """
                (subjectKind = 'meeting'
                    AND meetingID IS NOT NULL
                    AND commitmentID IS NULL
                    AND calendarEventID IS NULL)
                OR (subjectKind = 'commitment'
                    AND meetingID IS NULL
                    AND commitmentID IS NOT NULL
                    AND calendarEventID IS NULL)
                OR (subjectKind = 'calendar-event'
                    AND meetingID IS NULL
                    AND commitmentID IS NULL
                    AND calendarEventID IS NOT NULL
                    AND length(CAST(calendarEventID AS BLOB)) BETWEEN 1 AND
                        \(UpcomingEvent.maximumIdentifierLength))
                """)
        }
    }
}
