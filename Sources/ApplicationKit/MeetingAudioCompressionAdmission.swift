import Foundation
import StorageKit

/// Read authority shared by presentation eligibility and the destructive workflow.
public protocol MeetingAudioCompressionChecking: Sendable {
    func canCompressMeetingAudio(relativeAudioDirectory: String) async throws -> Bool
}

extension MeetingStore: MeetingAudioCompressionChecking {}

/// Refreshes mutation eligibility without recreating the playback session.
public struct CheckMeetingAudioCompression: ApplicationUseCase {
    private let resolver: any MeetingAudioChannelResolving
    private let admission: any MeetingAudioCompressionChecking

    public init(resolver: any MeetingAudioChannelResolving, admission: any MeetingAudioCompressionChecking) {
        self.resolver = resolver
        self.admission = admission
    }

    public func execute(_ relativeAudioDirectory: String) async throws -> Bool {
        guard try await admission.canCompressMeetingAudio(relativeAudioDirectory: relativeAudioDirectory) else {
            return false
        }
        return try resolver.resolve(relativeAudioDirectory: relativeAudioDirectory).containsRawAudio
    }
}

public enum MeetingAudioCompressionError: Error, Equatable, LocalizedError, Sendable {
    case unavailable

    public var errorDescription: String? {
        "Complete the audio import before compressing it."
    }
}
