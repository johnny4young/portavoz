import GRDB

extension StorageSchema {
    static func registerMeetingQuestionContinuityMigration(
        in migrator: inout DatabaseMigrator
    ) {
        migrator.registerMigration("v29") { database in
            try createMeetingQuestionTables(in: database)
            try createMeetingQuestionTriggers(in: database)
            try createMeetingQuestionGraphTables(in: database)
            try createMeetingQuestionGraphInvalidationTriggers(in: database)
        }
    }

    private static func createMeetingQuestionTables(in database: Database) throws {
        try database.create(table: "meetingQuestion") { table in
            table.primaryKey("id", .text)
            table.column("topicID", .text).notNull().references("topic")
            table.column("text", .text).notNull().check(sql: "length(trim(text)) > 0")
            table.column("status", .text).notNull().check(
                sql: "status IN ('open', 'resolved', 'dismissed')")
            table.column("sourceMeetingID", .text).notNull()
            table.column("sourceTranscriptRevision", .integer).notNull().check(
                sql: "sourceTranscriptRevision >= 0")
            table.column("primarySegmentID", .text).notNull()
            table.column("openedAt", .datetime).notNull()
            table.column("updatedAt", .datetime).notNull()
            table.column("latestEventID", .text)
            table.column("deletedAt", .datetime)
        }
        try database.create(
            index: "meetingQuestion_on_topic_status",
            on: "meetingQuestion",
            columns: ["topicID", "status", "updatedAt"])

        try database.create(table: "meetingQuestionEvidenceSegment") { table in
            table.column("questionID", .text).notNull()
                .references("meetingQuestion", onDelete: .cascade)
            table.column("segmentID", .text).notNull()
            table.column("ordinal", .integer).notNull().check(sql: "ordinal > 0")
            table.primaryKey(["questionID", "ordinal"])
            table.uniqueKey(["questionID", "segmentID"])
        }

        try database.create(table: "meetingQuestionEvent") { table in
            table.primaryKey("id", .text)
            table.column("questionID", .text).notNull()
                .references("meetingQuestion", onDelete: .cascade)
            table.column("kind", .text).notNull().check(
                sql: "kind IN ('resolve', 'reopen', 'dismiss')")
            table.column("sourceMeetingID", .text).notNull()
            table.column("sourceTranscriptRevision", .integer).notNull().check(
                sql: "sourceTranscriptRevision >= 0")
            table.column("primarySegmentID", .text).notNull()
            table.column("occurredAt", .datetime).notNull()
        }
        try database.create(
            index: "meetingQuestionEvent_on_question_time",
            on: "meetingQuestionEvent",
            columns: ["questionID", "occurredAt", "id"])
        try database.create(
            index: "meetingQuestionEvent_on_meeting",
            on: "meetingQuestionEvent",
            columns: ["sourceMeetingID", "occurredAt"])

        try database.create(table: "meetingQuestionEventEvidenceSegment") { table in
            table.column("eventID", .text).notNull()
                .references("meetingQuestionEvent", onDelete: .cascade)
            table.column("segmentID", .text).notNull()
            table.column("ordinal", .integer).notNull().check(sql: "ordinal > 0")
            table.primaryKey(["eventID", "ordinal"])
            table.uniqueKey(["eventID", "segmentID"])
        }
    }

    private static func createMeetingQuestionTriggers(in database: Database) throws {
        try createTrigger(
            "meetingQuestion_valid_bi",
            timing: "BEFORE INSERT",
            table: "meetingQuestion",
            body: "SELECT RAISE(ABORT, 'meeting question evidence is not current');",
            when: "NEW.status <> 'open' OR NEW.latestEventID IS NOT NULL "
                + "OR NEW.updatedAt <> NEW.openedAt OR NOT EXISTS ("
                + currentQuestionEvidenceSQL(
                    meetingID: "NEW.sourceMeetingID",
                    revision: "NEW.sourceTranscriptRevision",
                    segmentID: "NEW.primarySegmentID")
                + ") OR NOT EXISTS (SELECT 1 FROM topic WHERE id = NEW.topicID "
                + "AND deletedAt IS NULL AND mergedIntoTopicID IS NULL)",
            in: database)
        try createMeetingQuestionEvidenceTriggers(in: database)
        try createMeetingQuestionEventTriggers(in: database)
        try createMeetingQuestionImmutabilityTriggers(in: database)
    }

