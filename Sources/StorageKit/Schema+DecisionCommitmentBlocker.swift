import GRDB

extension StorageSchema {
    static func registerDecisionCommitmentBlockerMigration(
        in migrator: inout DatabaseMigrator
    ) {
        migrator.registerMigration("v30") { database in
            try createDecisionCommitmentBlockerTables(in: database)
            try createDecisionCommitmentBlockerTriggers(in: database)
            try createBlockerGraphTables(in: database)
            try createBlockerGraphInvalidationTriggers(in: database)
        }
    }

    private static func createDecisionCommitmentBlockerTables(
        in database: Database
    ) throws {
        try createDecisionCommitmentBlockerTable(in: database)
        try createDecisionCommitmentBlockerEvidenceTable(in: database)
        try createDecisionCommitmentBlockerEventTables(in: database)
    }

    private static func createDecisionCommitmentBlockerTable(
        in database: Database
    ) throws {
        try database.create(table: "decisionCommitmentBlocker") { table in
            table.primaryKey("id", .text)
            table.column("decisionID", .text).notNull()
                .references("decisionContinuity", onDelete: .cascade)
            table.column("commitmentID", .text).notNull()
                .references("commitment", onDelete: .cascade)
            table.column("status", .text).notNull().check(
                sql: "status IN ('active', 'cleared')")
            table.column("sourceMeetingID", .text).notNull()
            table.column("sourceTranscriptRevision", .integer).notNull().check(
                sql: "sourceTranscriptRevision >= 0")
            table.column("primarySegmentID", .text).notNull()
            table.column("confirmedAt", .datetime).notNull()
            table.column("updatedAt", .datetime).notNull()
            table.column("latestEventID", .text)
            table.column("deletedAt", .datetime)
            table.uniqueKey(["decisionID", "commitmentID"])
        }
        try database.create(
            index: "decisionCommitmentBlocker_on_commitment_status",
            on: "decisionCommitmentBlocker",
            columns: ["commitmentID", "status", "updatedAt"])
        try database.create(
            index: "decisionCommitmentBlocker_on_meeting",
            on: "decisionCommitmentBlocker",
            columns: ["sourceMeetingID", "confirmedAt", "id"])
    }

    private static func createDecisionCommitmentBlockerEvidenceTable(
        in database: Database
    ) throws {
        try database.create(table: "decisionCommitmentBlockerEvidenceSegment") { table in
            table.column("blockerID", .text).notNull()
                .references("decisionCommitmentBlocker", onDelete: .cascade)
            table.column("segmentID", .text).notNull()
            table.column("ordinal", .integer).notNull().check(sql: "ordinal > 0")
            table.primaryKey(["blockerID", "ordinal"])
            table.uniqueKey(["blockerID", "segmentID"])
        }
    }

    private static func createDecisionCommitmentBlockerEventTables(
        in database: Database
    ) throws {
        try database.create(table: "decisionCommitmentBlockerEvent") { table in
            table.primaryKey("id", .text)
            table.column("blockerID", .text).notNull()
                .references("decisionCommitmentBlocker", onDelete: .cascade)
            table.column("kind", .text).notNull().check(
                sql: "kind IN ('clear', 'reopen')")
            table.column("sourceMeetingID", .text).notNull()
            table.column("sourceTranscriptRevision", .integer).notNull().check(
                sql: "sourceTranscriptRevision >= 0")
            table.column("primarySegmentID", .text).notNull()
            table.column("occurredAt", .datetime).notNull()
        }
        try database.create(
            index: "decisionCommitmentBlockerEvent_on_blocker_time",
            on: "decisionCommitmentBlockerEvent",
            columns: ["blockerID", "occurredAt", "id"])
        try database.create(
            index: "decisionCommitmentBlockerEvent_on_meeting",
            on: "decisionCommitmentBlockerEvent",
            columns: ["sourceMeetingID", "occurredAt"])

        try database.create(
            table: "decisionCommitmentBlockerEventEvidenceSegment"
        ) { table in
            table.column("eventID", .text).notNull()
                .references("decisionCommitmentBlockerEvent", onDelete: .cascade)
            table.column("segmentID", .text).notNull()
            table.column("ordinal", .integer).notNull().check(sql: "ordinal > 0")
            table.primaryKey(["eventID", "ordinal"])
            table.uniqueKey(["eventID", "segmentID"])
        }
    }

