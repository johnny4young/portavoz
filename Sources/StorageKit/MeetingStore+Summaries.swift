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
            return try Self.insertSummarySnapshot(draft, at: Date(), in: db)
        }
    }

    /// Transaction-scoped primitive shared by direct saves and durable job
    /// completion. Callers must first prove that the meeting is live and that
    /// any processing lease/input guards still hold.
    static func insertSummarySnapshot(
        _ draft: SummaryDraft,
        at timestamp: Date,
        in db: Database
    ) throws -> Int {
        let meetingKey = draft.meetingID.rawValue.uuidString
        let version =
            (try Int.fetchOne(
                db,
                sql: "SELECT MAX(version) FROM summary WHERE meetingID = ? AND recipeID = ?",
                arguments: [meetingKey, draft.recipeID]) ?? 0) + 1

        let summaryID = UUID().uuidString
        let summary = SummaryRecord(
            id: summaryID,
            meetingID: meetingKey,
            recipeID: draft.recipeID,
            language: draft.language,
            markdown: draft.markdown,
            version: version,
            fingerprint: draft.fingerprint,
            createdAt: timestamp,
            deletedAt: nil)
        try summary.insert(db)

        for item in draft.actionItems {
            let record = ActionItemRecord(
                id: item.id.uuidString,
                summaryID: summaryID,
                meetingID: meetingKey,
                text: item.text,
                ownerSpeakerID: item.ownerSpeakerID?.rawValue.uuidString,
                isDone: item.isDone,
                createdAt: timestamp,
                updatedAt: timestamp,
                deletedAt: nil)
            try record.insert(db)
        }
        return version
    }

    /// Loads a snapshot: the latest version by default, or an exact one.
    public func summary(
        _ id: MeetingID, recipeID: String = Recipe.general.id, version: Int? = nil
    ) async throws -> (draft: SummaryDraft, version: Int)? {
        let meetingKey = id.rawValue.uuidString
        return try await database.read { db in
            guard try MeetingRecord
                .filter(Column("id") == meetingKey)
                .filter(Column("deletedAt") == nil)
                .fetchCount(db) > 0
            else { return nil }
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
            _ = try PersistedIdentity.required(
                record.id, table: SummaryRecord.databaseTableName, column: "id")

            let items = try ActionItemRecord
                .filter(Column("summaryID") == record.id)
                .filter(Column("deletedAt") == nil)
                .order(Column("createdAt"))
                .fetchAll(db).map { try $0.actionItem }

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
            guard try MeetingRecord
                .filter(Column("id") == meetingKey)
                .filter(Column("deletedAt") == nil)
                .fetchCount(db) > 0
            else { return nil }
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
            _ = try PersistedIdentity.required(
                record.id, table: SummaryRecord.databaseTableName, column: "id")

            let items = try ActionItemRecord
                .filter(Column("summaryID") == record.id)
                .filter(Column("deletedAt") == nil)
                .order(Column("createdAt"))
                .fetchAll(db).map { try $0.actionItem }

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

    /// A named participant and how many meetings they appear in.
    public struct LibraryParticipant: Sendable, Equatable, Identifiable {
        public let name: String
        public let meetings: Int
        public var id: String { name }
    }

    /// Library-wide people/commitment facts for the Insights dashboard.
    public struct LibraryFacts: Sendable, Equatable {
        /// Named (non-"Me") participants by how many meetings they appear
        /// in — only names the user confirmed, never raw S-labels.
        public let topParticipants: [LibraryParticipant]
        public let openActionItems: Int
        public let doneActionItems: Int
    }

    /// Raw material for the Insights "Hallazgos ✦" findings: the transcript
    /// and the latest summary's markdown + action-item count, per meeting.
    /// The caller decides what counts as a "decision" (parsing is an
    /// intelligence concern, not a storage one).
    public struct FindingInput: Sendable, Equatable {
        public let transcript: String
        public let summaryMarkdown: String?
        public let actionItemCount: Int
    }

    public func findingInputs(
        for meetingIDs: [MeetingID]
    ) async throws -> [MeetingID: FindingInput] {
        guard !meetingIDs.isEmpty else { return [:] }
        let ids = meetingIDs.map { $0.rawValue.uuidString }
        return try await database.read { db in
            let placeholders = databaseQuestionMarks(count: ids.count)
            let transcripts = try Row.fetchAll(
                db,
                sql: """
                    SELECT meetingID, GROUP_CONCAT(text, ' ') AS transcript
                    FROM segment
                    JOIN meeting ON meeting.id = segment.meetingID
                        AND meeting.deletedAt IS NULL
                    WHERE segment.deletedAt IS NULL
                      AND segment.meetingID IN (\(placeholders))
                    GROUP BY segment.meetingID
                    """,
                arguments: StatementArguments(ids))
            var byMeeting: [String: (String, String?, Int)] = [:]
            for row in transcripts {
                byMeeting[row["meetingID"]] = (row["transcript"] ?? "", nil, 0)
            }

            // The newest summary per meeting, and its action-item count.
            let summaries = try Row.fetchAll(
                db,
                sql: """
                    SELECT s.meetingID AS meetingID, s.markdown AS markdown,
                           (SELECT COUNT(*) FROM actionItem ai
                            WHERE ai.summaryID = s.id AND ai.deletedAt IS NULL) AS items
                    FROM summary s
                    JOIN meeting ON meeting.id = s.meetingID
                        AND meeting.deletedAt IS NULL
                    WHERE s.deletedAt IS NULL
                      AND s.meetingID IN (\(placeholders))
                      AND s.version = (
                          SELECT MAX(l.version) FROM summary l
                          WHERE l.meetingID = s.meetingID AND l.deletedAt IS NULL)
                    """,
                arguments: StatementArguments(ids))
            for row in summaries {
                let key: String = row["meetingID"]
                let existing = byMeeting[key] ?? ("", nil, 0)
                byMeeting[key] = (existing.0, row["markdown"], row["items"])
            }

            var result: [MeetingID: FindingInput] = [:]
            for (key, value) in byMeeting {
                let uuid = try PersistedIdentity.required(
                    key, table: "meeting", column: "id")
                result[MeetingID(rawValue: uuid)] = FindingInput(
                    transcript: value.0, summaryMarkdown: value.1, actionItemCount: value.2)
            }
            return result
        }
    }

    public func libraryFacts(topLimit: Int = 8) async throws -> LibraryFacts {
        try await database.read { db in
            let participantRows = try Row.fetchAll(
                db,
                sql: """
                    SELECT displayName AS name,
                           COUNT(DISTINCT speaker.meetingID) AS meetings
                    FROM speaker
                    JOIN meeting ON meeting.id = speaker.meetingID
                        AND meeting.deletedAt IS NULL
                    WHERE speaker.deletedAt IS NULL
                      AND speaker.isMe = 0
                      AND speaker.displayName IS NOT NULL
                      AND TRIM(speaker.displayName) != ''
                    GROUP BY LOWER(TRIM(speaker.displayName))
                    ORDER BY meetings DESC, LOWER(TRIM(speaker.displayName)) ASC
                    LIMIT ?
                    """,
                arguments: [topLimit])
            // Same latest-snapshot rule as `openActionItems`: superseded
            // summary versions must not double-count their items.
            let counts = try Row.fetchOne(
                db,
                sql: """
                    SELECT SUM(actionItem.isDone = 0) AS open,
                           SUM(actionItem.isDone = 1) AS done
                    FROM actionItem
                    JOIN summary ON summary.id = actionItem.summaryID
                        AND summary.deletedAt IS NULL
                    JOIN meeting ON meeting.id = actionItem.meetingID
                        AND meeting.deletedAt IS NULL
                    WHERE actionItem.deletedAt IS NULL
                      AND summary.version = (
                          SELECT MAX(version) FROM summary latest
                          WHERE latest.meetingID = summary.meetingID
                            AND latest.recipeID = summary.recipeID
                            AND latest.deletedAt IS NULL)
                    """)
            return LibraryFacts(
                topParticipants: participantRows.map {
                    LibraryParticipant(name: $0["name"], meetings: $0["meetings"])
                },
                openActionItems: counts?["open"] ?? 0,
                doneActionItems: counts?["done"] ?? 0)
        }
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
            return try rows.map { row in
                OpenActionItem(
                    meetingID: MeetingID(rawValue: try PersistedIdentity.required(
                        row["meetingID"], table: "actionItem", column: "meetingID")),
                    meetingTitle: row["title"],
                    item: ActionItem(
                        id: try PersistedIdentity.required(
                            row["id"], table: "actionItem", column: "id"),
                        text: row["text"],
                        ownerSpeakerID: try PersistedIdentity.optional(
                            row["ownerSpeakerID"] as String?,
                            table: "actionItem", column: "ownerSpeakerID"
                        ).map { SpeakerID(rawValue: $0) },
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