    private static func createMeetingQuestionEvidenceTriggers(
        in database: Database
    ) throws {
        try createQuestionEvidenceTrigger(
            name: "meetingQuestionEvidenceSegment_valid_bi",
            table: "meetingQuestionEvidenceSegment",
            ownerJoin: "JOIN meetingQuestion AS owner ON owner.id = NEW.questionID",
            in: database)
        try createQuestionEvidenceTrigger(
            name: "meetingQuestionEventEvidenceSegment_valid_bi",
            table: "meetingQuestionEventEvidenceSegment",
            ownerJoin: "JOIN meetingQuestionEvent AS owner ON owner.id = NEW.eventID",
            in: database)
    }

    private static func createMeetingQuestionEventTriggers(
        in database: Database
    ) throws {
        try database.execute(sql: """
            CREATE TRIGGER meetingQuestionEvent_valid_bi
            BEFORE INSERT ON meetingQuestionEvent
            WHEN NOT EXISTS (
                SELECT 1
                FROM meetingQuestion AS question
                WHERE question.id = NEW.questionID
                  AND question.deletedAt IS NULL
                  AND NEW.occurredAt > question.updatedAt
                  AND ((question.status = 'open' AND NEW.kind IN ('resolve', 'dismiss'))
                    OR (question.status = 'resolved' AND NEW.kind IN ('reopen', 'dismiss')))
            ) OR NOT EXISTS (
                \(currentQuestionEvidenceSQL(
                    meetingID: "NEW.sourceMeetingID",
                    revision: "NEW.sourceTranscriptRevision",
                    segmentID: "NEW.primarySegmentID"))
            )
            BEGIN
                SELECT RAISE(ABORT, 'meeting question transition is invalid');
            END;

            CREATE TRIGGER meetingQuestionEvent_project_ai
            AFTER INSERT ON meetingQuestionEvent
            BEGIN
                UPDATE meetingQuestion
                SET status = CASE NEW.kind
                        WHEN 'resolve' THEN 'resolved'
                        WHEN 'reopen' THEN 'open'
                        ELSE 'dismissed'
                    END,
                    updatedAt = NEW.occurredAt,
                    latestEventID = NEW.id
                WHERE id = NEW.questionID;
            END;
            """)
    }

    private static func createMeetingQuestionImmutabilityTriggers(
        in database: Database
    ) throws {
        try createTrigger(
            "meetingQuestion_immutable_identity_bu",
            timing: "BEFORE UPDATE OF id, topicID, text, sourceMeetingID, "
                + "sourceTranscriptRevision, primarySegmentID, openedAt",
            table: "meetingQuestion",
            body: "SELECT RAISE(ABORT, 'meeting question identity is immutable');",
            when: valuesChanged([
                "id", "topicID", "text", "sourceMeetingID", "sourceTranscriptRevision",
                "primarySegmentID", "openedAt"
            ]),
            in: database)
        try createTrigger(
            "meetingQuestion_projected_transition_bu",
            timing: "BEFORE UPDATE OF status, updatedAt, latestEventID",
            table: "meetingQuestion",
            body: "SELECT RAISE(ABORT, 'meeting question projection update is invalid');",
            when: "(OLD.status <> NEW.status OR OLD.updatedAt <> NEW.updatedAt "
                + "OR OLD.latestEventID IS NOT NEW.latestEventID) AND ("
                + "NEW.latestEventID IS NULL OR NEW.updatedAt <= OLD.updatedAt "
                + "OR NOT EXISTS (SELECT 1 FROM meetingQuestionEvent AS event "
                + "WHERE event.id = NEW.latestEventID AND event.questionID = NEW.id "
                + "AND event.occurredAt = NEW.updatedAt AND ((event.kind = 'resolve' "
                + "AND NEW.status = 'resolved') OR (event.kind = 'reopen' "
                + "AND NEW.status = 'open') OR (event.kind = 'dismiss' "
                + "AND NEW.status = 'dismissed'))))",
            in: database)
        for (name, table) in [
            ("meetingQuestionEvidenceSegment_immutable_bu", "meetingQuestionEvidenceSegment"),
            ("meetingQuestionEvent_immutable_bu", "meetingQuestionEvent"),
            ("meetingQuestionEventEvidenceSegment_immutable_bu", "meetingQuestionEventEvidenceSegment")
        ] {
            try createTrigger(
                name,
                timing: "BEFORE UPDATE",
                table: table,
                body: "SELECT RAISE(ABORT, 'meeting question history is immutable');",
                in: database)
        }
    }

