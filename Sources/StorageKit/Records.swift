import Foundation
import GRDB
import PortavozCore

// Internal row shapes. IDs are stored as UUID strings; the retention
// policy as JSON (an enum with associated values). Domain types stay
// database-agnostic — mapping lives here and nowhere else.

struct MeetingRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "meeting"

    var id: String
    var title: String
    var startedAt: Date
    var endedAt: Date?
    var language: String?
    var audioDirectory: String?
    var retention: String
    var visibility: String
    var createdAt: Date
    var updatedAt: Date
    var deletedAt: Date?

    init(_ meeting: Meeting, createdAt: Date, updatedAt: Date, deletedAt: Date? = nil) throws {
        self.id = meeting.id.rawValue.uuidString
        self.title = meeting.title
        self.startedAt = meeting.startedAt
        self.endedAt = meeting.endedAt
        self.language = meeting.language
        self.audioDirectory = meeting.audioDirectory
        self.retention = try Self.encode(meeting.retention)
        self.visibility = meeting.visibility
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }

    var meeting: Meeting {
        get throws {
            Meeting(
                id: MeetingID(rawValue: UUID(uuidString: id) ?? UUID()),
                title: title,
                startedAt: startedAt,
                endedAt: endedAt,
                language: language,
                audioDirectory: audioDirectory,
                retention: try Self.decode(retention),
                visibility: visibility
            )
        }
    }

    static func encode(_ policy: AudioRetentionPolicy) throws -> String {
        // JSONEncoder siempre emite UTF-8 válido: la conversión total (nunca
        // nil) es intencional; la variante failable cambiaría el contrato.
        // swiftlint:disable:next optional_data_string_conversion
        String(decoding: try JSONEncoder().encode(policy), as: UTF8.self)
    }

    static func decode(_ text: String) throws -> AudioRetentionPolicy {
        try JSONDecoder().decode(AudioRetentionPolicy.self, from: Data(text.utf8))
    }
}

struct SpeakerRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "speaker"

    var id: String
    var meetingID: String
    var label: String
    var displayName: String?
    var isMe: Bool
    var createdAt: Date
    var updatedAt: Date
    var deletedAt: Date?

    init(_ speaker: Speaker, createdAt: Date, updatedAt: Date) {
        self.id = speaker.id.rawValue.uuidString
        self.meetingID = speaker.meetingID.rawValue.uuidString
        self.label = speaker.label
        self.displayName = speaker.displayName
        self.isMe = speaker.isMe
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = nil
    }

    var speaker: Speaker {
        Speaker(
            id: SpeakerID(rawValue: UUID(uuidString: id) ?? UUID()),
            meetingID: MeetingID(rawValue: UUID(uuidString: meetingID) ?? UUID()),
            label: label,
            displayName: displayName,
            isMe: isMe
        )
    }
}

struct SegmentRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "segment"

    var id: String
    var meetingID: String
    var speakerID: String?
    var channel: String
    var text: String
    var language: String?
    var startTime: Double
    var endTime: Double
    var confidence: Double?
    var isFinal: Bool
    var createdAt: Date
    var updatedAt: Date
    var deletedAt: Date?
    /// Float32 LE, L2-normalized sentence embedding (v2, local RAG).
    var embedding: Data?

    init(_ segment: TranscriptSegment, createdAt: Date, updatedAt: Date) {
        self.id = segment.id.uuidString
        self.meetingID = segment.meetingID.rawValue.uuidString
        self.speakerID = segment.speakerID?.rawValue.uuidString
        self.channel = segment.channel.rawValue
        self.text = segment.text
        self.language = segment.language
        self.startTime = segment.startTime
        self.endTime = segment.endTime
        self.confidence = segment.confidence
        self.isFinal = segment.isFinal
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = nil
        self.embedding = nil
    }

    var segment: TranscriptSegment {
        TranscriptSegment(
            id: UUID(uuidString: id) ?? UUID(),
            meetingID: MeetingID(rawValue: UUID(uuidString: meetingID) ?? UUID()),
            speakerID: speakerID.flatMap { UUID(uuidString: $0) }.map { SpeakerID(rawValue: $0) },
            channel: AudioChannel(rawValue: channel) ?? .system,
            text: text,
            language: language,
            startTime: startTime,
            endTime: endTime,
            confidence: confidence,
            isFinal: isFinal
        )
    }
}

struct SummaryRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "summary"

    var id: String
    var meetingID: String
    var recipeID: String
    var language: String
    var markdown: String
    var version: Int
    var fingerprint: String?
    var createdAt: Date
    var deletedAt: Date?
}

struct ActionItemRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "actionItem"

    var id: String
    var summaryID: String
    var meetingID: String
    var text: String
    var ownerSpeakerID: String?
    var isDone: Bool
    var createdAt: Date
    var updatedAt: Date
    var deletedAt: Date?

    var actionItem: ActionItem {
        ActionItem(
            id: UUID(uuidString: id) ?? UUID(),
            text: text,
            ownerSpeakerID: ownerSpeakerID.flatMap { UUID(uuidString: $0) }.map {
                SpeakerID(rawValue: $0)
            },
            isDone: isDone
        )
    }
}

struct ContextItemRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "contextItem"

    var id: String
    var meetingID: String
    var kind: String
    var content: String
    var timestamp: Double
    var createdAt: Date
    var updatedAt: Date
    var deletedAt: Date?

    init(_ item: ContextItem, createdAt: Date, updatedAt: Date) {
        self.id = item.id.uuidString
        self.meetingID = item.meetingID.rawValue.uuidString
        self.kind = item.kind.rawValue
        self.content = item.content
        self.timestamp = item.timestamp
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = nil
    }

    var item: ContextItem? {
        guard
            let uuid = UUID(uuidString: id),
            let meetingUUID = UUID(uuidString: meetingID),
            let kind = ContextItem.Kind(rawValue: kind)
        else { return nil }
        return ContextItem(
            id: uuid, meetingID: MeetingID(rawValue: meetingUUID),
            kind: kind, content: content, timestamp: timestamp)
    }
}
