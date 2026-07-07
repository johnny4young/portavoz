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
public final class MeetingStore: Sendable {
    private let database: DatabaseQueue

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
            path.hasPrefix("/") || path.contains("..")
        {
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

    // MARK: - Summaries (immutable versioned snapshots)

    /// Persists a new snapshot; the version auto-increments per
    /// (meeting, recipe). Existing snapshots are never touched.
    @discardableResult
    public func saveSummary(_ draft: SummaryDraft) async throws -> Int {
        try await database.write { db in
            let meetingKey = draft.meetingID.rawValue.uuidString
            guard try MeetingRecord.exists(db, key: meetingKey) else {
                throw StorageError.meetingNotFound(draft.meetingID)
            }
            let now = Date()
            let version =
                (try Int.fetchOne(
                    db,
                    sql: "SELECT MAX(version) FROM summary WHERE meetingID = ? AND recipeID = ?",
                    arguments: [meetingKey, draft.recipeID]) ?? 0) + 1

            let summaryID = UUID().uuidString
            var summary = SummaryRecord(
                id: summaryID,
                meetingID: meetingKey,
                recipeID: draft.recipeID,
                language: draft.language,
                markdown: draft.markdown,
                version: version,
                createdAt: now,
                deletedAt: nil)
            try summary.insert(db)

            for item in draft.actionItems {
                var record = ActionItemRecord(
                    id: item.id.uuidString,
                    summaryID: summaryID,
                    meetingID: meetingKey,
                    text: item.text,
                    ownerSpeakerID: item.ownerSpeakerID?.rawValue.uuidString,
                    isDone: item.isDone,
                    createdAt: now,
                    updatedAt: now,
                    deletedAt: nil)
                try record.insert(db)
            }
            return version
        }
    }

    /// Loads a snapshot: the latest version by default, or an exact one.
    public func summary(
        _ id: MeetingID, recipeID: String = Recipe.general.id, version: Int? = nil
    ) async throws -> (draft: SummaryDraft, version: Int)? {
        let meetingKey = id.rawValue.uuidString
        return try await database.read { db in
            var request = SummaryRecord
                .filter(Column("meetingID") == meetingKey)
                .filter(Column("recipeID") == recipeID)
                .filter(Column("deletedAt") == nil)
            if let version {
                request = request.filter(Column("version") == version)
            } else {
                request = request.order(Column("version").desc)
            }
            guard let record = try request.fetchOne(db) else { return nil }

            let items = try ActionItemRecord
                .filter(Column("summaryID") == record.id)
                .filter(Column("deletedAt") == nil)
                .order(Column("createdAt"))
                .fetchAll(db).map(\.actionItem)

            let draft = SummaryDraft(
                meetingID: id,
                recipeID: record.recipeID,
                language: record.language,
                markdown: record.markdown,
                actionItems: items)
            return (draft, record.version)
        }
    }

    /// A pending commitment with the meeting it came from.
    public struct OpenActionItem: Sendable {
        public let meetingID: MeetingID
        public let meetingTitle: String
        public let item: ActionItem
    }

    /// Pending action items across all meetings — only from the LATEST
    /// summary snapshot of each (meeting, recipe), so superseded versions
    /// never duplicate their items.
    public func openActionItems(limit: Int = 50) async throws -> [OpenActionItem] {
        try await database.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT actionItem.id AS id,
                           actionItem.text AS text,
                           actionItem.ownerSpeakerID AS ownerSpeakerID,
                           actionItem.meetingID AS meetingID,
                           meeting.title AS title
                    FROM actionItem
                    JOIN summary ON summary.id = actionItem.summaryID
                        AND summary.deletedAt IS NULL
                    JOIN meeting ON meeting.id = actionItem.meetingID
                        AND meeting.deletedAt IS NULL
                    WHERE actionItem.deletedAt IS NULL
                      AND actionItem.isDone = 0
                      AND summary.version = (
                          SELECT MAX(version) FROM summary latest
                          WHERE latest.meetingID = summary.meetingID
                            AND latest.recipeID = summary.recipeID
                            AND latest.deletedAt IS NULL)
                    ORDER BY actionItem.createdAt DESC
                    LIMIT ?
                    """,
                arguments: [limit])
            return rows.map { row in
                OpenActionItem(
                    meetingID: MeetingID(rawValue: UUID(uuidString: row["meetingID"]) ?? UUID()),
                    meetingTitle: row["title"],
                    item: ActionItem(
                        id: UUID(uuidString: row["id"]) ?? UUID(),
                        text: row["text"],
                        ownerSpeakerID: (row["ownerSpeakerID"] as String?)
                            .flatMap { UUID(uuidString: $0) }.map { SpeakerID(rawValue: $0) },
                        isDone: false)
                )
            }
        }
    }

    public func setActionItem(_ id: UUID, done: Bool) async throws {
        try await database.write { db in
            try db.execute(
                sql: "UPDATE actionItem SET isDone = ?, updatedAt = ? WHERE id = ?",
                arguments: [done, Date(), id.uuidString])
        }
    }

    // MARK: - Full-text search

    /// `requireAll: false` turns the tokens into an OR query — what a
    /// natural-language QUESTION needs (AND of every question word almost
    /// never matches a transcript).
    public func search(
        _ query: String, limit: Int = 20, requireAll: Bool = true
    ) async throws -> [SearchHit] {
        let match = Self.ftsQuery(from: query, requireAll: requireAll)
        guard !match.isEmpty else { return [] }
        return try await database.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT segment.id AS segmentID,
                           segment.meetingID AS meetingID,
                           segment.startTime AS startTime,
                           meeting.title AS title,
                           snippet(segmentSearch, 0, '[', ']', '…', 12) AS snippet
                    FROM segmentSearch
                    JOIN segment ON segment.rowid = segmentSearch.rowid
                    JOIN meeting ON meeting.id = segment.meetingID
                    WHERE segmentSearch MATCH ?
                      AND segment.deletedAt IS NULL
                      AND meeting.deletedAt IS NULL
                    ORDER BY bm25(segmentSearch)
                    LIMIT ?
                    """,
                arguments: [match, limit])
            return rows.map { row in
                SearchHit(
                    meetingID: MeetingID(rawValue: UUID(uuidString: row["meetingID"]) ?? UUID()),
                    meetingTitle: row["title"],
                    segmentID: UUID(uuidString: row["segmentID"]) ?? UUID(),
                    snippet: row["snippet"],
                    startTime: row["startTime"])
            }
        }
    }

    /// User text → safe FTS5 MATCH expression: every token quoted,
    /// embedded quotes doubled, so no input can break the query syntax.
    /// Tokens are ANDed (exact search) or ORed (question retrieval).
    static func ftsQuery(from text: String, requireAll: Bool = true) -> String {
        text.split(whereSeparator: \.isWhitespace)
            .map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"" }
            .joined(separator: requireAll ? " " : " OR ")
    }

    // MARK: - Semantic index (local RAG, M8)

    /// Segments (live, non-tombstoned) that still need an embedding.
    public func segmentsNeedingEmbeddings(limit: Int = 512) async throws -> [(id: UUID, text: String)] {
        try await database.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT segment.id AS id, segment.text AS text
                    FROM segment
                    JOIN meeting ON meeting.id = segment.meetingID AND meeting.deletedAt IS NULL
                    WHERE segment.embedding IS NULL AND segment.deletedAt IS NULL
                    ORDER BY segment.createdAt
                    LIMIT ?
                    """,
                arguments: [limit])
            return rows.compactMap { row in
                guard let id = UUID(uuidString: row["id"]) else { return nil }
                return (id, row["text"])
            }
        }
    }

    /// Stores L2-normalized embeddings (Float32 LE blobs) per segment.
    public func storeEmbeddings(_ embeddings: [UUID: [Float]]) async throws {
        try await database.write { db in
            for (id, vector) in embeddings {
                try db.execute(
                    sql: "UPDATE segment SET embedding = ? WHERE id = ?",
                    arguments: [Self.blob(from: vector), id.uuidString])
            }
        }
    }

    /// Brute-force cosine top-k over every embedded segment. Embeddings
    /// are normalized at write time, so cosine is a dot product. At
    /// meeting scale (thousands of rows) this is milliseconds; sqlite-vec
    /// earns its place when it isn't (D19).
    public func searchSemantic(_ query: [Float], limit: Int = 8) async throws -> [SearchHit] {
        try await database.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT segment.id AS segmentID,
                           segment.meetingID AS meetingID,
                           segment.startTime AS startTime,
                           segment.text AS text,
                           segment.embedding AS embedding,
                           meeting.title AS title
                    FROM segment
                    JOIN meeting ON meeting.id = segment.meetingID AND meeting.deletedAt IS NULL
                    WHERE segment.embedding IS NOT NULL AND segment.deletedAt IS NULL
                    """)
            let scored: [(Float, SearchHit)] = rows.compactMap { row in
                guard let blob = row["embedding"] as Data? else { return nil }
                let vector = Self.floats(from: blob)
                guard vector.count == query.count else { return nil }
                var dot: Float = 0
                for index in 0..<vector.count { dot += vector[index] * query[index] }
                let hit = SearchHit(
                    meetingID: MeetingID(rawValue: UUID(uuidString: row["meetingID"]) ?? UUID()),
                    meetingTitle: row["title"],
                    segmentID: UUID(uuidString: row["segmentID"]) ?? UUID(),
                    snippet: row["text"],
                    startTime: row["startTime"])
                return (dot, hit)
            }
            return scored.sorted { $0.0 > $1.0 }.prefix(limit).map(\.1)
        }
    }

    static func blob(from vector: [Float]) -> Data {
        vector.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    static func floats(from data: Data) -> [Float] {
        data.withUnsafeBytes { raw in
            Array(raw.bindMemory(to: Float.self))
        }
    }

    // MARK: - Audio retention (closes the M1 deferral)

    /// Applies each meeting's retention policy: deletes expired audio
    /// directories under `audioRoot` and clears their reference. Returns
    /// the URLs it removed. Transcripts are never touched — the policies
    /// only ever cover raw audio.
    @discardableResult
    public func enforceAudioRetention(audioRoot: URL, now: Date = Date()) async throws -> [URL] {
        let candidates: [(MeetingID, String, AudioRetentionPolicy, Date?, Bool)] =
            try await database.read { db in
                let records = try MeetingRecord
                    .filter(Column("deletedAt") == nil)
                    .filter(Column("audioDirectory") != nil)
                    .fetchAll(db)
                return try records.map { record in
                    let hasTranscript =
                        try SegmentRecord
                        .filter(Column("meetingID") == record.id)
                        .filter(Column("deletedAt") == nil)
                        .filter(Column("isFinal") == true)
                        .fetchCount(db) > 0
                    return (
                        MeetingID(rawValue: UUID(uuidString: record.id) ?? UUID()),
                        record.audioDirectory ?? "",
                        try MeetingRecord.decode(record.retention),
                        record.endedAt,
                        hasTranscript
                    )
                }
            }

        var removed: [URL] = []
        for (meetingID, relative, policy, endedAt, hasTranscript) in candidates {
            let expired: Bool
            switch policy {
            case .keep:
                expired = false
            case .deleteAfter(let days):
                guard let endedAt else { continue }
                expired = now >= endedAt.addingTimeInterval(TimeInterval(days) * 86_400)
            case .deleteAfterTranscription:
                expired = hasTranscript
            }
            guard expired else { continue }

            // Path-traversal guard: the resolved directory must stay under
            // the audio root.
            let directory = audioRoot.appendingPathComponent(relative).standardizedFileURL
            guard directory.path.hasPrefix(audioRoot.standardizedFileURL.path) else { continue }

            if FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.removeItem(at: directory)
            }
            try await database.write { db in
                try db.execute(
                    sql: "UPDATE meeting SET audioDirectory = NULL, updatedAt = ? WHERE id = ?",
                    arguments: [Date(), meetingID.rawValue.uuidString])
            }
            removed.append(directory)
        }
        return removed
    }
}
