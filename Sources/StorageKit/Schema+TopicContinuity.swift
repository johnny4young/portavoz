import GRDB

extension StorageSchema {
    static func registerTopicContinuityMigration(
        in migrator: inout DatabaseMigrator
    ) {
        migrator.registerMigration("v25") { database in
            try createTopicTable(in: database)
            try createTopicAliasTable(in: database)
            try createTopicMeetingEvidenceTable(in: database)
            try createTopicIdentityEventTable(in: database)
            try createTopicContinuityImmutabilityTriggers(in: database)
        }
    }

    private static func createTopicTable(in database: Database) throws {
        try database.create(table: "topic") { table in
            table.primaryKey("id", .text)
            // Presentation only. UUID identity remains stable across labels.
            table.column("preferredLabel", .text).notNull().check(
                sql: "length(trim(preferredLabel)) > 0")
            table.column("mergedIntoTopicID", .text)
                .references("topic", onDelete: .restrict)
            table.column("createdAt", .datetime).notNull()
            table.column("updatedAt", .datetime).notNull().check(
                sql: "updatedAt >= createdAt")
            table.column("deletedAt", .datetime).check(
                sql: "deletedAt IS NULL OR deletedAt >= createdAt")
            table.check(sql: "mergedIntoTopicID IS NULL OR mergedIntoTopicID <> id")
        }
        try database.create(
            index: "topic_on_mergedIntoTopicID",
            on: "topic",
            columns: ["mergedIntoTopicID"])
    }

    private static func createTopicAliasTable(in database: Database) throws {
        try database.create(table: "topicAlias") { table in
            table.primaryKey("id", .text)
            table.column("topicID", .text).notNull()
                .references("topic", onDelete: .restrict)
            table.column("displayLabel", .text).notNull().check(
                sql: "length(trim(displayLabel)) > 0")
            table.column("normalizedAlias", .text).notNull().check(
                sql: "length(trim(normalizedAlias)) > 0")
            table.column("language", .text)
            table.column("source", .text).notNull().check(
                sql: "source IN ('manual', 'generated-similarity')")
            table.column("createdAt", .datetime).notNull()
            table.column("updatedAt", .datetime).notNull().check(
                sql: "updatedAt >= createdAt")
            table.column("deletedAt", .datetime).check(
                sql: "deletedAt IS NULL OR deletedAt >= createdAt")
            table.uniqueKey(["topicID", "normalizedAlias"])
            table.uniqueKey(["id", "topicID"])
        }
        try database.create(
            index: "topicAlias_on_normalizedAlias",
            on: "topicAlias",
            columns: ["normalizedAlias"])
    }

    private static func createTopicMeetingEvidenceTable(
        in database: Database
    ) throws {
        try database.create(table: "topicMeetingEvidence") { table in
            table.primaryKey("id", .text)
            table.column("topicID", .text).notNull()
                .references("topic", onDelete: .restrict)
            table.column("aliasID", .text).notNull()
                .references("topicAlias", onDelete: .restrict)
            // Deliberately no meeting/segment foreign keys: hard-purged source
            // content leaves an unavailable identity instead of erasing history.
            table.column("meetingID", .text).notNull()
            table.column("segmentID", .text).notNull()
            table.column("sourceTranscriptRevision", .integer).notNull().check(
                sql: "sourceTranscriptRevision >= 0")
            table.column("observedLabel", .text).notNull().check(
                sql: "length(trim(observedLabel)) > 0")
            table.column("language", .text)
            table.column("origin", .text).notNull().check(
                sql: "origin IN ('manual', 'generated-similarity')")
            table.column("resolution", .text).notNull().check(
                sql: "resolution IN ('kept-distinct', 'merged-into-existing')")
            // Candidate metadata explains a generated suggestion; it never
            // selects a threshold or grants write authority.
            table.column("suggestedTopicID", .text)
            table.column("similarity", .double).check(
                sql: "similarity IS NULL OR (similarity >= -1 AND similarity <= 1)")
            table.column("profileFingerprint", .text)
            table.column("confirmedAt", .datetime).notNull()
            table.check(sql: """
                (origin = 'manual'
                    AND suggestedTopicID IS NULL
                    AND similarity IS NULL
                    AND profileFingerprint IS NULL)
                OR (origin = 'generated-similarity'
                    AND suggestedTopicID IS NOT NULL
                    AND similarity IS NOT NULL
                    AND length(trim(profileFingerprint)) > 0)
                """)
            table.uniqueKey(["topicID", "meetingID", "segmentID"])
            table.foreignKey(
                ["aliasID", "topicID"],
                references: "topicAlias",
                columns: ["id", "topicID"],
                onDelete: .restrict)
        }
        try database.create(
            index: "topicMeetingEvidence_on_topic",
            on: "topicMeetingEvidence",
            columns: ["topicID", "confirmedAt", "id"])
        try database.create(
            index: "topicMeetingEvidence_on_meeting",
            on: "topicMeetingEvidence",
            columns: ["meetingID", "segmentID"])
    }

    private static func createTopicIdentityEventTable(
        in database: Database
    ) throws {
        try database.create(table: "topicIdentityEvent") { table in
            table.primaryKey("id", .text)
            table.column("kind", .text).notNull().check(
                sql: "kind IN ('merge', 'split')")
            table.column("sourceTopicID", .text).notNull()
                .references("topic", onDelete: .restrict)
            table.column("targetTopicID", .text).notNull()
                .references("topic", onDelete: .restrict)
            table.column("occurredAt", .datetime).notNull()
            table.check(sql: "sourceTopicID <> targetTopicID")
        }
        try database.create(
            index: "topicIdentityEvent_on_source",
            on: "topicIdentityEvent",
            columns: ["sourceTopicID", "occurredAt", "id"])
        try database.create(
            index: "topicIdentityEvent_on_target",
            on: "topicIdentityEvent",
            columns: ["targetTopicID", "occurredAt", "id"])
    }

    private static func createTopicContinuityImmutabilityTriggers(
        in database: Database
    ) throws {
        try createTrigger(
            "topic_immutable_identity_bu",
            timing: "BEFORE UPDATE OF id, preferredLabel, createdAt",
            table: "topic",
            body: "SELECT RAISE(ABORT, 'topic identity is immutable');",
            when: valuesChanged(["id", "preferredLabel", "createdAt"]),
            in: database)
        for table in ["topicAlias", "topicMeetingEvidence", "topicIdentityEvent"] {
            try createTrigger(
                "\(table)_immutable_bu",
                timing: "BEFORE UPDATE",
                table: table,
                body: "SELECT RAISE(ABORT, 'topic continuity history is immutable');",
                in: database)
        }
    }
}
