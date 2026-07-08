import Foundation
import GRDB

/// The v1 schema, executing the D4 contract frozen since M0:
///
/// - UUID primary keys everywhere (never auto-increment).
/// - `updatedAt` + `deletedAt` tombstones on every syncable table.
/// - Summaries are immutable versioned snapshots (action items are the
///   deliberate mutable exception: users check them off, so they live in
///   their own table keyed to a snapshot).
/// - No absolute file paths in the database — audio resolves relative to
///   the app's audio root.
/// - API keys and voiceprints never live in SQLite (Keychain / encrypted
///   files respectively).
/// - `visibility` reserved since v1 for the sharing ladder (D12).
///
/// sqlite-vec (embeddings for local RAG) intentionally waits for M8 — it
/// needs a C extension and nothing before RAG reads vectors.
public enum StorageSchema {
    public static let version = 4

    // Registro secuencial de migraciones (una por versión de esquema);
    // cuerpo inherentemente largo que crece con cada migración.
    // swiftlint:disable:next function_body_length
    static func migrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1") { db in
            try db.create(table: "meeting") { t in
                t.primaryKey("id", .text)
                t.column("title", .text).notNull()
                t.column("startedAt", .datetime).notNull()
                t.column("endedAt", .datetime)
                t.column("language", .text)
                t.column("audioDirectory", .text)
                t.column("retention", .text).notNull()
                t.column("visibility", .text).notNull().defaults(to: "private")
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
                t.column("deletedAt", .datetime)
            }

            try db.create(table: "speaker") { t in
                t.primaryKey("id", .text)
                t.column("meetingID", .text).notNull().indexed()
                    .references("meeting", onDelete: .cascade)
                t.column("label", .text).notNull()
                t.column("displayName", .text)
                t.column("isMe", .boolean).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
                t.column("deletedAt", .datetime)
            }

            try db.create(table: "segment") { t in
                t.primaryKey("id", .text)
                t.column("meetingID", .text).notNull().indexed()
                    .references("meeting", onDelete: .cascade)
                t.column("speakerID", .text).indexed()
                t.column("channel", .text).notNull()
                t.column("text", .text).notNull()
                t.column("language", .text)
                t.column("startTime", .double).notNull()
                t.column("endTime", .double).notNull()
                t.column("confidence", .double)
                t.column("isFinal", .boolean).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
                t.column("deletedAt", .datetime)
            }

            // Immutable snapshot: rows are only ever inserted (or
            // tombstoned for sync); a (meeting, recipe) pair grows a new
            // version per pass.
            try db.create(table: "summary") { t in
                t.primaryKey("id", .text)
                t.column("meetingID", .text).notNull().indexed()
                    .references("meeting", onDelete: .cascade)
                t.column("recipeID", .text).notNull()
                t.column("language", .text).notNull()
                t.column("markdown", .text).notNull()
                t.column("version", .integer).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("deletedAt", .datetime)
                t.uniqueKey(["meetingID", "recipeID", "version"])
            }

            try db.create(table: "actionItem") { t in
                t.primaryKey("id", .text)
                t.column("summaryID", .text).notNull().indexed()
                    .references("summary", onDelete: .cascade)
                t.column("meetingID", .text).notNull().indexed()
                t.column("text", .text).notNull()
                t.column("ownerSpeakerID", .text)
                t.column("isDone", .boolean).notNull().defaults(to: false)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
                t.column("deletedAt", .datetime)
            }

            // Full-text search over segment text, kept in sync with the
            // content table by GRDB-generated triggers.
            try db.create(virtualTable: "segmentSearch", using: FTS5()) { t in
                t.synchronize(withTable: "segment")
                t.tokenizer = .unicode61()
                t.column("text")
            }
        }

        // v2 (M8): per-segment sentence embedding for local RAG. A plain
        // BLOB (Float32 LE, L2-normalized) + brute-force cosine — at
        // meeting scale this beats carrying a C extension; sqlite-vec
        // arrives when the numbers say so (D19).
        migrator.registerMigration("v2") { db in
            try db.alter(table: "segment") { t in
                t.add(column: "embedding", .blob)
            }
        }

        // v3 (M10/D28): the user's own notes during the meeting — intent
        // that guides the summary. Timestamped to interleave with the
        // transcript; tombstoned like everything else (D4).
        migrator.registerMigration("v3") { db in
            try db.create(table: "contextItem") { t in
                t.primaryKey("id", .text)
                t.column("meetingID", .text).notNull()
                    .references("meeting", onDelete: .cascade)
                t.column("kind", .text).notNull()
                t.column("content", .text).notNull()
                t.column("timestamp", .double).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
                t.column("deletedAt", .datetime)
            }
            try db.create(index: "contextItem_on_meetingID", on: "contextItem", columns: ["meetingID"])
        }

        // v4 (D25): material fingerprint per summary snapshot — the cache
        // key that makes regenerating free and turns a snapshot in another
        // language into a translation pivot. Nullable: old snapshots simply
        // never match.
        migrator.registerMigration("v4") { db in
            try db.alter(table: "summary") { t in
                t.add(column: "fingerprint", .text)
            }
        }

        return migrator
    }
}
