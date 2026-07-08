import Foundation
import GRDB
import PortavozCore

public enum StorageError: Error, LocalizedError {
    /// D4: the database never stores absolute paths (nor escapes the root).
    case absolutePathRejected(String)
    case meetingNotFound(MeetingID)

    public var errorDescription: String? {
        switch self {
        case .absolutePathRejected(let path):
            return "audioDirectory must be relative to the audio root, got: \(path)"
        case .meetingNotFound(let id):
            return "no such meeting: \(id.rawValue.uuidString)"
        }
    }
}

/// Everything persisted about one meeting.
public struct MeetingDetail: Sendable {
    public let meeting: Meeting
    public let speakers: [Speaker]
    public let segments: [TranscriptSegment]
    public let summaries: [SummaryInfo]
}

/// Snapshot metadata (the markdown itself loads via `summary(...)`).
public struct SummaryInfo: Sendable {
    public let recipeID: String
    public let language: String
    public let version: Int
    public let createdAt: Date
}

/// One full-text search hit, newest meeting first.
public struct SearchHit: Sendable {
    public let meetingID: MeetingID
    public let meetingTitle: String
    public let segmentID: UUID
    /// Matched terms wrapped in [brackets] by FTS5.
    public let snippet: String
    public let startTime: TimeInterval
}

/// The SQLite-backed store (GRDB + FTS5, D4 contract in `StorageSchema`).
/// All writes stamp `updatedAt`; deletion is always a tombstone.
///
/// The CRUD surface is split across `MeetingStore+Summaries.swift`,
/// `MeetingStore+Search.swift`, and `MeetingStore+Retention.swift` — this
/// core file keeps the meeting/speaker/segment and context-item paths.
public final class MeetingStore: Sendable {
    /// Internal (not `private`) so the extension files above can reach it;
    /// still never exposed publicly.
    let database: DatabaseQueue