    private static func createMeetingQuestionGraphTables(
        in database: Database
    ) throws {
        try database.create(table: "meetingMemoryGraphMeetingQuestion") { table in
            table.column("meetingID", .text).notNull()
                .references("meeting", onDelete: .cascade)
            table.column("questionID", .text).notNull()
                .references("meetingQuestion", onDelete: .cascade)
            table.primaryKey(["meetingID", "questionID"])
        }
        try database.create(
            index: "meetingMemoryGraphMeetingQuestion_on_question",
            on: "meetingMemoryGraphMeetingQuestion",
            columns: ["questionID", "meetingID"])

        try database.create(table: "meetingMemoryGraphTopicQuestion") { table in
            table.column("topicID", .text).notNull()
                .references("topic", onDelete: .cascade)
            table.column("questionID", .text).notNull()
                .references("meetingQuestion", onDelete: .cascade)
            table.primaryKey(["topicID", "questionID"])
        }
        try database.create(
            index: "meetingMemoryGraphTopicQuestion_on_question",
            on: "meetingMemoryGraphTopicQuestion",
            columns: ["questionID", "topicID"])
    }

    private static func createMeetingQuestionGraphInvalidationTriggers(
        in database: Database
    ) throws {
        try createMemoryGraphTrigger(
            "memoryGraphMeetingQuestion_ai",
            timing: "AFTER INSERT",
            table: "meetingQuestion",
            scopes: """
                SELECT 'meeting' AS scopeKind, NEW.sourceMeetingID AS scopeID
                UNION SELECT 'topic', NEW.topicID
                """,
            in: database)
        try createMemoryGraphTrigger(
            "memoryGraphMeetingQuestion_au",
            timing: "AFTER UPDATE OF deletedAt",
            table: "meetingQuestion",
            scopes: """
                SELECT 'meeting' AS scopeKind, NEW.sourceMeetingID AS scopeID
                UNION SELECT 'topic', NEW.topicID
                UNION SELECT 'meeting', event.sourceMeetingID
                FROM meetingQuestionEvent AS event
                WHERE event.questionID = NEW.id
                """,
            when: valuesChanged(["deletedAt"]),
            in: database)
        try createMemoryGraphTrigger(
            "memoryGraphMeetingQuestion_ad",
            timing: "AFTER DELETE",
            table: "meetingQuestion",
            scopes: """
                SELECT 'meeting' AS scopeKind, OLD.sourceMeetingID AS scopeID
                UNION SELECT 'topic', OLD.topicID
                """,
            in: database)
        try createMemoryGraphTrigger(
            "memoryGraphMeetingQuestionEvent_ai",
            timing: "AFTER INSERT",
            table: "meetingQuestionEvent",
            scopes: "SELECT 'meeting' AS scopeKind, NEW.sourceMeetingID AS scopeID",
            in: database)
        try createMemoryGraphTrigger(
            "memoryGraphMeetingQuestionEvent_ad",
            timing: "AFTER DELETE",
            table: "meetingQuestionEvent",
            scopes: "SELECT 'meeting' AS scopeKind, OLD.sourceMeetingID AS scopeID",
            in: database)
    }

    private static func createQuestionEvidenceTrigger(
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
                SELECT RAISE(ABORT, 'meeting question evidence is not current');
            END
            """)
    }

    private static func currentQuestionEvidenceSQL(
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
