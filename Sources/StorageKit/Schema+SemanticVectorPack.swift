import GRDB

extension StorageSchema {
    /// v64: one version for every input the in-memory semantic pack reads.
    /// Triggers advance it inside the writing transaction, so any connection or
    /// process reads a version that matches its own snapshot.
    static func registerSemanticVectorPackVersionMigration(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v64") { db in
            try db.execute(sql: """
                INSERT INTO derivedMaintenanceSource (kind, sourceGeneration, updatedAt)
                VALUES ('\(semanticVectorPackSourceKind)', 0, CURRENT_TIMESTAMP)
                """)
            try createSemanticVectorPackVersionTriggers(in: db)
        }
    }

    static let semanticVectorPackSourceKind = "semantic-vector-pack"

    private static func createSemanticVectorPackVersionTriggers(in db: Database) throws {
        func change(_ table: String, _ columns: [String]) -> String {
            "AFTER UPDATE OF \(columns.joined(separator: ", ")) ON \(table) WHEN \(valuesChanged(columns))"
        }
        var events: [(name: String, event: String)] = [
            ("segment_insert", "AFTER INSERT ON segment"),
            ("segment_delete", "AFTER DELETE ON segment"),
            ("segment_update", change(
                "segment", ["id", "meetingID", "embedding", "embeddingFingerprint", "deletedAt"])),
            ("meeting_insert", "AFTER INSERT ON meeting"),
            ("meeting_delete", "AFTER DELETE ON meeting"),
            ("meeting_update", change("meeting", ["transcriptRevision", "deletedAt"]))
        ]
        for table in [
            "segmentCorrectedText", "transcriptStructuralSearchRow", "transcriptCorrection",
            "transcriptCorrectionSearchState", "transcriptCorrectionTarget"
        ] {
            events += ["INSERT", "UPDATE", "DELETE"].map {
                ("\(table)_\($0.lowercased())", "AFTER \($0) ON \(table)")
            }
        }
        for trigger in events {
            try db.execute(sql: """
                CREATE TRIGGER semanticVectorPack_after_\(trigger.name)
                \(trigger.event)
                BEGIN
                    UPDATE derivedMaintenanceSource
                    SET sourceGeneration = sourceGeneration + 1
                    WHERE kind = '\(semanticVectorPackSourceKind)';
                END
                """)
        }
    }
}