    /// `~/Library/Application Support/Portavoz/portavoz.sqlite`
    public static var defaultDatabaseURL: URL {
        let base =
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
                "Library/Application Support")
        return base.appendingPathComponent("Portavoz/portavoz.sqlite")
    }

    public init(databaseURL: URL) throws {
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        self.database = try DatabaseQueue(path: databaseURL.path)
        try StorageSchema.migrator().migrate(database)
    }

    /// Ephemeral store for tests and previews.
    public static func inMemory() throws -> MeetingStore {
        try MeetingStore(database: DatabaseQueue())
    }

    private init(database: DatabaseQueue) throws {
        self.database = database
        try StorageSchema.migrator().migrate(database)
    }

    // MARK: - Meetings

    /// Insert-or-update; `createdAt` survives updates, `updatedAt` bumps.
    public func save(_ meeting: Meeting) async throws {
        if let path = meeting.audioDirectory,
            path.hasPrefix("/") || path.contains("..") {
            throw StorageError.absolutePathRejected(path)
        }
        try await database.write { db in
            let now = Date()
            let existing = try MeetingRecord.fetchOne(
                db, key: meeting.id.rawValue.uuidString)
            var record = try MeetingRecord(
                meeting, createdAt: existing?.createdAt ?? now, updatedAt: now,
                deletedAt: existing?.deletedAt)
            try record.save(db)
        }
    }

    public func save(_ speakers: [Speaker]) async throws {
        try await database.write { db in
            let now = Date()
            for speaker in speakers {
                let existing = try SpeakerRecord.fetchOne(
                    db, key: speaker.id.rawValue.uuidString)
                var record = SpeakerRecord(
                    speaker, createdAt: existing?.createdAt ?? now, updatedAt: now)
                record.deletedAt = existing?.deletedAt
                try record.save(db)
            }
        }
    }

    public func save(_ segments: [TranscriptSegment]) async throws {
        try await database.write { db in
            let now = Date()
            for segment in segments {
                let existing = try SegmentRecord.fetchOne(db, key: segment.id.uuidString)
                var record = SegmentRecord(
                    segment, createdAt: existing?.createdAt ?? now, updatedAt: now)
                record.deletedAt = existing?.deletedAt
                // Text unchanged → the stored embedding stays valid.
                if existing?.text == segment.text {
                    record.embedding = existing?.embedding
                }
                try record.save(db)
            }
        }
    }

    public func meetings(includeDeleted: Bool = false) async throws -> [Meeting] {
        try await database.read { db in
            var request = MeetingRecord.order(Column("startedAt").desc)
            if !includeDeleted {
                request = request.filter(Column("deletedAt") == nil)
            }
            return try request.fetchAll(db).map { try $0.meeting }
        }
    }

    public func detail(_ id: MeetingID) async throws -> MeetingDetail? {
        let key = id.rawValue.uuidString
        return try await database.read { db in
            guard
                let meetingRecord = try MeetingRecord
                    .filter(Column("id") == key)
                    .filter(Column("deletedAt") == nil)
                    .fetchOne(db)
            else { return nil }

            let speakers = try SpeakerRecord
                .filter(Column("meetingID") == key)
                .filter(Column("deletedAt") == nil)
                .fetchAll(db).map(\.speaker)
            let segments = try SegmentRecord
                .filter(Column("meetingID") == key)
                .filter(Column("deletedAt") == nil)
                .order(Column("startTime"))
                .fetchAll(db).map(\.segment)
            let summaries = try SummaryRecord
                .filter(Column("meetingID") == key)
                .filter(Column("deletedAt") == nil)
                .order(Column("createdAt").desc)
                .fetchAll(db)
                .map {
                    SummaryInfo(
                        recipeID: $0.recipeID, language: $0.language,
                        version: $0.version, createdAt: $0.createdAt)
                }
            return MeetingDetail(
                meeting: try meetingRecord.meeting,
                speakers: speakers, segments: segments, summaries: summaries)
        }
    }

    /// Atomically retires a meeting's current transcript (tombstones, D4)
    /// and installs a new cast of segments + speakers — the quality
    /// re-pass path (D7): Whisper replaces the live transcript once the
    /// meeting is over. Summary snapshots are untouched history.
    public func replaceCast(
        for id: MeetingID,
        speakers: [Speaker],
        segments: [TranscriptSegment]
    ) async throws {
        let key = id.rawValue.uuidString
        try await database.write { db in
            guard try MeetingRecord.exists(db, key: key) else {
                throw StorageError.meetingNotFound(id)
            }
            let now = Date()
            try db.execute(
                sql: "UPDATE segment SET deletedAt = ?, updatedAt = ? WHERE meetingID = ? AND deletedAt IS NULL",
                arguments: [now, now, key])
            try db.execute(
                sql: "UPDATE speaker SET deletedAt = ?, updatedAt = ? WHERE meetingID = ? AND deletedAt IS NULL",
                arguments: [now, now, key])
            for speaker in speakers {
                var record = SpeakerRecord(speaker, createdAt: now, updatedAt: now)
                try record.save(db)
            }
            for segment in segments {
                var record = SegmentRecord(segment, createdAt: now, updatedAt: now)
                try record.save(db)
            }
        }
    }

    /// Tombstone, never a hard delete (sync needs to see it, D4).
    public func delete(_ id: MeetingID) async throws {
        try await database.write { db in
            try db.execute(
                sql: "UPDATE meeting SET deletedAt = ?, updatedAt = ? WHERE id = ?",
                arguments: [Date(), Date(), id.rawValue.uuidString])
        }
    }

    // MARK: - Context items (D28: the user's notes = intent)

    public func save(_ items: [ContextItem]) async throws {
        try await database.write { db in
            let now = Date()
            for item in items {
                let existing = try ContextItemRecord.fetchOne(db, key: item.id.uuidString)
                var record = ContextItemRecord(
                    item, createdAt: existing?.createdAt ?? now, updatedAt: now)
                record.deletedAt = existing?.deletedAt
                try record.save(db)
            }
        }
    }

    public func contextItems(for id: MeetingID) async throws -> [ContextItem] {
        try await database.read { db in
            try ContextItemRecord
                .filter(Column("meetingID") == id.rawValue.uuidString)
                .filter(Column("deletedAt") == nil)
                .order(Column("timestamp"))
                .fetchAll(db)
                .compactMap(\.item)
        }
    }

    public func deleteContextItem(_ id: UUID) async throws {
        try await database.write { db in
            try db.execute(
                sql: "UPDATE contextItem SET deletedAt = ?, updatedAt = ? WHERE id = ?",
                arguments: [Date(), Date(), id.uuidString])
        }
    }
}
