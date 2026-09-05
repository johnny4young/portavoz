import Foundation
import GRDB
import PortavozCore

/// One exact raw user-note search hit. Generated `enhancedNote` rows have no
/// path into this type or query.
public struct NoteSearchHit: Equatable, Sendable {
    public let noteID: UUID
    public let meetingID: MeetingID
    public let meetingTitle: String
    public let authoredAt: Date
    public let timestamp: TimeInterval
    public let text: String
    public let snippet: String

    public init(
        noteID: UUID,
        meetingID: MeetingID,
        meetingTitle: String,
        authoredAt: Date,
        timestamp: TimeInterval,
        text: String,
        snippet: String
    ) {
        self.noteID = noteID
        self.meetingID = meetingID
        self.meetingTitle = meetingTitle
        self.authoredAt = authoredAt
        self.timestamp = timestamp
        self.text = text
        self.snippet = snippet
    }
}

extension MeetingStore {
    /// Exact FTS5 retrieval over raw notes only. The meeting-relative authoring
    /// offset remains the durable time authority across import and sync; the
    /// absolute instant is derived from the owning meeting.
    public func searchNotes(
        _ query: String,
        limit: Int = 20,
        requireAll: Bool = false
    ) async throws -> [NoteSearchHit] {
        guard limit > 0 else { return [] }
        let match = Self.ftsQuery(from: query, requireAll: requireAll)
        guard !match.isEmpty else { return [] }
        return try await database.read { database in
            let rows = try Row.fetchAll(
                database,
                sql: Self.noteSearchSQL,
                arguments: [match, limit])
            return try rows.map(Self.noteSearchHit)
        }
    }

    private static let noteSearchSQL = """
        SELECT contextItem.id AS noteID,
               contextItem.meetingID AS meetingID,
               meeting.title AS meetingTitle,
               meeting.startedAt AS meetingStartedAt,
               contextItem.timestamp AS timestamp,
               contextItem.content AS content,
               snippet(contextItemSearch, 0, '[', ']', '…', 12) AS snippet
        FROM contextItemSearch
        JOIN contextItem ON contextItem.rowid = contextItemSearch.rowid
        JOIN meeting ON meeting.id = contextItem.meetingID
        WHERE contextItemSearch MATCH ?
          AND contextItem.kind = 'note'
          AND contextItem.deletedAt IS NULL
          AND meeting.deletedAt IS NULL
        ORDER BY rank, contextItem.timestamp, contextItem.id
        LIMIT ?
        """

    private static func noteSearchHit(_ row: Row) throws -> NoteSearchHit {
        let timestamp: TimeInterval = row["timestamp"]
        guard timestamp.isFinite, timestamp >= 0 else {
            throw StorageError.invalidPersistedValue(
                table: "contextItem",
                column: "timestamp",
                value: String(timestamp))
        }
        let startedAt: Date = row["meetingStartedAt"]
        let content: String = row["content"]
        guard content.contains(where: { !$0.isWhitespace }) else {
            throw StorageError.invalidPersistedValue(
                table: "contextItem",
                column: "content",
                value: "empty")
        }
        return NoteSearchHit(
            noteID: try PersistedIdentity.required(
                row["noteID"],
                table: "contextItem",
                column: "id"),
            meetingID: MeetingID(rawValue: try PersistedIdentity.required(
                row["meetingID"],
                table: "contextItem",
                column: "meetingID")),
            meetingTitle: row["meetingTitle"],
            authoredAt: startedAt.addingTimeInterval(timestamp),
            timestamp: timestamp,
            text: content,
            snippet: row["snippet"])
    }
}
