import GRDB

extension StorageSchema {
    static func registerDerivedMaintenanceMigration(
        in migrator: inout DatabaseMigrator
    ) {
        migrator.registerMigration("v18") { db in
            try createDerivedMaintenanceTables(in: db)
            try createSemanticCorpusGenerationTriggers(in: db)
        }
    }

    private static func createDerivedMaintenanceTables(in db: Database) throws {
        try db.create(table: "derivedMaintenanceSource") { table in
            table.primaryKey("kind", .text)
            table.column("sourceGeneration", .integer)
                .notNull()
                .defaults(to: 0)
                .check(sql: "sourceGeneration >= 0")
            table.column("updatedAt", .datetime).notNull()
        }
        try db.execute(sql: """
            INSERT INTO derivedMaintenanceSource (kind, sourceGeneration, updatedAt)
            SELECT 'semantic-corpus',
                   CASE WHEN EXISTS (
                       SELECT 1
                       FROM segment
                       JOIN meeting ON meeting.id = segment.meetingID
                       WHERE segment.deletedAt IS NULL AND meeting.deletedAt IS NULL
                   ) THEN 1 ELSE 0 END,
                   CURRENT_TIMESTAMP
            """)

        try db.create(table: "derivedMaintenanceJob") { table in
            table.primaryKey("id", .text)
            table.column("kind", .text).notNull()
            table.column("targetFingerprint", .text).notNull().check(
                sql: "length(targetFingerprint) = 64")
            table.column("sourceGeneration", .integer).notNull().check(
                sql: "sourceGeneration >= 0")
            table.column("operationFingerprint", .text).notNull().check(
                sql: "length(operationFingerprint) = 64")
            table.column("state", .text).notNull().defaults(to: "pending").check(
                sql: "state IN ('pending', 'running', 'succeeded', 'failed', 'cancelled')")
            table.column("attempt", .integer).notNull().defaults(to: 0).check(
                sql: "attempt >= 0")
            table.column("maxAttempts", .integer).notNull().defaults(to: 3).check(
                sql: "maxAttempts > 0 AND attempt <= maxAttempts")
            table.column("notBefore", .datetime)
            table.column("leaseOwner", .text)
            table.column("leaseExpiresAt", .datetime)
            table.column("errorCode", .text)
            table.column("createdAt", .datetime).notNull()
            table.column("startedAt", .datetime)
            table.column("finishedAt", .datetime)
            table.column("updatedAt", .datetime).notNull()
            table.uniqueKey(["kind", "operationFingerprint"])
            table.foreignKey(
                ["kind"], references: "derivedMaintenanceSource",
                columns: ["kind"], onDelete: .cascade)
        }
        try db.create(
            index: "derivedMaintenanceJob_on_dispatch",
            on: "derivedMaintenanceJob",
            columns: ["kind", "state", "notBefore", "createdAt"])
    }

    private static func createSemanticCorpusGenerationTriggers(
        in db: Database
    ) throws {
        let advance = """
            UPDATE derivedMaintenanceSource
            SET sourceGeneration = sourceGeneration + 1,
                updatedAt = CURRENT_TIMESTAMP
            WHERE kind = 'semantic-corpus';
            """
        try db.execute(sql: """
            CREATE TRIGGER semanticCorpusGeneration_after_segment_insert
            AFTER INSERT ON segment
            BEGIN
                \(advance)
            END
            """)
        try db.execute(sql: """
            CREATE TRIGGER semanticCorpusGeneration_after_segment_update
            AFTER UPDATE OF meetingID, text, deletedAt ON segment
            WHEN OLD.meetingID IS NOT NEW.meetingID
              OR OLD.text IS NOT NEW.text
              OR OLD.deletedAt IS NOT NEW.deletedAt
            BEGIN
                \(advance)
            END
            """)
        try db.execute(sql: """
            CREATE TRIGGER semanticCorpusGeneration_after_segment_delete
            AFTER DELETE ON segment
            BEGIN
                \(advance)
            END
            """)
        try db.execute(sql: """
            CREATE TRIGGER semanticCorpusGeneration_after_meeting_update
            AFTER UPDATE OF transcriptRevision, deletedAt ON meeting
            WHEN OLD.transcriptRevision IS NOT NEW.transcriptRevision
              OR OLD.deletedAt IS NOT NEW.deletedAt
            BEGIN
                \(advance)
            END
            """)
        try db.execute(sql: """
            CREATE TRIGGER semanticCorpusGeneration_after_meeting_delete
            AFTER DELETE ON meeting
            BEGIN
                \(advance)
            END
            """)
    }
}
