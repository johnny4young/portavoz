import Foundation
import GRDB
import PortavozCore

extension MeetingStore {
    /// How far back a previous occurrence is looked for.
    static let meetingBriefOccurrenceWindow: TimeInterval = 180 * 86_400
    /// Sources of events that started longer ago than this are pruned.
    static let meetingBriefSourceRetention: TimeInterval = 86_400

    /// The most recent live, ended meeting started before `date` whose title
    /// equals `title` ignoring case, diacritics and spacing.
    public func previousMeetingOccurrence(
        title: String, before date: Date
    ) async throws -> MeetingID? {
        let key = MeetingBriefLines.titleKey(title)
        guard !key.isEmpty else { return nil }
        return try await database.read { db in
            // SQLite cannot fold diacritics, so the bounded window is compared here.
            let rows = try Row.fetchCursor(
                db,
                sql: """
                    SELECT id, title FROM meeting
                    WHERE deletedAt IS NULL AND endedAt IS NOT NULL
                      AND startedAt < ? AND startedAt >= ?
                    ORDER BY startedAt DESC, id
                    LIMIT 2000
                    """,
                arguments: [date, date.addingTimeInterval(-Self.meetingBriefOccurrenceWindow)])
            while let row = try rows.next() {
                guard MeetingBriefLines.titleKey(row["title"]) == key else { continue }
                return MeetingID(rawValue: try PersistedIdentity.required(
                    row["id"], table: "meeting", column: "id"))
            }
            return nil
        }
    }

    /// Remembers which past meeting an upcoming event continues and builds its
    /// lines unless they are current. A nil, tombstoned or later-starting
    /// source clears the event.
    public func recordMeetingBriefSource(
        eventID: String, eventStartAt: Date, sourceMeetingID: MeetingID?, at now: Date = Date()
    ) async throws {
        try await database.write { db in
            // Foreign keys are on at runtime, so the lines cascade.
            try db.execute(
                sql: "DELETE FROM meetingBriefSource WHERE eventStartAt < ?",
                arguments: [now.addingTimeInterval(-Self.meetingBriefSourceRetention)])
            if let sourceMeetingID {
                try db.execute(
                    sql: """
                        INSERT INTO meetingBriefSource
                            (eventID, eventStartAt, sourceMeetingID, preparedAt, linesBuiltAt)
                        SELECT ?, ?, id, ?, NULL FROM meeting
                        WHERE id = ? AND deletedAt IS NULL AND startedAt < ?
                        ON CONFLICT(eventID) DO UPDATE SET
                            eventStartAt = excluded.eventStartAt,
                            sourceMeetingID = excluded.sourceMeetingID,
                            preparedAt = excluded.preparedAt,
                            linesBuiltAt = CASE WHEN sourceMeetingID = excluded.sourceMeetingID
                                THEN linesBuiltAt END
                        """,
                    arguments: [
                        eventID, eventStartAt, now, sourceMeetingID.rawValue.uuidString, eventStartAt
                    ])
                if db.changesCount > 0 {
                    let current = try Bool.fetchOne(
                        db, sql: "SELECT linesBuiltAt IS NOT NULL FROM meetingBriefSource WHERE eventID = ?",
                        arguments: [eventID]) ?? false
                    // A failed build leaves the lines pending for the next read.
                    if !current {
                        try? db.inSavepoint {
                            try Self.refreshMeetingBriefLines(in: db, forEventID: eventID, at: now)
                            return .commit
                        }
                    }
                    return
                }
            }
            try db.execute(
                sql: "DELETE FROM meetingBriefSource WHERE eventID = ?", arguments: [eventID])
        }
    }

    public func meetingBriefLines(forEventID eventID: String) async throws -> MeetingBriefLines? {
        try await meetingBriefLines(forEventIDs: [eventID])[eventID]
    }

    /// What each person said last time, per upcoming event, rebuilding any
    /// lines a change to the source meeting cleared. Events without a recorded
    /// source or with a tombstoned one are absent, as is one whose rebuild fails.
    public func meetingBriefLines(
        forEventIDs eventIDs: [String]
    ) async throws -> [String: MeetingBriefLines] {
        guard !eventIDs.isEmpty else { return [:] }
        let stored = try await database.read { db in
            try Self.fetchMeetingBriefLines(in: db, for: eventIDs)
        }
        guard !stored.stale.isEmpty else { return stored.lines }
        let rebuilt = try await database.write { db in
            for eventID in stored.stale {
                try? db.inSavepoint {
                    try Self.refreshMeetingBriefLines(in: db, forEventID: eventID)
                    return .commit
                }
            }
            return try Self.fetchMeetingBriefLines(in: db, for: stored.stale)
        }
        return stored.lines.merging(rebuilt.lines) { _, new in new }
    }

    struct StoredMeetingBriefLines {
        var lines: [String: MeetingBriefLines] = [:]
        /// Events whose lines a source change cleared.
        var stale: [String] = []
    }

