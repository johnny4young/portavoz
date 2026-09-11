import GRDB

extension StorageSchema {
    static func registerTranscriptCorrectionMigration(
        in migrator: inout DatabaseMigrator
    ) {
        migrator.registerMigration("v19") { database in
            try createTranscriptCorrectionParentTable(in: database)
            try createTranscriptCorrectionPayloadTables(in: database)
            try createTranscriptCorrectionImmutabilityTriggers(in: database)
            try createTranscriptCorrectionSyncTriggers(in: database)
        }
    }

    private static func createTranscriptCorrectionParentTable(
        in database: Database
    ) throws {
        try database.create(table: "transcriptCorrection") { table in
            table.primaryKey("id", .text)
            table.column("meetingID", .text).notNull()
                .references("meeting", onDelete: .cascade)
            table.column("baseTranscriptRevision", .integer).notNull().check(
                sql: "baseTranscriptRevision >= 0")
            table.column("kind", .text).notNull().check(
                sql: "kind IN ('replaceText', 'changeSpeaker', 'split', "
                    + "'merge', 'suppress', 'restore')")
            table.column("author", .text).notNull().check(sql: "author = 'user'")
            table.column("sourceDeviceID", .text).notNull().check(
                sql: "length(sourceDeviceID) = 36")
            table.column("supersedesCorrectionID", .text)
                .references("transcriptCorrection", onDelete: .restrict)
            table.column("createdAt", .datetime).notNull()
            table.column("updatedAt", .datetime).notNull().check(
                sql: "updatedAt >= createdAt")
            table.column("deletedAt", .datetime).check(
                sql: "deletedAt IS NULL OR "
                    + "(deletedAt >= createdAt AND deletedAt <= updatedAt)")
            table.uniqueKey(["supersedesCorrectionID"])
            table.check(sql: "supersedesCorrectionID IS NULL OR supersedesCorrectionID <> id")
        }
        try database.create(
            index: "transcriptCorrection_on_meeting_revision_live",
            on: "transcriptCorrection",
            columns: ["meetingID", "baseTranscriptRevision", "deletedAt", "createdAt", "id"])
    }

    private static func createTranscriptCorrectionPayloadTables(
        in database: Database
    ) throws {
        try database.create(table: "transcriptCorrectionTarget") { table in
            table.column("correctionID", .text).notNull()
                .references("transcriptCorrection", onDelete: .cascade)
            // Deliberately no segment FK: accepted evidence may later be
            // replaced or purged while the immutable correction history still
            // needs to explain which source identity became unavailable.
            table.column("segmentID", .text).notNull()
            table.column("ordinal", .integer).notNull().check(sql: "ordinal >= 0")
            table.primaryKey(["correctionID", "ordinal"])
            table.uniqueKey(["correctionID", "segmentID"])
        }
        try database.create(
            index: "transcriptCorrectionTarget_on_segmentID",
            on: "transcriptCorrectionTarget",
            columns: ["segmentID"])

        try database.create(table: "transcriptCorrectionPayload") { table in
            table.primaryKey("correctionID", .text)
                .references("transcriptCorrection", onDelete: .cascade)
            table.column("text", .text).check(
                sql: "text IS NULL OR length(trim(text)) > 0")
            table.column("language", .text).check(
                sql: "language IS NULL OR length(trim(language)) > 0")
            table.column("speakerID", .text)
        }

        try database.create(table: "transcriptCorrectionPart") { table in
            // This is also the stable visible row identity after composition.
            table.primaryKey("id", .text)
            table.column("correctionID", .text).notNull()
                .references("transcriptCorrection", onDelete: .cascade)
            table.column("ordinal", .integer).notNull().check(sql: "ordinal >= 0")
            table.column("text", .text).notNull().check(sql: "length(trim(text)) > 0")
            table.column("speakerID", .text)
            table.column("language", .text).check(
                sql: "language IS NULL OR length(trim(language)) > 0")
            table.column("startTime", .double).notNull().check(sql: "startTime >= 0")
            table.column("endTime", .double).notNull().check(sql: "endTime > startTime")
            table.uniqueKey(["correctionID", "ordinal"])
        }
    }

    private static func createTranscriptCorrectionImmutabilityTriggers(
        in database: Database
    ) throws {
        try createTrigger(
            "transcriptCorrection_immutable_bu",
            timing: "BEFORE UPDATE",
            table: "transcriptCorrection",
            body: """
                SELECT CASE WHEN
                    OLD.id IS NOT NEW.id OR
                    OLD.meetingID IS NOT NEW.meetingID OR
                    OLD.baseTranscriptRevision IS NOT NEW.baseTranscriptRevision OR
                    OLD.kind IS NOT NEW.kind OR
                    OLD.author IS NOT NEW.author OR
                    OLD.sourceDeviceID IS NOT NEW.sourceDeviceID OR
                    OLD.supersedesCorrectionID IS NOT NEW.supersedesCorrectionID OR
                    OLD.createdAt IS NOT NEW.createdAt
                THEN RAISE(ABORT, 'transcript correction events are immutable') END;
                """,
            in: database)
        try createTrigger(
            "transcriptCorrection_tombstone_bu",
            timing: "BEFORE UPDATE",
            table: "transcriptCorrection",
            body: """
                SELECT CASE WHEN
                    OLD.deletedAt IS NOT NULL OR
                    NEW.deletedAt IS NULL OR
                    NEW.updatedAt IS NOT NEW.deletedAt OR
                    NEW.updatedAt < OLD.updatedAt
                THEN RAISE(ABORT, 'transcript correction updates must be tombstones') END;
                """,
            in: database)

        for table in ["transcriptCorrectionTarget", "transcriptCorrectionPayload",
                      "transcriptCorrectionPart"] {
            try createTrigger(
                "\(table)_immutable_bu",
                timing: "BEFORE UPDATE",
                table: table,
                body: "SELECT RAISE(ABORT, 'transcript correction payloads are immutable');",
                in: database)
        }
    }

    /// Only the parent event advances the meeting journal. Ordered targets
    /// and typed payload rows are inserted in the same transaction, so child
    /// triggers would inflate one logical correction into several generations.
    private static func createTranscriptCorrectionSyncTriggers(
        in database: Database
    ) throws {
        try createTrigger(
            "transcriptCorrection_sync_ai",
            timing: "AFTER INSERT",
            table: "transcriptCorrection",
            body: childSyncUpsert(
                meetingID: "NEW.meetingID",
                changedAt: "NEW.updatedAt"),
            in: database)
        try createTrigger(
            "transcriptCorrection_sync_au",
            timing: "AFTER UPDATE OF deletedAt, updatedAt",
            table: "transcriptCorrection",
            body: childSyncUpsert(
                meetingID: "NEW.meetingID",
                changedAt: "NEW.updatedAt"),
            when: valuesChanged(["deletedAt", "updatedAt"]),
            in: database)
        try createTrigger(
            "transcriptCorrection_sync_ad",
            timing: "AFTER DELETE",
            table: "transcriptCorrection",
            body: childSyncUpsert(
                meetingID: "OLD.meetingID",
                changedAt: "CURRENT_TIMESTAMP"),
            in: database)
    }
}
