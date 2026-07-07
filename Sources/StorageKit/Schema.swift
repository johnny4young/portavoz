import Foundation

/// Storage lands in M1 on GRDB (SQLite) with FTS5 for search and sqlite-vec
/// for the local RAG index. The schema contract, fixed from v1 so sync and
/// sharing never require a painful migration:
///
/// - UUID primary keys everywhere (never auto-increment).
/// - `updated_at` + `deleted_at` tombstones on every syncable table.
/// - Summaries are immutable versioned snapshots.
/// - No absolute file paths in the database — assets resolve relative to
///   the app container.
/// - API keys and voiceprints never live in SQLite (Keychain / encrypted
///   files respectively).
public enum StorageSchema {
    public static let version = 1
}
