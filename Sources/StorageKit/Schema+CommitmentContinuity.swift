import GRDB

extension StorageSchema {
    static func registerCommitmentContinuityMigration(
        in migrator: inout DatabaseMigrator
    ) {
        migrator.registerMigration("v20") { database in
            try createCommitmentTable(in: database)
            try createCommitmentSourceTables(in: database)
            try createCommitmentEventTable(in: database)
            try createCommitmentImmutabilityTriggers(in: database)
        }
    }

    private static func createCommitmentTable(in database: Database) throws {
        try database.create(table: "commitment") { table in
            table.primaryKey("id", .text)
            table.column("canonicalPersonID", .text)
                .references("person", onDelete: .restrict)
            table.column("title", .text).notNull().check(
                sql: "length(trim(title)) > 0")
            // A proposal remains an ActionItem. This table contains only
            // continuity state that crossed explicit user confirmation.
            table.column("status", .text).notNull().check(
                sql: "status IN ('confirmed', 'done', 'dismissed')")
            table.column("dueAt", .datetime)
            table.column("createdAt", .datetime).notNull()
            table.column("updatedAt", .datetime).notNull().check(
                sql: "updatedAt >= createdAt")
            table.column("deletedAt", .datetime).check(
                sql: "deletedAt IS NULL OR deletedAt >= createdAt")
        }
        try database.create(
            index: "commitment_on_status_dueAt",
            on: "commitment",
            columns: ["deletedAt", "status", "dueAt", "updatedAt", "id"])
        try database.create(
            index: "commitment_on_person_status",
            on: "commitment",
            columns: ["canonicalPersonID", "deletedAt", "status", "dueAt"])
    }

    private static func createCommitmentSourceTables(in database: Database) throws {
        try database.create(table: "commitmentSource") { table in
            table.primaryKey("id", .text)
            table.column("commitmentID", .text).notNull()
                .references("commitment", onDelete: .cascade)
            table.column("kind", .text).notNull().check(
                sql: "kind IN ('generated-action-item', 'user-note', 'manual')")
            // These are durable source identities, not cascading ownership.
            // Their rows may be purged later while this history stays honest.
            table.column("meetingID", .text)
            table.column("actionItemID", .text)
            table.column("contextItemID", .text)
            table.column("transcriptRevision", .integer).check(
                sql: "transcriptRevision IS NULL OR transcriptRevision >= 0")
            table.column("firstSeenAt", .datetime).notNull()
            table.check(sql: """
                (kind = 'generated-action-item'
                    AND meetingID IS NOT NULL
                    AND actionItemID IS NOT NULL
                    AND contextItemID IS NULL
                    AND transcriptRevision IS NOT NULL)
                OR (kind = 'user-note'
                    AND meetingID IS NOT NULL
                    AND actionItemID IS NULL
                    AND contextItemID IS NOT NULL
                    AND transcriptRevision IS NULL)
                OR (kind = 'manual'
                    AND actionItemID IS NULL
                    AND contextItemID IS NULL
                    AND transcriptRevision IS NULL)
                """)
        }
        try database.create(
            index: "commitmentSource_on_commitment",
            on: "commitmentSource",
            columns: ["commitmentID", "firstSeenAt", "id"])
        try database.create(
            index: "commitmentSource_on_meeting",
            on: "commitmentSource",
            columns: ["meetingID", "firstSeenAt"])
        try database.create(
            index: "commitmentSource_on_actionItem",
            on: "commitmentSource",
            columns: ["actionItemID"])
        try database.create(
            index: "commitmentSource_on_contextItem",
            on: "commitmentSource",
            columns: ["contextItemID"])

        try database.create(table: "commitmentEvidenceSegment") { table in
            table.column("sourceID", .text).notNull()
                .references("commitmentSource", onDelete: .cascade)
            // Deliberately no segment FK: a hard-purged transcript leaves an
            // unavailable evidence identity instead of rewriting history.
            table.column("segmentID", .text)
            table.column("role", .text).notNull().check(
                sql: "role IN ('promise', 'deadline', 'status-update')")
            table.column("ordinal", .integer).notNull().check(sql: "ordinal >= 0")
            table.primaryKey(["sourceID", "ordinal"])
            table.uniqueKey(["sourceID", "segmentID"])
        }
        try database.create(
            index: "commitmentEvidenceSegment_on_segment",
            on: "commitmentEvidenceSegment",
            columns: ["segmentID"])
    }

    private static func createCommitmentEventTable(in database: Database) throws {
        try database.create(table: "commitmentEvent") { table in
            table.primaryKey("id", .text)
            table.column("commitmentID", .text).notNull()
                .references("commitment", onDelete: .cascade)
            table.column("kind", .text).notNull().check(
                sql: "kind IN ('confirm', 'reassign', 'reschedule', "
                    + "'complete', 'reopen', 'dismiss')")
            table.column("canonicalPersonID", .text)
                .references("person", onDelete: .restrict)
            table.column("dueAt", .datetime)
            // The source meeting is historical context, not row ownership.
            table.column("sourceMeetingID", .text)
            table.column("occurredAt", .datetime).notNull()
            table.check(sql: """
                kind = 'confirm'
                OR (kind = 'reassign' AND dueAt IS NULL)
                OR (kind = 'reschedule' AND canonicalPersonID IS NULL)
                OR (kind IN ('complete', 'reopen', 'dismiss')
                    AND canonicalPersonID IS NULL AND dueAt IS NULL)
                """)
        }
        try database.create(
            index: "commitmentEvent_on_history",
            on: "commitmentEvent",
            columns: ["commitmentID", "occurredAt", "id"])
        try database.create(
            index: "commitmentEvent_on_sourceMeeting",
            on: "commitmentEvent",
            columns: ["sourceMeetingID", "occurredAt"])
    }

    private static func createCommitmentImmutabilityTriggers(
        in database: Database
    ) throws {
        try createTrigger(
            "commitment_immutable_identity_bu",
            timing: "BEFORE UPDATE OF title, createdAt",
            table: "commitment",
            body: "SELECT RAISE(ABORT, 'commitment identity is immutable');",
            when: valuesChanged(["title", "createdAt"]),
            in: database)
        for table in ["commitmentSource", "commitmentEvidenceSegment", "commitmentEvent"] {
            try createTrigger(
                "\(table)_immutable_bu",
                timing: "BEFORE UPDATE",
                table: table,
                body: "SELECT RAISE(ABORT, 'commitment history is immutable');",
                in: database)
        }
    }
}
