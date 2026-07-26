import GRDB

extension StorageSchema {
    /// v15 (D135/NOTES-001): one LLM-enhanced version of the user's own
    /// notes per meeting. The raw `contextItem` notes are never modified —
    /// this is a separate regenerable artifact with generation provenance,
    /// replaced in place on regenerate (its fingerprint answers "already
    /// up to date").
    static func createEnhancedNotes(in db: Database) throws {
        try db.create(table: "enhancedNote") { t in
            t.primaryKey("id", .text)
            t.column("meetingID", .text).notNull().unique().indexed()
                .references("meeting", onDelete: .cascade)
            t.column("markdown", .text).notNull().check(
                sql: "length(trim(markdown)) > 0")
            t.column("language", .text).notNull().check(
                sql: "length(trim(language)) > 0")
            t.column("inputFingerprint", .text).notNull().check(
                sql: "length(trim(inputFingerprint)) > 0")
            t.column("generationRunID", .text).indexed()
                .references("generationRun", onDelete: .setNull)
            t.column("createdAt", .datetime).notNull()
            t.column("updatedAt", .datetime).notNull()
            t.column("deletedAt", .datetime)
        }
    }

    /// The enhanced note is meeting-owned portable content, so it joins the
    /// D92 change journal. Registered with v15 rather than by editing the
    /// v14 trigger list — registered migrations are never edited.
    static func createEnhancedNoteSyncTriggers(in db: Database) throws {
        let portableColumns = ["markdown", "language", "inputFingerprint", "deletedAt"]
        try createTrigger(
            "enhancedNote_sync_ai",
            timing: "AFTER INSERT",
            table: "enhancedNote",
            body: childSyncUpsert(meetingID: "NEW.meetingID", changedAt: "NEW.updatedAt"),
            in: db)
        try createTrigger(
            "enhancedNote_sync_au",
            timing: "AFTER UPDATE OF \(portableColumns.joined(separator: ", "))",
            table: "enhancedNote",
            body: childSyncUpsert(meetingID: "NEW.meetingID", changedAt: "NEW.updatedAt"),
            when: valuesChanged(portableColumns),
            in: db)
        try createTrigger(
            "enhancedNote_sync_ad",
            timing: "AFTER DELETE",
            table: "enhancedNote",
            body: childSyncUpsert(meetingID: "OLD.meetingID", changedAt: "CURRENT_TIMESTAMP"),
            in: db)
    }
}
