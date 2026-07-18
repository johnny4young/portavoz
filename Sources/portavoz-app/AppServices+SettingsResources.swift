import ApplicationKit
import AudioCaptureKit
import DiarizationKit
import Foundation
import StorageKit

extension AppServices {
    func audioInputOptions() async -> [AudioInputOption] {
        (try? await LoadAudioInputOptions(inputs: AppAudioInputListing()).execute(())) ?? []
    }

    func recordingStorageLocation() async -> RecordingStorageLocation {
        let result = try? await ManageRecordingStorage(
            storage: AppRecordingStorageManager()
        ).execute(ManageRecordingStorageRequest(action: .inspect))
        guard case .location(let location) = result else {
            let fallback = RecordingsLocation.shared
            return RecordingStorageLocation(
                currentRoot: fallback.currentRoot(),
                defaultRoot: fallback.defaultRoot,
                isCustom: fallback.isCustom)
        }
        return location
    }

    func updateRecordingStorage(
        to destination: URL?,
        progress: @escaping @MainActor (RecordingStorageProgress) -> Void
    ) async throws -> (location: RecordingStorageLocation, recordingCount: Int) {
        let result = try await ManageRecordingStorage(
            storage: AppRecordingStorageManager()
        ).execute(ManageRecordingStorageRequest(
            action: .move(to: destination),
            progress: { update in
                await MainActor.run { progress(update) }
            }))
        guard case .moved(let location, let recordingCount) = result else {
            preconditionFailure("Recording storage update returned an inspection result")
        }
        return (location, recordingCount)
    }

    func rememberedVoiceSummaries() async throws -> [RememberedVoiceSummary] {
        let result = try await ManageRememberedVoices(
            catalog: AppRememberedVoiceCatalog(
                gallery: voiceGallery,
                usesTemporaryStore: ProcessInfo.processInfo.arguments
                    .contains("-use-temp-store"))
        ).execute(.list)
        guard case .voices(let voices) = result else { return [] }
        return voices
    }

    func removeRememberedVoice(id: UUID) async throws {
        _ = try await ManageRememberedVoices(
            catalog: AppRememberedVoiceCatalog(
                gallery: voiceGallery,
                usesTemporaryStore: ProcessInfo.processInfo.arguments
                    .contains("-use-temp-store"))
        ).execute(.remove(id))
    }

    func removeAllRememberedVoices() async throws {
        _ = try await ManageRememberedVoices(
            catalog: AppRememberedVoiceCatalog(
                gallery: voiceGallery,
                usesTemporaryStore: ProcessInfo.processInfo.arguments
                    .contains("-use-temp-store"))
        ).execute(.removeAll)
    }
}

private struct AppAudioInputListing: AudioInputListing {
    func audioInputOptions() async throws -> [AudioInputOption] {
        try await Task.detached(priority: .utility) {
            try AudioDeviceCatalog.inputDevices().map {
                AudioInputOption(uid: $0.uid, name: $0.name)
            }
        }.value
    }
}

private struct AppRecordingStorageManager: RecordingStorageManaging {
    private let location = RecordingsLocation.shared

    func recordingStorageLocation() async -> RecordingStorageLocation {
        RecordingStorageLocation(
            currentRoot: location.currentRoot(),
            defaultRoot: location.defaultRoot,
            isCustom: location.isCustom)
    }

    func migrateRecordingStorage(
        to destination: URL?,
        progress: @escaping RecordingStorageProgressHandler
    ) async throws -> Int {
        let origin = location.currentRoot()
        let resolvedDestination = destination ?? location.defaultRoot
        let (updates, continuation) = AsyncStream<RecordingStorageProgress>.makeStream()
        let progressTask = Task {
            for await update in updates {
                await progress(update)
            }
        }
        do {
            let moved = try await Task.detached(priority: .userInitiated) {
                try location.migrateAudio(from: origin, to: resolvedDestination) { completed, total in
                    continuation.yield(RecordingStorageProgress(
                        completed: completed,
                        total: total))
                }
            }.value
            continuation.finish()
            await progressTask.value
            try location.setRoot(destination)
            return moved
        } catch {
            continuation.finish()
            await progressTask.value
            throw error
        }
    }
}

private struct AppRememberedVoiceCatalog: RememberedVoiceCatalogManaging {
    let gallery: VoiceGallery
    let usesTemporaryStore: Bool

    func rememberedVoiceSummaries() async throws -> [RememberedVoiceSummary] {
        guard !usesTemporaryStore else { return [] }
        return try await Task.detached(priority: .utility) {
            try gallery.voices().map {
                RememberedVoiceSummary(
                    id: $0.id,
                    name: $0.name,
                    createdAt: $0.createdAt)
            }
        }.value
    }

    func removeRememberedVoice(id: UUID) async throws {
        guard !usesTemporaryStore else { return }
        try await Task.detached(priority: .utility) {
            try gallery.remove(id: id)
        }.value
    }

    func removeAllRememberedVoices() async throws {
        guard !usesTemporaryStore else { return }
        try await Task.detached(priority: .utility) {
            try gallery.deleteAll()
        }.value
    }
}
