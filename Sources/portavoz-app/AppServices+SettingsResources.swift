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
            storage: AppRecordingStorageManager(),
            // Settings is a separate scene with no recording-phase gate, so
            // the move is reachable mid-capture. Moving a live meeting's
            // directory across volumes copies and then unlinks it underneath
            // the open writers.
            activity: AppRecordingStorageActivity(recording: recording)
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
        let arguments = ProcessInfo.processInfo.arguments
        let usesTemporaryStore = arguments.contains("-use-temp-store")
        let result = try await ManageRememberedVoices(
            catalog: AppRememberedVoiceCatalog(
                gallery: voiceGallery,
                usesTemporaryStore: usesTemporaryStore,
                simulateUnavailable: usesTemporaryStore
                    && arguments.contains("-simulate-voice-storage-unavailable"))
        ).execute(.list)
        guard case .voices(let voices) = result else { return [] }
        return voices
    }

    func removeRememberedVoice(id: UUID) async throws {
        let arguments = ProcessInfo.processInfo.arguments
        let usesTemporaryStore = arguments.contains("-use-temp-store")
        _ = try await ManageRememberedVoices(
            catalog: AppRememberedVoiceCatalog(
                gallery: voiceGallery,
                usesTemporaryStore: usesTemporaryStore,
                simulateUnavailable: usesTemporaryStore
                    && arguments.contains("-simulate-voice-storage-unavailable"))
        ).execute(.remove(id))
    }

    func removeAllRememberedVoices() async throws {
        let arguments = ProcessInfo.processInfo.arguments
        let usesTemporaryStore = arguments.contains("-use-temp-store")
        _ = try await ManageRememberedVoices(
            catalog: AppRememberedVoiceCatalog(
                gallery: voiceGallery,
                usesTemporaryStore: usesTemporaryStore,
                simulateUnavailable: usesTemporaryStore
                    && arguments.contains("-simulate-voice-storage-unavailable"))
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

@MainActor
private struct AppRecordingStorageActivity: RecordingStorageActivity {
    let recording: RecordingController

    /// `processing` counts as busy: post-capture workers still read the
    /// meeting's audio, and publication resolves paths under the current root.
    func recordingStorageIsBusy() async -> Bool {
        switch recording.phase {
        case .preparing, .recording, .processing: true
        case .idle, .done, .failed: false
        }
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
            // Translated here rather than leaked upward: presentation reads
            // ApplicationKit errors, and a bare StorageKit error would render
            // as an opaque description under a "nothing was lost" message that
            // is false for exactly this case.
            if case RecordingsMigrationError.stranded(let count, let at, _) = error {
                throw ManageRecordingStorageError.recordingsStranded(
                    count: count,
                    path: at.path)
            }
            throw error
        }
    }
}

private struct AppRememberedVoiceCatalog: RememberedVoiceCatalogManaging {
    let gallery: VoiceGallery
    let usesTemporaryStore: Bool
    let simulateUnavailable: Bool

    func rememberedVoiceSummaries() async throws -> [RememberedVoiceSummary] {
        if simulateUnavailable {
            throw VoiceprintStore.VoiceprintError.missingKey
        }
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
