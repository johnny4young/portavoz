import Foundation
import GRDB
import PortavozCore

/// A meeting's stored voice strip: `VoiceColumns.storedCount` columns over the
/// audio length, each an index into `voices` or `VoiceColumns.silence`.
public struct MeetingVoiceColumns: Sendable, Equatable {
    public struct Voice: Sendable, Equatable {
        public let speakerID: SpeakerID
        public let isMe: Bool
        public let label: String
        public let displayName: String?
        public let talkSeconds: TimeInterval
        public let firstHeard: TimeInterval

        public init(
            speakerID: SpeakerID, isMe: Bool, label: String, displayName: String?,
            talkSeconds: TimeInterval, firstHeard: TimeInterval
        ) {
            self.speakerID = speakerID
            self.isMe = isMe
            self.label = label
            self.displayName = displayName
            self.talkSeconds = talkSeconds
            self.firstHeard = firstHeard
        }
    }

    public let duration: TimeInterval
    public let columns: [UInt8]
    /// Every attributed voice in first-heard order; names resolve at read time.
    public let voices: [Voice]

    public init(duration: TimeInterval, columns: [UInt8], voices: [Voice]) {
        self.duration = duration
        self.columns = columns
        self.voices = voices
    }
}

extension MeetingStore {
    /// The voice strips for a set of meetings, rebuilding any whose cache a
    /// transcript, correction or audio change dropped. Tombstoned meetings and
    /// meetings without attributed speech are absent. A meeting whose rebuild
    /// fails is absent too, so it cannot hide every other strip in the batch.
    public func voiceColumns(
        for meetingIDs: [MeetingID]
    ) async throws -> [MeetingID: MeetingVoiceColumns] {
        guard !meetingIDs.isEmpty else { return [:] }
        let stored = try await database.read { db in
            try Self.fetchVoiceColumns(in: db, for: meetingIDs)
        }
        guard !stored.missing.isEmpty else { return stored.columns }
        let rebuilt = try await database.write { db in
            for id in stored.missing {
                try? db.inSavepoint {
                    try Self.refreshVoiceColumns(in: db, for: [id])
                    return .commit
                }
            }
            return try Self.fetchVoiceColumns(in: db, for: stored.missing)
        }
        return stored.columns.merging(rebuilt.columns) { _, new in new }
    }

    struct StoredVoiceColumns {
        var columns: [MeetingID: MeetingVoiceColumns] = [:]
        /// Live meetings with no cached strip yet.
        var missing: [MeetingID] = []
    }

    static func fetchVoiceColumns(
        in db: Database, for meetingIDs: [MeetingID]
    ) throws -> StoredVoiceColumns {
        let ids = meetingIDs.map { $0.rawValue.uuidString }
        let placeholders = databaseQuestionMarks(count: ids.count)
        let strips = try Row.fetchAll(
            db,
            sql: """
                SELECT meeting.id AS meetingID, strip.meetingID AS cached, strip.duration, strip.columns
                FROM meeting
                LEFT JOIN meetingVoiceColumns AS strip ON strip.meetingID = meeting.id
                WHERE meeting.deletedAt IS NULL AND meeting.id IN (\(placeholders))
                """,
            arguments: StatementArguments(ids))
        let voiceRows = try Row.fetchAll(
            db,
            sql: """
                SELECT voice.meetingID, voice.speakerID, voice.talkSeconds, voice.firstHeard,
                       speaker.isMe, speaker.label, speaker.displayName
                FROM meetingVoiceColumnsVoice AS voice
                JOIN meeting ON meeting.id = voice.meetingID AND meeting.deletedAt IS NULL
                JOIN speaker ON speaker.id = voice.speakerID
                WHERE voice.meetingID IN (\(placeholders))
                ORDER BY voice.meetingID, voice.voiceIndex
                """,
            arguments: StatementArguments(ids))
        var voices: [String: [MeetingVoiceColumns.Voice]] = [:]
        for row in voiceRows {
            let speaker = try PersistedIdentity.required(
                row["speakerID"], table: "meetingVoiceColumnsVoice", column: "speakerID")
            voices[row["meetingID"], default: []].append(MeetingVoiceColumns.Voice(
                speakerID: SpeakerID(rawValue: speaker), isMe: row["isMe"], label: row["label"],
                displayName: row["displayName"], talkSeconds: row["talkSeconds"],
                firstHeard: row["firstHeard"]))
        }
        var result = StoredVoiceColumns()
        for row in strips {
            let key: String = row["meetingID"]
            let id = MeetingID(rawValue: try PersistedIdentity.required(
                key, table: "meeting", column: "id"))
            guard (row["cached"] as String?) != nil else {
                result.missing.append(id)
                continue
            }
            guard let meetingVoices = voices[key] else { continue }
            result.columns[id] = MeetingVoiceColumns(
                duration: row["duration"], columns: [UInt8](row["columns"] as Data), voices: meetingVoices)
        }
        return result
    }

