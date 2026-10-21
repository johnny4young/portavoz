import Foundation
import GRDB
import PortavozCore

extension MeetingStore {
    /// Finished, live meetings a dictation can go to: the one recorded while it
    /// was dictated first, then the newest. Meetings still recording are left
    /// out because their notes belong to the live session.
    public func meetingsForDictation(
        createdAt: Date, limit: Int
    ) async throws -> [DictationMeetingChoice] {
        guard (1...Self.maximumDictationPageSize).contains(limit) else { return [] }
        return try await database.read { database in
            try Row.fetchAll(
                database,
                sql: """
                    SELECT id, title, startedAt,
                           (startedAt <= :at AND endedAt >= :at) AS containsDictation
                    FROM meeting
                    WHERE deletedAt IS NULL AND endedAt IS NOT NULL AND lifecycleState != 'recording'
                    ORDER BY containsDictation DESC, startedAt DESC, id DESC
                    LIMIT :limit
                    """,
                arguments: ["at": createdAt, "limit": limit]
            ).map { row in
                let rawID: String = row["id"]
                guard let uuid = UUID(uuidString: rawID) else {
                    throw StorageError.invalidPersistedUUID(table: "meeting", column: "id", value: rawID)
                }
                return DictationMeetingChoice(
                    id: MeetingID(rawValue: uuid), title: row["title"], startedAt: row["startedAt"],
                    containsDictation: row["containsDictation"])
            }
        }
    }

    /// Copies a dictation into a finished meeting's notes, at the moment it was
    /// dictated when that falls inside the meeting, otherwise at its end.
    public func addDictationToMeeting(
        _ dictationID: DictationRecordID, meetingID: MeetingID, at now: Date = Date()
    ) async throws -> AddDictationToMeetingOutcome {
        try await database.write { database in
            let dictationKey = dictationID.rawValue.uuidString
            let meetingKey = meetingID.rawValue.uuidString
            guard let dictation = try Row.fetchOne(
                database, sql: "SELECT text, createdAt FROM dictationRecord WHERE id = ?", arguments: [dictationKey])
            else { return .dictationMissing }
            guard let meeting = try Row.fetchOne(
                database,
                sql: """
                    SELECT startedAt, endedAt FROM meeting
                    WHERE id = ? AND deletedAt IS NULL AND endedAt IS NOT NULL AND lifecycleState != 'recording'
                    """,
                arguments: [meetingKey])
            else { return .meetingUnavailable }
            if try Self.liveDictationNote(dictationKey, meetingKey, in: database) { return .alreadyAdded }
            // A tombstoned copy no longer counts; its link makes room for the new one.
            try database.execute(
                sql: "DELETE FROM dictationMeetingNote WHERE dictationID = ? AND meetingID = ?",
                arguments: [dictationKey, meetingKey])

            let startedAt: Date = meeting["startedAt"]
            let endedAt: Date = meeting["endedAt"]
            let dictatedAt: Date = dictation["createdAt"]
            let duration = max(0, endedAt.timeIntervalSince(startedAt))
            let offset = min(max(0, dictatedAt.timeIntervalSince(startedAt)), duration)
            let note = ContextItem(meetingID: meetingID, kind: .note, content: dictation["text"], timestamp: offset)
            try ContextItemRecord(note, createdAt: now, updatedAt: now).insert(database)
            try database.execute(
                sql: """
                    INSERT INTO dictationMeetingNote (dictationID, meetingID, contextItemID, createdAt)
                    VALUES (?, ?, ?, ?)
                    """,
                arguments: [dictationKey, meetingKey, note.id.uuidString, now])
            let tidied = try Bool.fetchOne(
                database,
                sql: "SELECT EXISTS(SELECT 1 FROM enhancedNote WHERE meetingID = ? AND deletedAt IS NULL)",
                arguments: [meetingKey]) ?? false
            return .added(noteID: note.id, tidiedNotes: tidied)
        }
    }

    /// Meetings whose live notes still hold a copy of each dictation.
    public func dictationMeetingLinks(
        for dictationIDs: [DictationRecordID]
    ) async throws -> [DictationRecordID: [DictationMeetingLink]] {
        guard !dictationIDs.isEmpty else { return [:] }
        let keys = dictationIDs.map(\.rawValue.uuidString)
        return try await database.read { database in
            let placeholders = Array(repeating: "?", count: keys.count).joined(separator: ", ")
            let rows = try Row.fetchAll(
                database,
                sql: """
                    SELECT link.dictationID, meeting.id AS meetingID, meeting.title
                    FROM dictationMeetingNote AS link
                    JOIN contextItem ON contextItem.id = link.contextItemID AND contextItem.deletedAt IS NULL
                    JOIN meeting ON meeting.id = link.meetingID AND meeting.deletedAt IS NULL
                    WHERE link.dictationID IN (\(placeholders))
                    ORDER BY link.createdAt
                    """,
                arguments: StatementArguments(keys))
            var links: [DictationRecordID: [DictationMeetingLink]] = [:]
            for row in rows {
                guard let dictation = UUID(uuidString: row["dictationID"]),
                      let meeting = UUID(uuidString: row["meetingID"])
                else { continue }
                links[DictationRecordID(rawValue: dictation), default: []].append(
                    DictationMeetingLink(meetingID: MeetingID(rawValue: meeting), title: row["title"]))
            }
            return links
        }
    }

    private static func liveDictationNote(
        _ dictation: String, _ meeting: String, in database: Database
    ) throws -> Bool {
        try Bool.fetchOne(
            database,
            sql: """
                SELECT EXISTS(
                    SELECT 1 FROM dictationMeetingNote AS link
                    JOIN contextItem ON contextItem.id = link.contextItemID AND contextItem.deletedAt IS NULL
                    WHERE link.dictationID = ? AND link.meetingID = ?)
                """,
            arguments: [dictation, meeting]) ?? false
    }
}
