import Foundation
import GRDB
import PortavozCore

extension MeetingStore {
    /// One speaker's slice of a meeting's attributed speech — the pieces of
    /// the sidebar's voice-mix bar (design system: "the library becomes a
    /// shelf of conversations you can read at a glance"). `order` is the
    /// speaker's rank by talk time, used to color unnamed speakers by
    /// appearance; named speakers color by their name instead.
    public struct VoiceMixSlice: Sendable, Equatable {
        public let isMe: Bool
        public let displayName: String?
        public let fraction: Double
        public let order: Int
    }

    /// The voice mix for a set of meetings, in ONE aggregate query — sums
    /// segment durations per (meeting, speaker) and returns each meeting's
    /// slices, largest first, normalized to the meeting's attributed
    /// speech. Meetings with no attributed speech are simply absent.
    public func voiceMixes(
        for meetingIDs: [MeetingID]
    ) async throws -> [MeetingID: [VoiceMixSlice]] {
        guard !meetingIDs.isEmpty else { return [:] }
        return try await database.read { db in
            try Self.fetchVoiceMixes(in: db, for: meetingIDs)
        }
    }

    static func fetchVoiceMixes(
        in database: Database,
        for meetingIDs: [MeetingID]
    ) throws -> [MeetingID: [VoiceMixSlice]] {
        guard !meetingIDs.isEmpty else { return [:] }
        let ids = meetingIDs.map { $0.rawValue.uuidString }
        let placeholders = databaseQuestionMarks(count: ids.count)
        let rows = try Row.fetchAll(
            database,
            sql: """
                SELECT segment.meetingID AS meetingID,
                       speaker.isMe AS isMe,
                       speaker.displayName AS displayName,
                       SUM(segment.endTime - segment.startTime) AS seconds
                FROM segment
                JOIN meeting ON meeting.id = segment.meetingID
                    AND meeting.deletedAt IS NULL
                JOIN speaker ON speaker.id = segment.speakerID
                    AND speaker.deletedAt IS NULL
                WHERE segment.deletedAt IS NULL
                  AND segment.speakerID IS NOT NULL
                  AND segment.endTime > segment.startTime
                  AND segment.meetingID IN (\(placeholders))
                GROUP BY segment.meetingID, segment.speakerID
                ORDER BY segment.meetingID, seconds DESC
                """,
            arguments: StatementArguments(ids))

        var byMeeting: [MeetingID: [(isMe: Bool, name: String?, seconds: Double)]] = [:]
        for row in rows {
            let uuid = try PersistedIdentity.required(
                row["meetingID"], table: "segment", column: "meetingID")
            let id = MeetingID(rawValue: uuid)
            byMeeting[id, default: []].append(
                (isMe: row["isMe"], name: row["displayName"], seconds: row["seconds"]))
        }

        var result: [MeetingID: [VoiceMixSlice]] = [:]
        for (id, speakers) in byMeeting {
            let total = speakers.reduce(0) { $0 + $1.seconds }
            guard total > 0 else { continue }
            result[id] = speakers.enumerated().map { order, speaker in
                VoiceMixSlice(
                    isMe: speaker.isMe,
                    displayName: speaker.name,
                    fraction: speaker.seconds / total,
                    order: order)
            }
        }
        return result
    }

    /// How much you talk vs each named person across the meetings you share
    /// (design system 3a, the "who you talk with" panel): amber = you, violet
    /// = them. Also carries your overall share of all attributed speech in the
    /// library, for the talk-balance tile. All from local segment durations.
    public struct ParticipantVoice: Sendable, Equatable, Identifiable {
        public let name: String
        public let meetings: Int
        /// This person's total attributed speech, seconds.
        public let theirSeconds: TimeInterval
        /// Your share of talk vs THIS person across your shared meetings,
        /// 0…1 (amber). 0.5 = even; > 0.5 = you dominate.
        public let myShareWithThem: Double
        public var id: String { name }
    }

    public struct VoiceBalance: Sendable, Equatable {
        public let participants: [ParticipantVoice]
        /// Your share of ALL attributed speech across the library, 0…1.
        public let myOverallShare: Double
        /// Whether there was any attributed, named speech to measure.
        public let hasData: Bool
    }

    /// One aggregate query over every attributed segment → per-person talk
    /// split and the overall balance. Names are grouped case-insensitively.
    /// The query plus the fold-into-per-person pass is one cohesive unit.
    public func voiceBalance(
        topLimit: Int = 6
    ) async throws -> VoiceBalance {
        try await database.read { db in
            try Self.fetchVoiceBalance(in: db, topLimit: topLimit)
        }
    }

    static func fetchVoiceBalance( // swiftlint:disable:this function_body_length
        in database: Database,
        topLimit: Int
    ) throws -> VoiceBalance {
        let rows = try Row.fetchAll(
            database,
            sql: """
                SELECT segment.meetingID AS meetingID,
                       speaker.isMe AS isMe,
                       speaker.displayName AS displayName,
                       SUM(segment.endTime - segment.startTime) AS seconds
                FROM segment
                JOIN meeting ON meeting.id = segment.meetingID
                    AND meeting.deletedAt IS NULL
                JOIN speaker ON speaker.id = segment.speakerID
                    AND speaker.deletedAt IS NULL
                WHERE segment.deletedAt IS NULL
                  AND segment.speakerID IS NOT NULL
                  AND segment.endTime > segment.startTime
                GROUP BY segment.meetingID, segment.speakerID
                """)

        // Per meeting: your seconds, and each named person's seconds.
        var mineByMeeting: [String: Double] = [:]
        var namedByMeeting: [String: [(key: String, name: String, seconds: Double)]] = [:]
        var overallMine = 0.0
        var overallTotal = 0.0
        for row in rows {
            let meetingID: String = row["meetingID"]
            let isMe: Bool = row["isMe"]
            let seconds: Double = row["seconds"]
            overallTotal += seconds
            if isMe {
                overallMine += seconds
                mineByMeeting[meetingID, default: 0] += seconds
            } else if let raw = row["displayName"] as String?,
                !raw.trimmingCharacters(in: .whitespaces).isEmpty {
                let key = raw.trimmingCharacters(in: .whitespaces).lowercased()
                namedByMeeting[meetingID, default: []].append(
                    (key: key, name: raw, seconds: seconds))
            }
        }

        // Fold into per-person totals, carrying your time in each of their
        // meetings so the amber/violet split is truthful.
        struct Acc {
            var name: String
            var meetings = 0
            var theirs = 0.0
            var mineWith = 0.0
        }
        var byPerson: [String: Acc] = [:]
        for (meetingID, people) in namedByMeeting {
            let mine = mineByMeeting[meetingID] ?? 0
            for person in people {
                var acc = byPerson[person.key] ?? Acc(name: person.name)
                acc.meetings += 1
                acc.theirs += person.seconds
                acc.mineWith += mine
                byPerson[person.key] = acc
            }
        }

        let participants = byPerson.values
            .sorted { $0.theirs > $1.theirs }
            .prefix(topLimit)
            .map { acc -> ParticipantVoice in
                let denominator = acc.mineWith + acc.theirs
                return ParticipantVoice(
                    name: acc.name,
                    meetings: acc.meetings,
                    theirSeconds: acc.theirs,
                    myShareWithThem: denominator > 0 ? acc.mineWith / denominator : 0)
            }

        return VoiceBalance(
            participants: Array(participants),
            myOverallShare: overallTotal > 0 ? overallMine / overallTotal : 0,
            hasData: overallTotal > 0)
    }
}