    /// Rebuilds the cached strips from accepted segments of live speakers with
    /// the effective corrections applied. A malformed correction history fails
    /// the rebuild, as it fails every other correction-aware projection.
    static func refreshVoiceColumns(in db: Database, for meetingIDs: [MeetingID]) throws {
        guard !meetingIDs.isEmpty else { return }
        let built = try buildVoiceStrips(in: db, for: meetingIDs)
        let ids = meetingIDs.map { $0.rawValue.uuidString }
        // Migrations run with foreign keys off, so the child rows cannot rely on the cascade.
        for table in ["meetingVoiceColumnsVoice", "meetingVoiceColumns"] {
            try db.execute(
                sql: "DELETE FROM \(table) WHERE meetingID IN (\(databaseQuestionMarks(count: ids.count)))",
                arguments: StatementArguments(ids))
        }
        let insertStrip = try db.cachedStatement(sql: """
            INSERT INTO meetingVoiceColumns (meetingID, duration, columns, updatedAt)
            VALUES (?, ?, ?, ?)
            """)
        let insertVoice = try db.cachedStatement(sql: """
            INSERT INTO meetingVoiceColumnsVoice
                (meetingID, voiceIndex, speakerID, talkSeconds, firstHeard)
            VALUES (?, ?, ?, ?, ?)
            """)
        let timestamp = Date()
        for (id, strip) in built {
            let key = id.rawValue.uuidString
            try insertStrip.execute(arguments: [key, strip.duration, Data(strip.columns), timestamp])
            for (index, voice) in strip.voices.enumerated() {
                try insertVoice.execute(arguments: [
                    key, index, voice.speakerID.rawValue.uuidString, voice.talkSeconds, voice.firstHeard
                ])
            }
        }
    }

    /// The strip a rebuild would store, without writing, so a read-only
    /// observation can draw a meeting whose cache was dropped. A meeting whose
    /// correction history is malformed is absent, as in `voiceColumns(for:)`.
    static func computeVoiceColumns(
        in db: Database, for meetingIDs: [MeetingID]
    ) -> [MeetingID: MeetingVoiceColumns] {
        guard !meetingIDs.isEmpty else { return [:] }
        let built = (try? buildVoiceStrips(in: db, for: meetingIDs))
            ?? meetingIDs.flatMap { (try? buildVoiceStrips(in: db, for: [$0])) ?? [] }
        return Dictionary(
            built.filter { !$0.strip.voices.isEmpty }.map { ($0.id, $0.strip) },
            uniquingKeysWith: { first, _ in first })
    }

    private struct LiveSpeaker {
        let isMe: Bool
        let label: String
        let displayName: String?
    }

