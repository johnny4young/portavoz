import Foundation
import GRDB
import PortavozCore

public enum StorageError: Error, LocalizedError {
    /// D4: the database never stores invalid paths or escapes the audio root.
    case absolutePathRejected(String)
    case meetingNotFound(MeetingID)
    case invalidImportedMeeting(String)
    case invalidRefinedMeeting(String)
    case staleRefineDraft(meetingID: MeetingID, expected: Int, actual: Int)
    case invalidRecordingReservation(String)
    case invalidProcessingJob(String)
    case invalidGenerationRun(String)
    case invalidDataEgressEvent(String)
    case invalidSyncState(String)
    case invalidPersonLink(String)
    case invalidSummaryClaim(String)
    case processingJobNotFound(ProcessingJobID)
    case processingJobLeaseLost(ProcessingJobID)
    case processingJobInputChanged(ProcessingJobID)
    /// Persisted identity is immutable. Corrupt rows must fail loudly rather
    /// than being assigned a fresh UUID and silently becoming another entity.
    case invalidPersistedUUID(table: String, column: String, value: String)
    case invalidPersistedValue(table: String, column: String, value: String)

    public var errorDescription: String? {
        switch self {
        case .absolutePathRejected(let path):
            return "audio paths must be relative to the audio root, got: \(path)"
        case .meetingNotFound(let id):
            return "no such meeting: \(id.rawValue.uuidString)"
        case .invalidImportedMeeting(let reason):
            return "invalid imported meeting: \(reason)"
        case .invalidRefinedMeeting(let reason):
            return "invalid refined meeting: \(reason)"
        case .staleRefineDraft(let meetingID, let expected, let actual):
            return "refine draft for \(meetingID.rawValue.uuidString) expected transcript revision "
                + "\(expected), current revision is \(actual)"
        case .invalidRecordingReservation(let reason):
            return "invalid recording reservation: \(reason)"
        case .invalidProcessingJob(let reason):
            return "invalid processing job: \(reason)"
        case .invalidGenerationRun(let reason):
            return "invalid generation run: \(reason)"
        case .invalidDataEgressEvent(let reason):
            return "invalid data egress event: \(reason)"
        case .invalidSyncState(let reason):
            return "invalid sync state: \(reason)"
        case .invalidPersonLink(let reason):
            return "invalid canonical person link: \(reason)"
        case .invalidSummaryClaim(let reason):
            return "invalid summary claim: \(reason)"
        case .processingJobNotFound(let id):
            return "no such processing job: \(id.rawValue.uuidString)"
        case .processingJobLeaseLost(let id):
            return "processing job lease is no longer owned: \(id.rawValue.uuidString)"
        case .processingJobInputChanged(let id):
            return "processing job input changed before completion: \(id.rawValue.uuidString)"
        case .invalidPersistedUUID(let table, let column, let value):
            return "invalid persisted UUID in \(table).\(column): \(value)"
        case .invalidPersistedValue(let table, let column, let value):
            return "invalid persisted value in \(table).\(column): \(value)"
        }
    }
}

/// Everything persisted about one meeting.
public struct MeetingDetail: Sendable {
    public let meeting: Meeting
    public let speakers: [Speaker]
    public let segments: [TranscriptSegment]
    public let summaries: [SummaryInfo]

    public init(
        meeting: Meeting,
        speakers: [Speaker],
        segments: [TranscriptSegment],
        summaries: [SummaryInfo]
    ) {
        self.meeting = meeting
        self.speakers = speakers
        self.segments = segments
        self.summaries = summaries
    }
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
    /// Complete segment content for retrieval; UI surfaces should prefer the
    /// highlighted, bounded `snippet` below.
    public let text: String
    /// Matched terms wrapped in [brackets] by FTS5.
    public let snippet: String
    public let startTime: TimeInterval
}

