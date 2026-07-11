import Foundation
import PortavozCore

/// The `.portavoz` interchange file (M15 L0): one meeting — transcript,
/// cast, latest summary, co-authoring notes — as a single versioned JSON
/// document another Mac can import. Deliberately WITHOUT audio in v1: the
/// shareable value is who-said-what and what was decided, and a text-only
/// file stays mail-sized. The format is additive: readers accept any file
/// whose `formatVersion` they know, and unknown FUTURE fields are ignored
/// by Codable, so v1 readers keep opening v1 files forever.
public struct MeetingBundle: Codable, Sendable {
    public static let currentFormatVersion = 1
    public static let fileExtension = "portavoz"
    /// Exported UTI (declared in the app's Info.plist).
    public static let typeIdentifier = "app.portavoz.meeting-bundle"

    public var formatVersion: Int
    public var exportedAt: Date
    public var meeting: Meeting
    public var speakers: [Speaker]
    public var segments: [TranscriptSegment]
    public var summary: SummaryDraft?
    public var contextItems: [ContextItem]

    public init(
        meeting: Meeting,
        speakers: [Speaker],
        segments: [TranscriptSegment],
        summary: SummaryDraft? = nil,
        contextItems: [ContextItem] = [],
        exportedAt: Date = Date()
    ) {
        self.formatVersion = Self.currentFormatVersion
        self.exportedAt = exportedAt
        var shared = meeting
        // Paths are machine-local (D4) and audio does not travel in v1.
        shared.audioDirectory = nil
        self.meeting = shared
        self.speakers = speakers
        self.segments = segments
        self.summary = summary
        self.contextItems = contextItems
    }

    public enum BundleError: Error, LocalizedError, Equatable {
        case unsupportedVersion(Int)

        public var errorDescription: String? {
            switch self {
            case .unsupportedVersion(let version):
                return "this .portavoz file uses format v\(version) — update Portavoz to open it"
            }
        }
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> MeetingBundle {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let bundle = try decoder.decode(MeetingBundle.self, from: data)
        guard bundle.formatVersion <= currentFormatVersion else {
            throw BundleError.unsupportedVersion(bundle.formatVersion)
        }
        return bundle
    }

    /// A copy with FRESH identifiers throughout (meeting, speakers,
    /// segments, action items, notes) with every relation preserved —
    /// importing can never collide with existing rows, and importing the
    /// same file twice yields two independent meetings.
    public func remappedForImport() -> MeetingBundle {
        var copy = self
        let newMeetingID = MeetingID()
        var speakerMap: [SpeakerID: SpeakerID] = [:]

        copy.meeting.id = newMeetingID
        copy.speakers = speakers.map { speaker in
            let newID = SpeakerID()
            speakerMap[speaker.id] = newID
            return Speaker(
                id: newID,
                meetingID: newMeetingID,
                label: speaker.label,
                displayName: speaker.displayName,
                isMe: speaker.isMe)
        }
        copy.segments = segments.map { segment in
            TranscriptSegment(
                id: UUID(),
                meetingID: newMeetingID,
                speakerID: segment.speakerID.flatMap { speakerMap[$0] },
                channel: segment.channel,
                text: segment.text,
                language: segment.language,
                startTime: segment.startTime,
                endTime: segment.endTime,
                confidence: segment.confidence,
                isFinal: segment.isFinal)
        }
        if let summary {
            copy.summary = SummaryDraft(
                meetingID: newMeetingID,
                recipeID: summary.recipeID,
                language: summary.language,
                markdown: summary.markdown,
                actionItems: summary.actionItems.map { item in
                    ActionItem(
                        id: UUID(),
                        text: item.text,
                        ownerSpeakerID: item.ownerSpeakerID.flatMap { speakerMap[$0] },
                        isDone: item.isDone)
                },
                fingerprint: summary.fingerprint)
        }
        copy.contextItems = contextItems.map { item in
            ContextItem(
                id: UUID(),
                meetingID: newMeetingID,
                kind: item.kind,
                content: item.content,
                timestamp: item.timestamp)
        }
        return copy
    }
}
