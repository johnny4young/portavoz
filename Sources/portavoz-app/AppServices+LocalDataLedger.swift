import ApplicationKit
import AudioCaptureKit
import DiarizationKit
import Foundation
import StorageKit

@MainActor
final class AppLocalDataLedgerModelClient: LocalDataLedgerModelClient {
    private let useCase: LoadLocalDataLedger

    init(useCase: LoadLocalDataLedger) {
        self.useCase = useCase
    }

    func loadLocalDataLedger() async throws -> LocalDataLedgerSnapshot {
        try await useCase.execute(())
    }
}

struct AppLocalMeetingCounter: LocalMeetingCounting {
    let store: MeetingStore

    func liveMeetingCount() async throws -> Int {
        try await store.liveMeetingCount()
    }
}

struct AppLocalAudioUsageMeter: LocalAudioUsageMeasuring {
    func localAudioBytes() async throws -> Int64 {
        let root = RecordingsLocation.shared.currentRoot()
        return try await Task.detached(priority: .utility) {
            try allocatedSize(of: root)
        }.value
    }
}

struct AppLocalVoiceCounter: LocalVoiceCounting {
    let usesTemporaryStore: Bool

    func localVoiceCount() async throws -> Int {
        guard !usesTemporaryStore else { return 0 }
        return try await Task.detached(priority: .utility) {
            let remembered = try VoiceGallery().voices().count
            let enrolled = try VoiceprintStore().load() == nil ? 0 : 1
            return remembered + enrolled
        }.value
    }
}

/// Total allocated size of regular files in a directory tree. A missing root
/// is a verified empty receipt; an unreadable tree is unavailable, not zero.
private func allocatedSize(of root: URL) throws -> Int64 {
    let manager = FileManager.default
    guard manager.fileExists(atPath: root.path) else { return 0 }
    let keys: Set<URLResourceKey> = [
        .totalFileAllocatedSizeKey,
        .fileAllocatedSizeKey,
        .fileSizeKey,
        .isRegularFileKey
    ]
    var traversalError: Error?
    guard let enumerator = manager.enumerator(
        at: root,
        includingPropertiesForKeys: Array(keys),
        errorHandler: { _, error in
            traversalError = error
            return false
        }
    ) else { throw LocalDataLedgerAdapterError.audioUnavailable }
    var total: Int64 = 0
    for case let url as URL in enumerator {
        let values = try url.resourceValues(forKeys: keys)
        guard values.isRegularFile == true else { continue }
        guard let bytes = values.totalFileAllocatedSize
            ?? values.fileAllocatedSize
            ?? values.fileSize
        else { throw LocalDataLedgerAdapterError.audioUnavailable }
        total += Int64(bytes)
    }
    if let traversalError { throw traversalError }
    return total
}

private enum LocalDataLedgerAdapterError: Error {
    case audioUnavailable
}
