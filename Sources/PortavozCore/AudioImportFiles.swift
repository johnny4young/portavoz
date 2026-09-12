import Foundation

/// Evidence for one copied source. This is not a decoded-audio or ASR result.
public struct AudioImportCopy: Equatable, Sendable {
    public let fileURL: URL
    public let relativeDirectory: String
    public let digest: String

    public init(fileURL: URL, relativeDirectory: String, digest: String) {
        self.fileURL = fileURL
        self.relativeDirectory = relativeDirectory
        self.digest = digest
    }
}

public protocol AudioImportFiles: Sendable {
    func prepareSelection(
        _ source: URL, meetingID: MeetingID, title: String,
        preferences: ImportMeetingPreferencesSnapshot
    ) async throws -> AudioImportRequest
    /// Serializes source revalidation, staged acquisition and publication.
    /// The caller re-reads durable ownership inside this critical section.
    func withAcquisitionAccess<Result: Sendable>(
        _ operation: @escaping @Sendable () async throws -> Result
    ) async throws -> Result
    /// Replaces only the admission's unpublished stage, after source validation.
    /// Must run inside acquisition access with a freshly owner-fenced input.
    func copySelectedAudio(_ input: AudioImportRequest) async throws -> AudioImportCopy
    func verifyOwnedAudio(_ input: AudioImportRequest) async throws -> AudioImportCopy
}

public enum AudioImportFileError: Error, Equatable, Sendable {
    case invalidSource
    case sourceChanged
    case sourceUnavailable
    case invalidOwnedCopy
    case acquisitionBusy
    case destinationOccupied
    case copyFailed
}