    private static func createDecisionCommitmentBlockerTriggers(
        in database: Database
    ) throws {
        try createBlockerInsertTrigger(in: database)
        try createBlockerEvidenceTriggers(in: database)
        try createBlockerEventTriggers(in: database)
        try createBlockerImmutabilityTriggers(in: database)
    }

    private static func createBlockerInsertTrigger(in database: Database) throws {
        try createTrigger(
            "decisionCommitmentBlocker_valid_bi",
            timing: "BEFORE INSERT",
            table: "decisionCommitmentBlocker",
            body: "SELECT RAISE(ABORT, 'decision commitment blocker is invalid');",
            when: "NEW.status <> 'active' OR NEW.latestEventID IS NOT NULL "
                + "OR NEW.updatedAt <> NEW.confirmedAt OR NOT EXISTS ("
                + currentBlockerEvidenceSQL(
                    meetingID: "NEW.sourceMeetingID",
                    revision: "NEW.sourceTranscriptRevision",
                    segmentID: "NEW.primarySegmentID")
                + ") OR NOT EXISTS (SELECT 1 FROM decisionContinuity AS decision "
                + "WHERE decision.id = NEW.decisionID AND decision.status = 'confirmed' "
                + "AND decision.deletedAt IS NULL) OR NOT EXISTS (SELECT 1 FROM commitment "
                + "WHERE commitment.id = NEW.commitmentID "
                + "AND commitment.status = 'confirmed' AND commitment.deletedAt IS NULL)",
            in: database)
    }

    private static func createBlockerEvidenceTriggers(in database: Database) throws {
        try createBlockerEvidenceTrigger(
            name: "decisionCommitmentBlockerEvidenceSegment_valid_bi",
            table: "decisionCommitmentBlockerEvidenceSegment",
            ownerJoin: "JOIN decisionCommitmentBlocker AS owner ON owner.id = NEW.blockerID",
            in: database)
        try createBlockerEvidenceTrigger(
            name: "decisionCommitmentBlockerEventEvidenceSegment_valid_bi",
            table: "decisionCommitmentBlockerEventEvidenceSegment",
            ownerJoin: "JOIN decisionCommitmentBlockerEvent AS owner ON owner.id = NEW.eventID",
            in: database)
    }

    private static func createBlockerEventTriggers(in database: Database) throws {
        try database.execute(sql: """
            CREATE TRIGGER decisionCommitmentBlockerEvent_valid_bi
            BEFORE INSERT ON decisionCommitmentBlockerEvent
            WHEN NOT EXISTS (
                SELECT 1
                FROM decisionCommitmentBlocker AS blocker
                WHERE blocker.id = NEW.blockerID
                  AND blocker.deletedAt IS NULL
                  AND NEW.occurredAt > blocker.updatedAt
                  AND ((blocker.status = 'active' AND NEW.kind = 'clear')
                    OR (blocker.status = 'cleared' AND NEW.kind = 'reopen'
                      AND \(currentBlockerEndpointsSQL(blocker: "blocker"))))
            ) OR NOT EXISTS (
                \(currentBlockerEvidenceSQL(
                    meetingID: "NEW.sourceMeetingID",
                    revision: "NEW.sourceTranscriptRevision",
                    segmentID: "NEW.primarySegmentID"))
            )
            BEGIN
                SELECT RAISE(ABORT, 'decision commitment blocker transition is invalid');
            END;

            CREATE TRIGGER decisionCommitmentBlockerEvent_project_ai
            AFTER INSERT ON decisionCommitmentBlockerEvent
            BEGIN
                UPDATE decisionCommitmentBlocker
                SET status = CASE NEW.kind
                        WHEN 'clear' THEN 'cleared'
                        ELSE 'active'
                    END,
                    updatedAt = NEW.occurredAt,
                    latestEventID = NEW.id
                WHERE id = NEW.blockerID;
            END;
            """)
    }

