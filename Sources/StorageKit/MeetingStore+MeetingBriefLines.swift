import Foundation
import GRDB
import PortavozCore

extension MeetingStore {
    /// How far back a previous occurrence is looked for.
    static let meetingBriefOccurrenceWindow: TimeInterval = 180 * 86_400
    /// Sources of events that started longer ago than this are pruned.
    static let meetingBriefSourceRetention: TimeInterval = 86_400

    /// The most recent live meeting that ended by `date` whose title equals
    /// `title` ignoring case, diacritics and spacing. Ending by the event's
    /// start keeps an ongoing event's own recording out.
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
                    WHERE deletedAt IS NULL AND endedAt <= ?
                      AND startedAt < ? AND startedAt >= ?
                    ORDER BY startedAt DESC, id
                    LIMIT 2000
                    """,
                arguments: [date, date, date.addingTimeInterval(-Self.meetingBriefOccurrenceWindow)])
            while let row = try rows.next() {
                guard MeetingBriefLines.titleKey(row["title"]) == key else { continue }
                return MeetingID(rawValue: try PersistedIdentity.required(
                    row["id"], table: "meeting", column: "id"))
            }
            return nil
        }
    }

    /// Remembers which past meeting an event occurrence continues and builds
    /// its lines unless they are current. A nil or tombstoned source, or one
    /// that had not ended by the event's start, clears the occurrence.
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
                        WHERE id = ? AND deletedAt IS NULL AND startedAt < ? AND endedAt <= ?
                        ON CONFLICT(eventID, eventStartAt) DO UPDATE SET
                            sourceMeetingID = excluded.sourceMeetingID,
                            preparedAt = excluded.preparedAt,
                            linesBuiltAt = CASE WHEN sourceMeetingID = excluded.sourceMeetingID
                                THEN linesBuiltAt END
                        """,
                    arguments: [
                        eventID, eventStartAt, now, sourceMeetingID.rawValue.uuidString,
                        eventStartAt, eventStartAt
                    ])
                if db.changesCount > 0 {
                    let row = try Row.fetchOne(
                        db,
                        sql: """
                            SELECT id, linesBuiltAt IS NOT NULL AS current FROM meetingBriefSource
                            WHERE eventID = ? AND eventStartAt = ?
                            """,
                        arguments: [eventID, eventStartAt])
                    if let row, !(row["current"] as Bool) {
                        try Self.rebuildMeetingBriefLines(in: db, sourceID: row["id"], at: now)
                    }
                    return
                }
            }
            try db.execute(
                sql: "DELETE FROM meetingBriefSource WHERE eventID = ? AND eventStartAt = ?",
                arguments: [eventID, eventStartAt])
        }
    }

    public func meetingBriefLines(
        for occurrence: MeetingBriefLines.Occurrence
    ) async throws -> MeetingBriefLines? {
        try await meetingBriefLines(for: [occurrence])[occurrence]
    }

    /// What each person said last time, per event occurrence, rebuilding any
    /// lines a change to the source meeting cleared. Occurrences without a
    /// recorded source or with a tombstoned one are absent.
    public func meetingBriefLines(
        for occurrences: [MeetingBriefLines.Occurrence]
    ) async throws -> [MeetingBriefLines.Occurrence: MeetingBriefLines] {
        guard !occurrences.isEmpty else { return [:] }
        let stored = try await database.read { db in
            try Self.fetchMeetingBriefLines(in: db, for: occurrences)
        }
        guard !stored.stale.isEmpty else { return stored.lines }
        let rebuilt = try await database.write { db in
            for sourceID in stored.stale.values {
                try Self.rebuildMeetingBriefLines(in: db, sourceID: sourceID, at: Date())
            }
            return try Self.fetchMeetingBriefLines(in: db, for: Array(stored.stale.keys))
        }
        return stored.lines.merging(rebuilt.lines) { _, new in new }
    }

    /// The occurrence's chosen source and when its lines were built. Emits
    /// when a change clears the lines, e.g. a commitment resolved elsewhere,
    /// so a screen showing them reads again; nil without a source.
    public func observeMeetingBriefSource(
        for occurrence: MeetingBriefLines.Occurrence
    ) -> AsyncThrowingStream<MeetingBriefLines.SourceState?, Error> {
        let observation = ValueObservation.tracking(
            region: Table("meetingBriefSource"),
            fetch: { db in
                try Row.fetchOne(
                    db,
                    sql: """
                        SELECT sourceMeetingID, linesBuiltAt FROM meetingBriefSource
                        WHERE eventID = ? AND eventStartAt = ?
                        """,
                    arguments: [occurrence.eventID, occurrence.startAt]
                ).map { row in
                    MeetingBriefLines.SourceState(
                        sourceMeetingID: MeetingID(rawValue: try PersistedIdentity.required(
                            row["sourceMeetingID"], table: "meetingBriefSource", column: "sourceMeetingID")),
                        linesBuiltAt: row["linesBuiltAt"])
                }
            }
        ).removeDuplicates()
        return observedStream(observation)
    }

    struct StoredMeetingBriefLines {
        var lines: [MeetingBriefLines.Occurrence: MeetingBriefLines] = [:]
        /// Sources whose lines a change cleared.
        var stale: [MeetingBriefLines.Occurrence: Int64] = [:]
    }

    static func fetchMeetingBriefLines(
        in db: Database, for occurrences: [MeetingBriefLines.Occurrence]
    ) throws -> StoredMeetingBriefLines {
        var result = StoredMeetingBriefLines()
        var built: [Int64: (occurrence: MeetingBriefLines.Occurrence, row: Row)] = [:]
        for occurrence in Set(occurrences) {
            guard let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT source.id, source.sourceMeetingID, source.preparedAt, source.linesBuiltAt
                    FROM meetingBriefSource AS source
                    JOIN meeting ON meeting.id = source.sourceMeetingID AND meeting.deletedAt IS NULL
                    WHERE source.eventID = ? AND source.eventStartAt = ?
                    """,
                arguments: [occurrence.eventID, occurrence.startAt])
            else { continue }
            if (row["linesBuiltAt"] as Date?) == nil {
                result.stale[occurrence] = row["id"]
            } else {
                built[row["id"]] = (occurrence, row)
            }
        }
        guard !built.isEmpty else { return result }
        let lineRows = try Row.fetchAll(
            db,
            sql: """
                SELECT line.sourceID, line.speakerID, line.kind, line.text, line.segmentID,
                       line.time, line.status, line.dueAt,
                       speaker.isMe, speaker.label, speaker.displayName, speaker.personID
                FROM meetingBriefLine AS line
                JOIN speaker ON speaker.id = line.speakerID
                WHERE line.sourceID IN (\(databaseQuestionMarks(count: built.count)))
                ORDER BY line.sourceID, line.ordinal
                """,
            arguments: StatementArguments(Array(built.keys)))
        var people: [Int64: [MeetingBriefLines.Person]] = [:]
        for row in lineRows {
            let source: Int64 = row["sourceID"]
            let speaker = SpeakerID(rawValue: try PersistedIdentity.required(
                row["speakerID"], table: "meetingBriefLine", column: "speakerID"))
            let line = try meetingBriefLine(from: row)
            var known = people[source] ?? []
            // Ordinals keep one person's lines together.
            let previous = known.last?.speakerID == speaker ? known.removeLast().lines : []
            let person = try PersistedIdentity.optional(
                row["personID"], table: "speaker", column: "personID")
            known.append(MeetingBriefLines.Person(
                speakerID: speaker, personID: person.map(PersonID.init(rawValue:)),
                isMe: row["isMe"], label: row["label"], displayName: row["displayName"],
                lines: previous + [line]))
            people[source] = known
        }
        for (sourceID, entry) in built {
            result.lines[entry.occurrence] = MeetingBriefLines(
                occurrence: entry.occurrence,
                sourceMeetingID: MeetingID(rawValue: try PersistedIdentity.required(
                    entry.row["sourceMeetingID"], table: "meetingBriefSource", column: "sourceMeetingID")),
                preparedAt: entry.row["preparedAt"], people: people[sourceID] ?? [])
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

    /// Replaces one source's lines and marks them built. A failed build keeps
    /// no lines until the source changes again, so later reads stay reads.
    static func rebuildMeetingBriefLines(in db: Database, sourceID: Int64, at timestamp: Date) throws {
        try db.execute(sql: "DELETE FROM meetingBriefLine WHERE sourceID = ?", arguments: [sourceID])
        do {
            try db.inSavepoint {
                try insertMeetingBriefLines(in: db, sourceID: sourceID)
                return .commit
            }
        } catch {
            // Disposable cache: an unreadable source shows no lines rather than failing the caller.
        }
        try db.execute(
            sql: "UPDATE meetingBriefSource SET linesBuiltAt = ? WHERE id = ?",
            arguments: [timestamp, sourceID])
    }

    private static func insertMeetingBriefLines(in db: Database, sourceID: Int64) throws {
        guard let meetingKey = try String.fetchOne(
            db,
            sql: """
                SELECT source.sourceMeetingID FROM meetingBriefSource AS source
                JOIN meeting ON meeting.id = source.sourceMeetingID AND meeting.deletedAt IS NULL
                WHERE source.id = ?
                """,
            arguments: [sourceID])
        else { return }
        let meetingID = MeetingID(rawValue: try PersistedIdentity.required(
            meetingKey, table: "meetingBriefSource", column: "sourceMeetingID"))
        let insert = try db.cachedStatement(sql: """
            INSERT INTO meetingBriefLine
                (sourceID, ordinal, speakerID, kind, text, segmentID, time, status, dueAt)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """)
        var ordinal = 0
        for person in try buildMeetingBriefLines(in: db, for: meetingID) {
            for line in person.lines {
                let status = line.status.column
                try insert.execute(arguments: [
                    sourceID, ordinal, person.speakerID.rawValue.uuidString, line.kind.rawValue,
                    line.text, line.segmentID?.uuidString, line.time, status.name, status.due
                ])
                ordinal += 1
            }
        }
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
