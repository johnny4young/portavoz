import Foundation
import GRDB
import PortavozCore

// Immutable versioned summary snapshots + their action items. Split out of
// `MeetingStore.swift` so the core type stays small.
extension MeetingStore {
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
                fingerprint: draft.fingerprint,
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
                actionItems: items,
                fingerprint: record.fingerprint)
            return (draft, record.version)
        }
    }

    /// The latest live snapshot whose material fingerprint matches (D25):
    /// with `language`, an exact cache hit (regenerating would reproduce
    /// it); without, any language — a translation pivot. Pre-fingerprint
    /// snapshots (NULL) never match.
    public func latestSummary(
        _ id: MeetingID,
        recipeID: String = Recipe.general.id,
        fingerprint: String,
        language: String? = nil
    ) async throws -> (draft: SummaryDraft, version: Int)? {
        let meetingKey = id.rawValue.uuidString
        return try await database.read { db in
            var request = SummaryRecord
                .filter(Column("meetingID") == meetingKey)
                .filter(Column("recipeID") == recipeID)
                .filter(Column("fingerprint") == fingerprint)
                .filter(Column("deletedAt") == nil)
                .order(Column("version").desc)
            if let language {
                request = request.filter(Column("language") == language)
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
                actionItems: items,
                fingerprint: record.fingerprint)
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
}
