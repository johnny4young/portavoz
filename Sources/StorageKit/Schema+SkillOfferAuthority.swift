import GRDB
import PortavozCore

extension StorageSchema {
    /// v40 (D337): one content-free authority for offers that real subject
    /// surfaces have made. The random review UUID prevents Settings from
    /// receiving the stable offer key or opaque subject identity.
    ///
    /// v34's 200-character dismissal bound was also too narrow for the valid
    /// 2,000-byte EventKit identifiers admitted by `UpcomingEvent`; rebuilding
    /// that small table aligns every durable offer boundary to the Core limit.
    static func registerSkillOfferAuthorityMigration(
        in migrator: inout DatabaseMigrator
    ) {
        migrator.registerMigration("v40") { database in
            try rebuildSkillOfferDismissal(in: database)
            try createSkillOfferProposal(in: database)
        }
    }

    private static func rebuildSkillOfferDismissal(
        in database: Database
    ) throws {
        try database.rename(
            table: "skillOfferDismissal",
            to: "skillOfferDismissal_v34")
        try database.create(table: "skillOfferDismissal") { table in
            table.primaryKey("offerKey", .text)
            table.column("skillID", .text).notNull().check(
                sql: "length(CAST(skillID AS BLOB)) BETWEEN 1 AND 80")
            table.column("dismissedAt", .datetime).notNull()
            table.check(sql: """
                length(CAST(offerKey AS BLOB)) BETWEEN 1 AND
                    \(SkillOfferRegistration.maximumOfferKeyByteCount)
                """)
        }
        try database.execute(sql: """
            INSERT INTO skillOfferDismissal (offerKey, skillID, dismissedAt)
            SELECT offerKey, skillID, dismissedAt
            FROM skillOfferDismissal_v34
            """)
        try database.drop(table: "skillOfferDismissal_v34")
    }

    private static func createSkillOfferProposal(
        in database: Database
    ) throws {
        try database.create(table: "skillOfferProposal") { table in
            table.primaryKey("offerKey", .text)
            table.column("reviewID", .text).notNull().unique()
            table.column("skillID", .text).notNull().check(
                sql: "length(CAST(skillID AS BLOB)) BETWEEN 1 AND 80")
            table.column("skillVersion", .integer).notNull().check(
                sql: "skillVersion >= 1")
            table.column("reason", .text).notNull().check(sql: """
                reason IN (
                    'meeting-summary-ready',
                    'upcoming-calendar-event',
                    'confirmed-commitment'
                )
                """)
            table.column("subjectKind", .text).notNull().check(sql: """
                subjectKind IN ('meeting', 'commitment', 'calendar-event')
                """)
            table.column("meetingID", .text)
                .references("meeting", onDelete: .cascade)
            table.column("commitmentID", .text)
                .references("commitment", onDelete: .cascade)
            table.column("calendarEventID", .text)
            table.column("proposedAt", .datetime).notNull()
            table.column("lastObservedAt", .datetime).notNull().check(
                sql: "lastObservedAt >= proposedAt")
            table.column("expiresAt", .datetime)
            table.check(sql: """
                length(CAST(offerKey AS BLOB)) BETWEEN 1 AND
                    \(SkillOfferRegistration.maximumOfferKeyByteCount)
                """)
            table.check(sql: """
                (subjectKind = 'meeting'
                    AND meetingID IS NOT NULL
                    AND commitmentID IS NULL
                    AND calendarEventID IS NULL
                    AND reason = 'meeting-summary-ready')
                OR (subjectKind = 'commitment'
                    AND meetingID IS NULL
                    AND commitmentID IS NOT NULL
                    AND calendarEventID IS NULL
                    AND reason = 'confirmed-commitment')
                OR (subjectKind = 'calendar-event'
                    AND meetingID IS NULL
                    AND commitmentID IS NULL
                    AND calendarEventID IS NOT NULL
                    AND length(CAST(calendarEventID AS BLOB)) BETWEEN 1 AND 2000
                    AND reason = 'upcoming-calendar-event')
                """)
        }
        try database.execute(sql: """
            CREATE INDEX skillOfferProposal_on_review
            ON skillOfferProposal(lastObservedAt DESC, offerKey ASC)
            """)

        try createSkillOfferProposalInput(in: database)
    }

    private static func createSkillOfferProposalInput(
        in database: Database
    ) throws {
        try database.create(table: "skillOfferProposalInput") { table in
            table.column("offerKey", .text).notNull()
                .references("skillOfferProposal", onDelete: .cascade)
            table.column("dataClass", .text).notNull().check(sql: """
                dataClass IN (
                    'meeting-details',
                    'meeting-summary',
                    'transcript',
                    'notes',
                    'companion-history',
                    'commitment',
                    'calendar-event',
                    'selected-destination'
                )
                """)
            table.primaryKey(["offerKey", "dataClass"])
        }
    }
}
