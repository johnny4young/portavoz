import GRDB

extension StorageSchema {
    static func registerCommitmentEventEvidenceMigration(
        in migrator: inout DatabaseMigrator
    ) {
        migrator.registerMigration("v28") { database in
            try database.alter(table: "commitmentEvent") { table in
                table.add(column: "sourceTranscriptRevision", .integer).check(
                    sql: "sourceTranscriptRevision IS NULL OR "
                        + "(kind <> 'confirm' AND sourceMeetingID IS NOT NULL "
                        + "AND sourceTranscriptRevision >= 0)")
            }
            try database.create(table: "commitmentEventEvidenceSegment") { table in
                table.column("eventID", .text).notNull()
                    .references("commitmentEvent", onDelete: .cascade)
                // Deliberately no segment FK: a purged transcript makes the
                // immutable evidence unavailable instead of rewriting history.
                table.column("segmentID", .text).notNull()
                table.column("ordinal", .integer).notNull().check(sql: "ordinal >= 0")
                table.primaryKey(["eventID", "ordinal"])
                table.uniqueKey(["eventID", "segmentID"])
            }
            try database.create(
                index: "commitmentEventEvidenceSegment_on_segment",
                on: "commitmentEventEvidenceSegment",
                columns: ["segmentID"])
            try createCommitmentEventEvidenceValidationTrigger(in: database)
            try createTrigger(
                "commitmentEventEvidenceSegment_immutable_bu",
                timing: "BEFORE UPDATE",
                table: "commitmentEventEvidenceSegment",
                body: "SELECT RAISE(ABORT, 'commitment event evidence is immutable');",
                in: database)
        }
    }

    private static func createCommitmentEventEvidenceValidationTrigger(
        in database: Database
    ) throws {
        try database.execute(sql: """
            CREATE TRIGGER commitmentEventEvidenceSegment_valid_bi
            BEFORE INSERT ON commitmentEventEvidenceSegment
            WHEN NOT EXISTS (
                SELECT 1
                FROM commitmentEvent AS event
                JOIN meeting
                  ON meeting.id = event.sourceMeetingID
                JOIN segment
                  ON segment.id = NEW.segmentID
                 AND segment.meetingID = event.sourceMeetingID
                WHERE event.id = NEW.eventID
                  AND event.kind <> 'confirm'
                  AND event.sourceTranscriptRevision = meeting.transcriptRevision
                  AND meeting.deletedAt IS NULL
                  AND segment.deletedAt IS NULL
                  AND segment.isFinal = 1
                  AND \(MeetingStore.acceptedSegmentHasNoActiveCorrectionSQL)
            )
            BEGIN
                SELECT RAISE(ABORT, 'commitment event evidence is not current');
            END
            """)
    }
}