    private static func buildVoiceStrips(
        in db: Database, for meetingIDs: [MeetingID]
    ) throws -> [(id: MeetingID, strip: MeetingVoiceColumns)] {
        let ids = meetingIDs.map { $0.rawValue.uuidString }
        let placeholders = databaseQuestionMarks(count: ids.count)
        let meetings = try Row.fetchAll(
            db,
            sql: """
                SELECT meeting.id AS meetingID, meeting.transcriptRevision AS revision,
                       EXISTS (
                           SELECT 1 FROM transcriptCorrection AS correction
                           WHERE correction.meetingID = meeting.id) AS corrected,
                       (SELECT MAX(durationSeconds) FROM audioAsset
                        WHERE audioAsset.meetingID = meeting.id
                          AND audioAsset.deletedAt IS NULL
                          AND audioAsset.supersededAt IS NULL) AS audio
                FROM meeting
                WHERE meeting.deletedAt IS NULL AND meeting.id IN (\(placeholders))
                """,
            arguments: StatementArguments(ids))
        let lines = try fetchVoiceColumnLines(in: db, placeholders: placeholders, ids: ids)
        let liveSpeakers = try fetchLiveSpeakers(in: db, placeholders: placeholders, ids: ids)
        return try meetings.map { row in
            let key: String = row["meetingID"]
            let id = MeetingID(rawValue: try PersistedIdentity.required(key, table: "meeting", column: "id"))
            let corrections = row["corrected"] as Bool
                ? try TranscriptCorrectionPolicy.effectiveCorrections(
                    in: fetchTranscriptCorrectionHistory(meetingID: id, in: db),
                    meetingID: id, baseTranscriptRevision: row["revision"])
                : []
            let speakers = liveSpeakers[key] ?? [:]
            let turns = VoiceColumns.attributedTurns(
                lines: lines[key] ?? [], corrections: corrections
            ).filter { speakers[$0.key.rawValue.uuidString] != nil }
            let audio: Double? = row["audio"]
            let strip = VoiceColumns.strip(turns, duration: audio ?? 0, count: VoiceColumns.storedCount)
            // Turns are filtered to live speakers, so every voice resolves and indexes stay aligned.
            let voices = strip.voices.compactMap { voice in
                speakers[voice.key.rawValue.uuidString].map {
                    MeetingVoiceColumns.Voice(
                        speakerID: voice.key, isMe: $0.isMe, label: $0.label,
                        displayName: $0.displayName, talkSeconds: voice.talkSeconds,
                        firstHeard: voice.firstHeard)
                }
            }
            return (id, MeetingVoiceColumns(duration: strip.duration, columns: strip.columns, voices: voices))
        }
    }

    private static func fetchVoiceColumnLines(
        in db: Database, placeholders: String, ids: [String]
    ) throws -> [String: [VoiceColumns.Line]] {
        var lines: [String: [VoiceColumns.Line]] = [:]
        for row in try Row.fetchAll(
            db,
            sql: """
                SELECT id, meetingID, speakerID, startTime, endTime FROM segment
                WHERE deletedAt IS NULL AND isFinal = 1 AND meetingID IN (\(placeholders))
                """,
            arguments: StatementArguments(ids)) {
            let speaker = try PersistedIdentity.optional(
                row["speakerID"], table: "segment", column: "speakerID")
            lines[row["meetingID"], default: []].append(VoiceColumns.Line(
                id: try PersistedIdentity.required(row["id"], table: "segment", column: "id"),
                speaker: speaker.map(SpeakerID.init(rawValue:)),
                start: row["startTime"], end: row["endTime"]))
        }
        return lines
    }

    private static func fetchLiveSpeakers(
        in db: Database, placeholders: String, ids: [String]
    ) throws -> [String: [String: LiveSpeaker]] {
        var speakers: [String: [String: LiveSpeaker]] = [:]
        for row in try Row.fetchAll(
            db,
            sql: """
                SELECT id, meetingID, isMe, label, displayName FROM speaker
                WHERE deletedAt IS NULL AND meetingID IN (\(placeholders))
                """,
            arguments: StatementArguments(ids)) {
            speakers[row["meetingID"], default: [:]][row["id"]] = LiveSpeaker(
                isMe: row["isMe"], label: row["label"], displayName: row["displayName"])
        }
        return speakers
    }
}