    static func fetchMeetingBriefLines(
        in db: Database, for eventIDs: [String]
    ) throws -> StoredMeetingBriefLines {
        let placeholders = databaseQuestionMarks(count: eventIDs.count)
        let sources = try Row.fetchAll(
            db,
            sql: """
                SELECT source.eventID, source.eventStartAt, source.sourceMeetingID,
                       source.preparedAt, source.linesBuiltAt
                FROM meetingBriefSource AS source
                JOIN meeting ON meeting.id = source.sourceMeetingID AND meeting.deletedAt IS NULL
                WHERE source.eventID IN (\(placeholders))
                """,
            arguments: StatementArguments(eventIDs))
        let lineRows = try Row.fetchAll(
            db,
            sql: """
                SELECT line.eventID, line.speakerID, line.kind, line.text, line.segmentID,
                       line.time, line.status, line.dueAt,
                       speaker.isMe, speaker.label, speaker.displayName, speaker.personID
                FROM meetingBriefLine AS line
                JOIN speaker ON speaker.id = line.speakerID
                WHERE line.eventID IN (\(placeholders))
                ORDER BY line.eventID, line.ordinal
                """,
            arguments: StatementArguments(eventIDs))
        var people: [String: [MeetingBriefLines.Person]] = [:]
        for row in lineRows {
            let event: String = row["eventID"]
            let speaker = SpeakerID(rawValue: try PersistedIdentity.required(
                row["speakerID"], table: "meetingBriefLine", column: "speakerID"))
            let line = try meetingBriefLine(from: row)
            var known = people[event] ?? []
            // Ordinals keep one person's lines together.
            let previous = known.last?.speakerID == speaker ? known.removeLast().lines : []
            let person = try PersistedIdentity.optional(
                row["personID"], table: "speaker", column: "personID")
            known.append(MeetingBriefLines.Person(
                speakerID: speaker, personID: person.map(PersonID.init(rawValue:)),
                isMe: row["isMe"], label: row["label"], displayName: row["displayName"],
                lines: previous + [line]))
            people[event] = known
        }
        var result = StoredMeetingBriefLines()
        for row in sources {
            let event: String = row["eventID"]
            guard (row["linesBuiltAt"] as Date?) != nil else {
                result.stale.append(event)
                continue
            }
            result.lines[event] = MeetingBriefLines(
                eventID: event, eventStartAt: row["eventStartAt"],
                sourceMeetingID: MeetingID(rawValue: try PersistedIdentity.required(
                    row["sourceMeetingID"], table: "meetingBriefSource", column: "sourceMeetingID")),
                preparedAt: row["preparedAt"], people: people[event] ?? [])
        }
        return result
    }

    private static func meetingBriefLine(from row: Row) throws -> MeetingBriefLines.Line {
        MeetingBriefLines.Line(
            kind: MeetingBriefLines.Kind(rawValue: row["kind"]) ?? .quote, text: row["text"],
            segmentID: try PersistedIdentity.optional(
                row["segmentID"], table: "meetingBriefLine", column: "segmentID"),
            time: row["time"], status: MeetingBriefLines.Status(column: row["status"], due: row["dueAt"]))
    }

    /// Rebuilds one event's lines from its source meeting and marks them built,
    /// even when there are none. A malformed correction history fails the rebuild.
    static func refreshMeetingBriefLines(
        in db: Database, forEventID eventID: String, at timestamp: Date = Date()
    ) throws {
        guard let meetingKey = try String.fetchOne(
            db,
            sql: """
                SELECT source.sourceMeetingID FROM meetingBriefSource AS source
                JOIN meeting ON meeting.id = source.sourceMeetingID AND meeting.deletedAt IS NULL
                WHERE source.eventID = ?
                """,
            arguments: [eventID])
        else { return }
        let meetingID = MeetingID(rawValue: try PersistedIdentity.required(
            meetingKey, table: "meetingBriefSource", column: "sourceMeetingID"))
        let people = try buildMeetingBriefLines(in: db, for: meetingID)
        try db.execute(sql: "DELETE FROM meetingBriefLine WHERE eventID = ?", arguments: [eventID])
        let insert = try db.cachedStatement(sql: """
            INSERT INTO meetingBriefLine
                (eventID, ordinal, speakerID, kind, text, segmentID, time, status, dueAt)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """)
        var ordinal = 0
        for person in people {
            for line in person.lines {
                let status = line.status.column
                try insert.execute(arguments: [
                    eventID, ordinal, person.speakerID.rawValue.uuidString, line.kind.rawValue,
                    line.text, line.segmentID?.uuidString, line.time, status.name, status.due
                ])
                ordinal += 1
            }
        }
        try db.execute(
            sql: "UPDATE meetingBriefSource SET linesBuiltAt = ? WHERE eventID = ?",
            arguments: [timestamp, eventID])
    }
}

private extension MeetingBriefLines.Status {
    var column: (name: String, due: Date?) {
        switch self {
        case .said: ("said", nil)
        case .unresolved: ("unresolved", nil)
        case .open(let due): ("open", due)
        case .closed: ("closed", nil)
        }
    }

    init(column: String, due: Date?) {
        switch column {
        case "said": self = .said
        case "unresolved": self = .unresolved
        case "open": self = .open(due: due)
        default: self = .closed
        }
    }
}
