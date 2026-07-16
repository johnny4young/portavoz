import ApplicationKit
import AudioCaptureKit
import CryptoKit
import DiarizationKit
import Foundation
import IntelligenceKit
import ModelStoreKit
import PortavozCore
import StorageKit
import TranscriptionKit

extension AppServices {
    /// Refine draft/apply workflows composed from the shared local engines and
    /// private platform adapters.
    var refineMeeting: RefineMeetingUseCases {
        RefineMeetingUseCases(
            audioFiles: AppRefineMeetingAudioFiles(store: store),
            preferences: AppRefineMeetingPreferences(
                snapshot: RefineMeetingPreferencesSnapshot(
                    transcriptLanguage: MeetingLanguagePreferences.transcript(),
                    vocabulary: VocabularyPrompt.parse(
                        UserDefaults.standard.string(forKey: "customVocabulary") ?? ""))),
            processor: AppRefineMeetingProcessor(services: self),
            store: store,
            companion: AppRefineMeetingCompanion())
    }
}

private struct AppRefineMeetingAudioFiles: RefineMeetingAudioFiles {
    let store: MeetingStore

    func resolveRefineAudio(
        _ relativeDirectory: String,
        meetingID: MeetingID
    ) async throws -> RefineMeetingAudio {
        let assets = (try? await store.audioAssets(for: meetingID)) ?? []
        let base = RecordingsLocation.shared.resolve(relativeDirectory)
        return try await Task.detached(priority: .utility) {
            let systemURL = MeetingAudioLayout.channelFile(named: "system", in: base)
            let microphoneURL = MeetingAudioLayout.channelFile(named: "microphone", in: base)
            return RefineMeetingAudio(
                system: try Self.channel(
                    .system,
                    fileURL: systemURL,
                    relativeDirectory: relativeDirectory,
                    assets: assets),
                microphone: try Self.channel(
                    .microphone,
                    fileURL: microphoneURL,
                    relativeDirectory: relativeDirectory,
                    assets: assets))
        }.value
    }

    private static func channel(
        _ channel: AudioChannel,
        fileURL: URL?,
        relativeDirectory: String,
        assets: [AudioAsset]
    ) throws -> RefineMeetingAudioChannel? {
        guard let fileURL else { return nil }
        let relativePath = "\(relativeDirectory)/\(fileURL.lastPathComponent)"
        let asset = assets.last {
            $0.channel == channel
                && $0.role == .capture
                && $0.supersededAt == nil
                && $0.relativePath == relativePath
        }
        let contentFingerprint = try trustedChecksum(asset, fileURL: fileURL)
            ?? sha256(of: fileURL)
        return RefineMeetingAudioChannel(
            fileURL: fileURL,
            isSilent: AudioSilence.fileIsSilent(at: fileURL),
            contentFingerprint: contentFingerprint)
    }

    private static func trustedChecksum(
        _ asset: AudioAsset?,
        fileURL: URL
    ) throws -> String? {
        guard let asset,
              let sha256 = asset.sha256,
              !sha256.isEmpty,
              let expectedBytes = asset.byteCount
        else { return nil }
        let values = try fileURL.resourceValues(forKeys: [.fileSizeKey])
        guard values.fileSize.map(Int64.init) == expectedBytes else { return nil }
        return sha256
    }

    private static func sha256(of fileURL: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1 << 20), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

private struct AppRefineMeetingPreferences: RefineMeetingPreferences {
    let snapshot: RefineMeetingPreferencesSnapshot

    func refineMeetingPreferences() -> RefineMeetingPreferencesSnapshot { snapshot }
}

@MainActor
private final class AppRefineMeetingProcessor: RefineMeetingProcessor {
    private weak var services: AppServices?
    private let descriptor: ModelDescriptor

    init(services: AppServices) {
        self.services = services
        descriptor = AppServices.preferredWhisperDescriptor()
    }

    func transcriptionProvider() -> RefineMeetingTranscriptionProvider {
        RefineMeetingTranscriptionProvider(
            providerID: "whisperkit/coreml",
            modelID: descriptor.id,
            modelRevision: descriptor.revision)
    }

    func prepare(progress: @escaping RefineMeetingProgressHandler) async throws {
        guard let services else { throw AppRefineMeetingError.servicesUnavailable }
        _ = try await services.loadWhisperIfNeeded(
            descriptor: descriptor,
            progress: { _ in },
            downloadProgress: { size, percent in
                Task { await progress(.downloadingWhisper(size: size, percent: percent)) }
            })
        try await services.loadEnginesIfNeeded()
    }

    func transcribe(
        fileURL: URL,
        hints: TranscriptionHints,
        channel: AudioChannel
    ) async throws -> FileTranscription {
        guard let whisper = services?.whisper else {
            throw AppRefineMeetingError.transcriberUnavailable
        }
        return try await whisper.transcribeFile(
            at: fileURL,
            hints: hints,
            channel: channel)
    }

    func diarize(fileURL: URL) async throws -> [SpeakerTurn] {
        guard let diarizer = services?.diarizer else {
            throw AppRefineMeetingError.diarizerUnavailable
        }
        return try await diarizer.diarizeFile(at: fileURL)
    }

    func scheduleIdleRelease() {
        services?.scheduleWhisperRelease()
        services?.scheduleRecordingEnginesRelease()
    }
}

@MainActor
private final class AppRefineMeetingCompanion: RefineMeetingCompanion {
    func isRefreshAvailable() -> Bool {
        guard FoundationModelsCapability.current().isAvailable else { return false }
        guard #available(macOS 26.0, *) else { return false }
        return UserDefaults.standard.bool(forKey: "companionEnabled")
    }

    func refresh(
        segments: [TranscriptSegment],
        meetingID: MeetingID,
        transcriptRevision: Int
    ) async -> RefineMeetingCompanionRefresh {
        guard #available(macOS 26.0, *) else {
            return RefineMeetingCompanionRefresh(cards: [], completed: false)
        }
        let result = await CompanionRefresh.regenerate(
            from: segments,
            meetingID: meetingID,
            transcriptRevision: transcriptRevision)
        return RefineMeetingCompanionRefresh(
            cards: [],
            artifacts: result.artifacts,
            terminalRuns: result.terminalRuns,
            completed: result.completed)
    }
}

private enum AppRefineMeetingError: Error {
    case servicesUnavailable
    case transcriberUnavailable
    case diarizerUnavailable
}