/// The SQLite-backed store (GRDB + FTS5, D4 contract in `StorageSchema`).
/// All writes stamp `updatedAt`; user-visible deletion is a tombstone. D37's
/// empty pre-capture reservation is the sole guarded rollback exception.
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
        if let path = meeting.audioDirectory { try StoredAudioPath.validate(path) }
        try await database.write { db in
            let now = Date()
            let existing = try MeetingRecord.fetchOne(
                db, key: meeting.id.rawValue.uuidString)
            let record = try MeetingRecord(
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
                record.generationRunID = existing?.generationRunID
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
            try Self.fetchMeetings(in: db, includeDeleted: includeDeleted)
        }
    }

    /// Content-free aggregate used by launch eligibility and local receipts.
    /// Avoids materializing an entire library when only its cardinality matters.
    public func liveMeetingCount() async throws -> Int {
        try await database.read { db in
            try MeetingRecord
                .filter(Column("deletedAt") == nil)
                .fetchCount(db)
        }
    }

    static func fetchMeetings(
        in database: Database,
        includeDeleted: Bool = false
    ) throws -> [Meeting] {
        var request = MeetingRecord.order(Column("startedAt").desc)
        if !includeDeleted {
            request = request.filter(Column("deletedAt") == nil)
        }
        return try request.fetchAll(database).map { try $0.meeting }
    }

    public func detail(_ id: MeetingID) async throws -> MeetingDetail? {
        return try await database.read { db in
            guard let core = try Self.fetchMeetingReviewCore(id, in: db) else { return nil }
            let key = id.rawValue.uuidString
            let summaries = try SummaryRecord
                .filter(Column("meetingID") == key)
                .filter(Column("deletedAt") == nil)
                .order(
                    Column("createdAt").desc,
                    Column("version").desc,
                    Column("recipeID").asc,
                    Column("id").asc)
                .fetchAll(db)
                .map {
                    SummaryInfo(
                        recipeID: $0.recipeID, language: $0.language,
                        version: $0.version, createdAt: $0.createdAt)
                }
            return MeetingDetail(
                meeting: core.meeting,
                speakers: core.speakers,
                segments: core.segments,
                summaries: summaries)
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
                let record = SpeakerRecord(speaker, createdAt: now, updatedAt: now)
                try record.save(db)
            }
            for segment in segments {
                let record = SegmentRecord(segment, createdAt: now, updatedAt: now)
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

    // MARK: - Trash (soft-deleted meetings)

    /// A soft-deleted meeting and when it was deleted — the "Recently
    /// deleted" list. Tombstones already exist for sync (D4); this just
    /// surfaces them.
    public struct DeletedMeeting: Sendable, Identifiable {
        public let meeting: Meeting
        public let deletedAt: Date
        public var id: MeetingID { meeting.id }
    }

    public func deletedMeetings() async throws -> [DeletedMeeting] {
        try await database.read { db in
            try Self.fetchDeletedMeetings(in: db)
        }
    }

    static func fetchDeletedMeetings(in database: Database) throws -> [DeletedMeeting] {
        try MeetingRecord
            .filter(Column("deletedAt") != nil)
            .order(Column("deletedAt").desc)
            .fetchAll(database)
            .compactMap { record in
                guard let deletedAt = record.deletedAt else { return nil }
                return DeletedMeeting(meeting: try record.meeting, deletedAt: deletedAt)
            }
    }

    /// Undeletes: clearing the meeting's tombstone brings everything back —
    /// children were never tombstoned (queries filter through the meeting).
    public func restore(_ id: MeetingID) async throws {
        try await database.write { db in
            try db.execute(
                sql: "UPDATE meeting SET deletedAt = NULL, updatedAt = ? WHERE id = ?",
                arguments: [Date(), id.rawValue.uuidString])
        }
    }

    /// Permanently removes a SOFT-DELETED meeting and all its rows (the
    /// FTS index cleans itself via GRDB's synchronize triggers). Refuses
    /// live meetings — purging must always go through the trash. Deleting
    /// the audio folder on disk is the caller's job (paths are app-side).
    public func purge(_ id: MeetingID) async throws {
        let key = id.rawValue.uuidString
        try await database.write { db in
            guard
                let record = try MeetingRecord.fetchOne(db, key: key),
                record.deletedAt != nil
            else { return }
            let tables = ["actionItem", "summary", "contextItem", "companionCard", "segment", "speaker"]
            for table in tables {
                try db.execute(
                    sql: "DELETE FROM \(table) WHERE meetingID = ?", arguments: [key])
            }
            try db.execute(sql: "DELETE FROM meeting WHERE id = ?", arguments: [key])
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
                .map { try $0.item }
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

enum StoredAudioPath {
    static func validate(_ path: String) throws {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty, !path.hasPrefix("/"), !components.contains("..") else {
            throw StorageError.absolutePathRejected(path)
        }
    }
}
