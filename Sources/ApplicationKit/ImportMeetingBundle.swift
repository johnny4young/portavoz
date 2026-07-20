import Foundation
import PortavozCore
import StorageKit

public enum ImportMeetingBundleError: Error, Equatable, LocalizedError, Sendable {
    case unsupportedAudioChannel(String)
    case unsupportedAudioExtension(String)
    case duplicateAudioChannel(AudioChannel)
    case audioDirectoryAlreadyExists(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedAudioChannel(let name):
            "Unsupported meeting audio channel: \(name)."
        case .unsupportedAudioExtension(let fileExtension):
            "Unsupported meeting audio extension: \(fileExtension)."
        case .duplicateAudioChannel(let channel):
            "The meeting bundle contains more than one \(channel.rawValue) audio file."
        case .audioDirectoryAlreadyExists(let directory):
            "The imported meeting audio directory already exists: \(directory)."
        }
    }
}

/// Validated attachment crossing the external-format/application boundary.
/// Only canonical channel names and playback-supported extensions survive.
public struct ImportedMeetingBundleAttachment: Equatable, Sendable {
    public let channel: AudioChannel
    public let fileExtension: String
    public let data: Data

    public init(
        name: String,
        fileExtension: String,
        data: Data
    ) throws {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard let channel = AudioChannel(rawValue: normalizedName),
            channel == .microphone || channel == .system
        else {
            throw ImportMeetingBundleError.unsupportedAudioChannel(name)
        }
        let normalizedExtension = fileExtension
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard ["m4a", "caf", "wav"].contains(normalizedExtension) else {
            throw ImportMeetingBundleError.unsupportedAudioExtension(fileExtension)
        }
        self.channel = channel
        self.fileExtension = normalizedExtension
        self.data = data
    }
}

/// Format-neutral, already identity-remapped representation of one external
/// meeting document. IntegrationsKit stays behind the private app adapter.
public struct ImportedMeetingBundleDocument: Sendable {
    public let meeting: Meeting
    public let speakers: [Speaker]
    public let segments: [TranscriptSegment]
    public let summary: SummaryDraft?
    public let contextItems: [ContextItem]
    public let companionCards: [CompanionCard]
    public let attachments: [ImportedMeetingBundleAttachment]

    public init(
        meeting: Meeting,
        speakers: [Speaker],
        segments: [TranscriptSegment],
        summary: SummaryDraft?,
        contextItems: [ContextItem],
        companionCards: [CompanionCard],
        attachments: [ImportedMeetingBundleAttachment]
    ) throws {
        var channels = Set<AudioChannel>()
        for attachment in attachments where !channels.insert(attachment.channel).inserted {
            throw ImportMeetingBundleError.duplicateAudioChannel(attachment.channel)
        }
        self.meeting = meeting
        self.speakers = speakers
        self.segments = segments
        self.summary = summary
        self.contextItems = contextItems
        self.companionCards = companionCards
        self.attachments = attachments
    }
}

/// External document adapter. Reading, JSON decoding, and identity remapping
/// may be expensive for audio-bearing bundles and must run off the MainActor.
public protocol ImportMeetingBundleDocuments: Sendable {
    func readRemappedBundle(from source: URL) async throws
        -> ImportedMeetingBundleDocument
}

/// Directory owned by this import until the aggregate transaction succeeds.
public struct ImportedMeetingBundleAudio: Equatable, Sendable {
    public let relativeDirectory: String

    public init(relativeDirectory: String) {
        self.relativeDirectory = relativeDirectory
    }
}

/// Local filesystem Saga for optional audio attachments.
public protocol ImportMeetingBundleFiles: Sendable {
    func stageBundleAudio(
        _ attachments: [ImportedMeetingBundleAttachment],
        meetingID: MeetingID
    ) async throws -> ImportedMeetingBundleAudio
    func discardBundleAudio(_ audio: ImportedMeetingBundleAudio) async throws
}

/// One complete database Unit of Work for every row carried by the bundle.
public protocol ImportMeetingBundleStore: Sendable {
    func installImportedMeetingBundle(
        _ snapshot: ImportedMeetingBundleSnapshot,
        at timestamp: Date
    ) async throws
}

extension MeetingStore: ImportMeetingBundleStore {
    public func installImportedMeetingBundle(
        _ snapshot: ImportedMeetingBundleSnapshot,
        at timestamp: Date
    ) async throws {
        try await saveImportedMeetingBundle(snapshot, at: timestamp)
    }
}

public struct ImportMeetingBundleRequest: Sendable {
    public let sourceURL: URL

    public init(sourceURL: URL) {
        self.sourceURL = sourceURL
    }
}

/// Imports one `.portavoz` document as a fresh, all-or-nothing meeting while
/// preserving the released Library invalidation and navigation boundary.
public struct ImportMeetingBundle: ApplicationUseCase {
    private let documents: any ImportMeetingBundleDocuments
    private let files: any ImportMeetingBundleFiles
    private let store: any ImportMeetingBundleStore
    private let now: @Sendable () -> Date

    public init(
        documents: any ImportMeetingBundleDocuments,
        files: any ImportMeetingBundleFiles,
        store: any ImportMeetingBundleStore,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.documents = documents
        self.files = files
        self.store = store
        self.now = now
    }

    public func execute(_ request: ImportMeetingBundleRequest) async throws -> MeetingID {
        let document = try await documents.readRemappedBundle(from: request.sourceURL)
        var meeting = document.meeting
        // Machine-local paths never cross the interchange boundary, even if
        // a hand-authored document supplied one.
        meeting.audioDirectory = nil
        var stagedAudio: ImportedMeetingBundleAudio?
        do {
            if !document.attachments.isEmpty {
                let audio = try await files.stageBundleAudio(
                    document.attachments,
                    meetingID: meeting.id)
                stagedAudio = audio
                meeting.audioDirectory = audio.relativeDirectory
            }
            try await store.installImportedMeetingBundle(
                ImportedMeetingBundleSnapshot(
                    meeting: meeting,
                    speakers: document.speakers,
                    segments: document.segments,
                    summary: document.summary,
                    contextItems: document.contextItems,
                    companionCards: document.companionCards),
                at: now())
            return meeting.id
        } catch {
            if let stagedAudio {
                try? await files.discardBundleAudio(stagedAudio)
            }
            throw error
        }
    }
}
