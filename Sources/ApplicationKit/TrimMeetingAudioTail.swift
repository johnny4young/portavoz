import AudioPlaybackKit
import Foundation
import PortavozCore
import StorageKit

/// Where a recording that kept running after the conversation can be cut.
public enum TrailingSilence {
    /// Only a long quiet tail is worth an irreversible cut.
    public static let minimumLength: TimeInterval = 300
    /// Audio kept after the last transcribed phrase.
    static let keptAfterSpeech: TimeInterval = 10

    /// The cut point, or nil when the tail is shorter than five minutes.
    public static func cutoff(segments: [TranscriptSegment], duration: TimeInterval) -> TimeInterval? {
        guard let lastSpeech = segments.map(\.endTime).filter({ $0 <= duration }).max(),
            duration - lastSpeech >= minimumLength
        else { return nil }
        return lastSpeech + keptAfterSpeech
    }
}

public protocol MeetingAudioTrimming: Sendable {
    func stageTrim(_ files: [URL], cutoff: TimeInterval) async throws -> [URL]
    func commitTrim(originals: [URL], staged: [URL]) throws
    func discardTrim(_ staged: [URL])
}

public protocol MeetingAudioTrimStore: Sendable {
    func canTrimMeetingAudio(meetingID: MeetingID, relativeAudioDirectory: String) async throws -> Bool
    func trimMeetingTail(
        meetingID: MeetingID,
        expectedTranscriptRevision: Int,
        cutoff: TimeInterval
    ) async throws
}

public struct TrimMeetingAudioTailRequest: Sendable {
    public let meetingID: MeetingID
    public let relativeAudioDirectory: String
    public let transcriptRevision: Int
    public let segments: [TranscriptSegment]
    public let duration: TimeInterval

    public init(
        meetingID: MeetingID,
        relativeAudioDirectory: String,
        transcriptRevision: Int,
        segments: [TranscriptSegment],
        duration: TimeInterval
    ) {
        self.meetingID = meetingID
        self.relativeAudioDirectory = relativeAudioDirectory
        self.transcriptRevision = transcriptRevision
        self.segments = segments
        self.duration = duration
    }
}

public enum TrimMeetingAudioTailError: Error, Equatable, Sendable {
    case nothingToTrim
    case unavailable
}

/// Cuts a long silent tail from both channels and the transcript (D606).
/// Copies are staged and verified first; the transcript commits with a
/// revision fence; only then are the files swapped. A failed swap leaves extra
/// silence, never transcript rows past the end of the audio.
public struct TrimMeetingAudioTail: ApplicationUseCase {
    private let resolver: any MeetingAudioChannelResolving
    private let trimmer: any MeetingAudioTrimming
    private let store: any MeetingAudioTrimStore

    public init(
        resolver: any MeetingAudioChannelResolving,
        trimmer: any MeetingAudioTrimming,
        store: any MeetingAudioTrimStore
    ) {
        self.resolver = resolver
        self.trimmer = trimmer
        self.store = store
    }

    /// Returns the seconds of audio removed.
    public func execute(_ request: TrimMeetingAudioTailRequest) async throws -> TimeInterval {
        guard let cutoff = TrailingSilence.cutoff(segments: request.segments, duration: request.duration)
        else { throw TrimMeetingAudioTailError.nothingToTrim }
        let files = try resolver.resolve(relativeAudioDirectory: request.relativeAudioDirectory).files
        guard !files.isEmpty,
            try await store.canTrimMeetingAudio(
                meetingID: request.meetingID,
                relativeAudioDirectory: request.relativeAudioDirectory)
        else { throw TrimMeetingAudioTailError.unavailable }

        let staged = try await trimmer.stageTrim(files, cutoff: cutoff)
        do {
            try Task.checkCancellation()
            try await store.trimMeetingTail(
                meetingID: request.meetingID,
                expectedTranscriptRevision: request.transcriptRevision,
                cutoff: cutoff)
        } catch {
            trimmer.discardTrim(staged)
            throw error
        }
        try trimmer.commitTrim(originals: files, staged: staged)
        return request.duration - cutoff
    }
}

extension MeetingStore: MeetingAudioTrimStore {}

/// Production trimmer over AudioPlaybackKit's verified copies.
public struct AudioFileTailTrimmer: MeetingAudioTrimming {
    public init() {}

    public func stageTrim(_ files: [URL], cutoff: TimeInterval) async throws -> [URL] {
        try await AudioTailTrimmer.stage(files, cutoff: cutoff)
    }

    public func commitTrim(originals: [URL], staged: [URL]) throws {
        try AudioTailTrimmer.commit(originals: originals, staged: staged)
    }

    public func discardTrim(_ staged: [URL]) {
        AudioTailTrimmer.discard(staged)
    }
}
