import Foundation
import PortavozCore
import StorageKit

public enum ExportMeetingBundleError: Error, Equatable, LocalizedError, Sendable {
    case meetingNotFound(MeetingID)
    case duplicateAudioChannel(AudioChannel)

    public var errorDescription: String? {
        switch self {
        case .meetingNotFound(let id):
            "No live meeting is available to export: \(id.rawValue.uuidString)."
        case .duplicateAudioChannel(let channel):
            "The meeting export contains more than one \(channel.rawValue) audio file."
        }
    }
}

/// One read-consistent aggregate, independent of any external file format.
public struct ExportMeetingBundleContent: Sendable {
    public let meeting: Meeting
    public let speakers: [Speaker]
    public let segments: [TranscriptSegment]
    public let summary: SummaryDraft?
    public let contextItems: [ContextItem]
    public let companionCards: [CompanionCard]

    public init(
        meeting: Meeting,
        speakers: [Speaker],
        segments: [TranscriptSegment],
        summary: SummaryDraft?,
        contextItems: [ContextItem],
        companionCards: [CompanionCard]
    ) {
        self.meeting = meeting
        self.speakers = speakers
        self.segments = segments
        self.summary = summary
        self.contextItems = contextItems
        self.companionCards = companionCards
    }
}

/// Canonical audio bytes admitted to the export document boundary.
public struct ExportMeetingBundleAttachment: Equatable, Sendable {
    public let channel: AudioChannel
    public let fileExtension: String
    public let data: Data

    public init?(
        channel: AudioChannel,
        fileExtension: String,
        data: Data
    ) {
        guard channel == .system || channel == .microphone else { return nil }
        let normalizedExtension = fileExtension.lowercased()
        guard ["m4a", "caf", "wav"].contains(normalizedExtension) else {
            return nil
        }
        self.channel = channel
        self.fileExtension = normalizedExtension
        self.data = data
    }
}

/// Format-neutral document assembled by the application workflow. The
/// private app adapter is the only layer that converts this to MeetingBundle.
public struct ExportMeetingBundleDocument: Sendable {
    public let meeting: Meeting
    public let speakers: [Speaker]
    public let segments: [TranscriptSegment]
    public let summary: SummaryDraft?
    public let contextItems: [ContextItem]
    public let companionCards: [CompanionCard]
    public let attachments: [ExportMeetingBundleAttachment]

    public init(
        content: ExportMeetingBundleContent,
        attachments: [ExportMeetingBundleAttachment]
    ) throws {
        var channels = Set<AudioChannel>()
        for attachment in attachments where !channels.insert(attachment.channel).inserted {
            throw ExportMeetingBundleError.duplicateAudioChannel(attachment.channel)
        }
        self.meeting = content.meeting
        self.speakers = content.speakers
        self.segments = content.segments
        self.summary = content.summary
        self.contextItems = content.contextItems
        self.companionCards = content.companionCards
        self.attachments = attachments
    }
}

/// Atomic read-side projection of one live meeting.
public protocol ExportMeetingBundleStore: Sendable {
    func meetingBundleExportContent(
        for meetingID: MeetingID
    ) async throws -> ExportMeetingBundleContent?
}

extension MeetingStore: ExportMeetingBundleStore {
    public func meetingBundleExportContent(
        for meetingID: MeetingID
    ) async throws -> ExportMeetingBundleContent? {
        guard let snapshot = try await meetingExportSnapshot(meetingID) else { return nil }
        return ExportMeetingBundleContent(
            meeting: snapshot.meeting,
            speakers: snapshot.speakers,
            segments: snapshot.segments,
            summary: snapshot.summary,
            contextItems: snapshot.contextItems,
            companionCards: snapshot.companionCards)
    }
}

/// Best-effort canonical channel reader. Missing or unreadable channels are
/// omitted exactly as in the released exporter.
public protocol ExportMeetingBundleFiles: Sendable {
    func readBundleAudio(
        from relativeDirectory: String
    ) async -> [ExportMeetingBundleAttachment]
}

/// External-format encoder. IntegrationsKit remains behind its app adapter.
public protocol ExportMeetingBundleDocuments: Sendable {
    func encodeMeetingBundle(
        _ document: ExportMeetingBundleDocument
    ) async throws -> Data
}

public struct ExportMeetingBundleRequest: Sendable {
    public let meetingID: MeetingID
    public let includeAudio: Bool

    public init(meetingID: MeetingID, includeAudio: Bool) {
        self.meetingID = meetingID
        self.includeAudio = includeAudio
    }
}

/// Builds one `.portavoz` payload without exposing its format or meeting-size
/// file work to SwiftUI.
public struct ExportMeetingBundle: ApplicationUseCase {
    private let store: any ExportMeetingBundleStore
    private let files: any ExportMeetingBundleFiles
    private let documents: any ExportMeetingBundleDocuments

    public init(
        store: any ExportMeetingBundleStore,
        files: any ExportMeetingBundleFiles,
        documents: any ExportMeetingBundleDocuments
    ) {
        self.store = store
        self.files = files
        self.documents = documents
    }

    public func execute(_ request: ExportMeetingBundleRequest) async throws -> Data {
        guard var content = try await store.meetingBundleExportContent(
            for: request.meetingID)
        else {
            throw ExportMeetingBundleError.meetingNotFound(request.meetingID)
        }

        let relativeDirectory = content.meeting.audioDirectory
        var sharedMeeting = content.meeting
        sharedMeeting.audioDirectory = nil
        content = ExportMeetingBundleContent(
            meeting: sharedMeeting,
            speakers: content.speakers,
            segments: content.segments,
            summary: content.summary,
            contextItems: content.contextItems,
            companionCards: content.companionCards)

        let attachments: [ExportMeetingBundleAttachment]
        if request.includeAudio, let relativeDirectory {
            attachments = await files.readBundleAudio(from: relativeDirectory)
        } else {
            attachments = []
        }
        return try await documents.encodeMeetingBundle(
            try ExportMeetingBundleDocument(
                content: content,
                attachments: attachments))
    }
}