    private static func createBlockerImmutabilityTriggers(
        in database: Database
    ) throws {
        try createTrigger(
            "decisionCommitmentBlocker_immutable_identity_bu",
            timing: "BEFORE UPDATE OF id, decisionID, commitmentID, sourceMeetingID, "
                + "sourceTranscriptRevision, primarySegmentID, confirmedAt",
            table: "decisionCommitmentBlocker",
            body: "SELECT RAISE(ABORT, 'decision commitment blocker identity is immutable');",
            when: valuesChanged([
                "id", "decisionID", "commitmentID", "sourceMeetingID",
                "sourceTranscriptRevision", "primarySegmentID", "confirmedAt"
            ]),
            in: database)
        try createTrigger(
            "decisionCommitmentBlocker_projected_transition_bu",
            timing: "BEFORE UPDATE OF status, updatedAt, latestEventID",
            table: "decisionCommitmentBlocker",
            body: "SELECT RAISE(ABORT, 'decision commitment blocker projection is invalid');",
            when: "(OLD.status <> NEW.status OR OLD.updatedAt <> NEW.updatedAt "
                + "OR OLD.latestEventID IS NOT NEW.latestEventID) AND ("
                + "NEW.latestEventID IS NULL OR NEW.updatedAt <= OLD.updatedAt "
                + "OR NOT EXISTS (SELECT 1 FROM decisionCommitmentBlockerEvent AS event "
                + "WHERE event.id = NEW.latestEventID AND event.blockerID = NEW.id "
                + "AND event.occurredAt = NEW.updatedAt AND ((event.kind = 'clear' "
                + "AND NEW.status = 'cleared') OR (event.kind = 'reopen' "
                + "AND NEW.status = 'active'))))",
            in: database)
        for (name, table) in blockerImmutableHistoryTables {
            try createTrigger(
                name,
                timing: "BEFORE UPDATE",
                table: table,
                body: "SELECT RAISE(ABORT, 'decision commitment blocker history is immutable');",
                in: database)
        }
    }

    private static let blockerImmutableHistoryTables = [
        (
            "decisionCommitmentBlockerEvidenceSegment_immutable_bu",
            "decisionCommitmentBlockerEvidenceSegment"
        ),
        (
            "decisionCommitmentBlockerEvent_immutable_bu",
            "decisionCommitmentBlockerEvent"
        ),
        (
            "decisionCommitmentBlockerEventEvidenceSegment_immutable_bu",
            "decisionCommitmentBlockerEventEvidenceSegment"
        )
    ]

    private static func createBlockerEvidenceTrigger(
        name: String,
        table: String,
        ownerJoin: String,
        in database: Database
    ) throws {
        try database.execute(sql: """
            CREATE TRIGGER \(name)
            BEFORE INSERT ON \(table)
            WHEN NOT EXISTS (
                SELECT 1
                FROM (SELECT 1) AS seed
                \(ownerJoin)
                JOIN meeting ON meeting.id = owner.sourceMeetingID
                JOIN segment ON segment.id = NEW.segmentID
                  AND segment.meetingID = owner.sourceMeetingID
                WHERE owner.sourceTranscriptRevision = meeting.transcriptRevision
                  AND meeting.deletedAt IS NULL
                  AND segment.deletedAt IS NULL
                  AND segment.isFinal = 1
                  AND \(MeetingStore.acceptedSegmentHasNoActiveCorrectionSQL)
            )
            BEGIN
                SELECT RAISE(ABORT, 'decision commitment blocker evidence is invalid');
            END
            """)
    }

    private static func currentBlockerEndpointsSQL(blocker: String) -> String {
        """
        EXISTS (
            SELECT 1 FROM decisionContinuity AS decision
            WHERE decision.id = \(blocker).decisionID
              AND decision.status = 'confirmed'
              AND decision.deletedAt IS NULL
        ) AND EXISTS (
            SELECT 1 FROM commitment
            WHERE commitment.id = \(blocker).commitmentID
              AND commitment.status = 'confirmed'
              AND commitment.deletedAt IS NULL
        )
        """
    }

    private static func currentBlockerEvidenceSQL(
        meetingID: String,
        revision: String,
        segmentID: String
    ) -> String {
        """
        SELECT 1
        FROM meeting
        JOIN segment ON segment.id = \(segmentID)
          AND segment.meetingID = \(meetingID)
        WHERE meeting.id = \(meetingID)
          AND meeting.transcriptRevision = \(revision)
          AND meeting.deletedAt IS NULL
          AND segment.deletedAt IS NULL
          AND segment.isFinal = 1
          AND \(MeetingStore.acceptedSegmentHasNoActiveCorrectionSQL)
        """
    }
}
