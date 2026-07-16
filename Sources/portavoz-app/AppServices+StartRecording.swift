import ApplicationKit
import AudioCaptureKit
import DiarizationKit
import Foundation
import ModelStoreKit
import PortavozCore
import TranscriptionKit

extension AppServices {
    /// Recording-start workflow composed from platform preferences, capture
    /// runtime, filesystem evidence, and the durable MeetingStore adapter.
    var startRecording: StartRecording {
        StartRecording(
            preferences: AppStartRecordingPreferences(),
            audioFiles: AppStartRecordingAudioFiles(root: Self.audioRoot),
            store: store,
            runtime: AppStartRecordingRuntime(
                services: self,
                audioRoot: Self.audioRoot))
    }
}

@MainActor
private struct AppStartRecordingPreferences: StartRecordingPreferences {
    func startRecordingPreferences() async -> StartRecordingPreferencesSnapshot {
        let defaults = UserDefaults.standard
        let inputID = defaults.string(forKey: "preferredInputUID")
        let preferredInput = inputID == nil || inputID == "default" ? nil : inputID
        let mode: StartRecordingCaptureMode
        switch defaults.string(forKey: "captureMode") {
        case "app": mode = .meetingApps
        case "system": mode = .system
        default: mode = .automatic
        }
        return StartRecordingPreferencesSnapshot(
            titleTemplate: defaults.string(forKey: "titleTemplate")
                ?? TitleTemplate.defaultTemplate,
            titleLocaleIdentifier: Locale.current.identifier,
            transcriptLanguage: MeetingLanguagePreferences.transcript(),
            vocabulary: VocabularyPrompt.parse(
                defaults.string(forKey: "customVocabulary") ?? ""),
            voiceProcessingEnabled: defaults.object(forKey: "aecEnabled") as? Bool ?? true,
            preferredInputDeviceID: preferredInput,
            captureMode: mode)
    }
}

private struct AppStartRecordingAudioFiles: StartRecordingAudioFiles {
    let root: URL

    func captureFileExists(relativePath: String) async -> Bool {
        let fileURL = root.appendingPathComponent(relativePath)
        return await Task.detached(priority: .utility) {
            FileManager.default.fileExists(atPath: fileURL.path)
        }.value
    }
}

@MainActor
private final class AppStartRecordingRuntime: StartRecordingRuntime {
    private struct Prepared {
        let microphone: MicrophoneSource
        let warmup: Task<Void, Never>
        let sources: [any AudioCaptureSource]
        let transcriber: ParakeetEngine?
    }

    private weak var services: AppServices?
    private let audioRoot: URL
    private var prepared: Prepared?

    init(services: AppServices, audioRoot: URL) {
        self.services = services
        self.audioRoot = audioRoot
    }

    func prepare(
        preferences: StartRecordingPreferencesSnapshot
    ) async throws -> StartRecordingPreparedRuntime {
        guard let services else { throw StartRecordingRuntimeError.preparationUnavailable }
        let microphoneID = preferences.preferredInputDeviceID.flatMap { identifier in
            (try? AudioDeviceCatalog.inputDevice(matching: identifier)) != nil
                ? identifier : nil
        }
        let microphone = MicrophoneSource(
            deviceIdentifier: microphoneID,
            voiceProcessing: preferences.voiceProcessingEnabled)
        let warmup = Task { await microphone.warmUp() }

        var sources: [any AudioCaptureSource] = [microphone]
        var tappedMeetingApps: [String] = []
        if #available(macOS 14.4, *) {
            let system = await makeSystemTapSource(mode: preferences.captureMode)
            sources.append(system.source)
            tappedMeetingApps = system.appNames
        }
        let transcriber = services.transcriber
        prepared = Prepared(
            microphone: microphone,
            warmup: warmup,
            sources: sources,
            transcriber: transcriber)
        return StartRecordingPreparedRuntime(
            channels: sources.map(\.channel),
            tappedMeetingApps: tappedMeetingApps,
            liveTranscriptionAvailable: transcriber != nil)
    }

    func startCapture(
        _ request: StartRecordingCaptureRequest
    ) async throws -> any StartRecordingSession {
        guard let prepared else {
            throw StartRecordingRuntimeError.preparationUnavailable
        }
        self.prepared = nil
        let active = AppStartRecordingSession(
            outputDirectory: audioRoot.appendingPathComponent(request.audioDirectory),
            microphone: prepared.microphone,
            sources: prepared.sources,
            transcriber: prepared.transcriber,
            voiceprintTask: Task.detached(priority: .utility) {
                try? VoiceprintStore().load()
            })
        do {
            try await active.start(request)
            if prepared.transcriber == nil {
                services?.prepareRecordingEnginesInBackground()
            }
            return active
        } catch {
            await active.abortFailedStart()
            throw error
        }
    }

    func cancelPreparation() async {
        guard let prepared else { return }
        self.prepared = nil
        prepared.warmup.cancel()
        await prepared.microphone.stop()
    }

    func scheduleIdleRelease() async {
        services?.scheduleRecordingEnginesRelease()
    }

    @available(macOS 14.4, *)
    private func makeSystemTapSource(
        mode: StartRecordingCaptureMode
    ) async -> (source: ProcessTapSource, appNames: [String]) {
        let useAppTap: Bool
        switch mode {
        case .meetingApps: useAppTap = true
        case .system: useAppTap = false
        case .automatic: useAppTap = AudioDeviceCatalog.defaultOutputIsBluetooth()
        }
        let meetingApps = useAppTap ? MeetingAppDetector.running() : []
        let selfPID = ProcessInfo.processInfo.processIdentifier
        let allowedBundleIDs = Set(meetingApps.map(\.bundleID))
        let helperPIDs = useAppTap
            ? await Task.detached {
                AudioProcessCatalog.outputProducingPIDs(
                    excluding: selfPID,
                    matchingBundleIDs: allowedBundleIDs)
            }.value
            : []
        let processIDs = Array(Set(meetingApps.map(\.pid) + helperPIDs))
        return (ProcessTapSource(processIDs: processIDs), meetingApps.map(\.name))
    }
}

private actor AppStartRecordingSession: StartRecordingSession {
    private let recordingSession: RecordingSession
    private let microphone: MicrophoneSource
    private let sources: [any AudioCaptureSource]
    private let transcriber: (any TranscriptionEngine)?
    private let voiceprintTask: Task<Voiceprint?, Never>
    private var feeds: [AudioChannel: AsyncStream<AudioChunk>.Continuation] = [:]
    private var consumers: [Task<Void, Never>] = []
    private var transcriptRequiresRecovery: Bool
    private var stoppedCapture: StopRecordingCapture?

    init(
        outputDirectory: URL,
        microphone: MicrophoneSource,
        sources: [any AudioCaptureSource],
        transcriber: (any TranscriptionEngine)?,
        voiceprintTask: Task<Voiceprint?, Never>
    ) {
        recordingSession = RecordingSession(outputDirectory: outputDirectory)
        self.microphone = microphone
        self.sources = sources
        self.transcriber = transcriber
        transcriptRequiresRecovery = transcriber == nil
        self.voiceprintTask = voiceprintTask
    }

    func start(_ request: StartRecordingCaptureRequest) async throws {
        if let transcriber {
            startLiveTranscription(
                transcriber: transcriber,
                request: request)
        }

        let channelFeeds = feeds
        let chunk = request.callbacks.chunk
        do {
            try await recordingSession.start(sources: sources) { audio in
                channelFeeds[audio.channel]?.yield(audio)
                chunk(audio)
            }
        } catch {
            await finishLiveStreams()
            throw error
        }
    }

    private func startLiveTranscription(
        transcriber: any TranscriptionEngine,
        request: StartRecordingCaptureRequest
    ) {
        for source in sources {
            let (stream, continuation) = AsyncStream.makeStream(of: AudioChunk.self)
            feeds[source.channel] = continuation
            let segments = transcriber.transcribe(
                stream,
                hints: TranscriptionHints(
                    language: request.languageHint,
                    vocabulary: request.vocabulary,
                    meetingID: request.meetingID))
            let caption = request.callbacks.caption
            consumers.append(Task {
                do {
                    for try await segment in segments {
                        await caption(segment)
                    }
                } catch {
                    // One dead transcript lane never stops capture or its peer.
                    self.markTranscriptForRecovery()
                }
            })
        }
    }

    func stop() async -> StopRecordingCapture {
        if let stoppedCapture { return stoppedCapture }
        let summary = await recordingSession.stop()
        await finishLiveStreams()
        let capture = StopRecordingCapture(
            summary,
            transcriptRequiresRecovery: transcriptRequiresRecovery)
        stoppedCapture = capture
        return capture
    }

    func voiceprint() async -> Voiceprint? {
        await voiceprintTask.value
    }

    func cancelVoiceprintRead() async {
        voiceprintTask.cancel()
    }

    nonisolated func setMicrophoneMuted(_ value: Bool) {
        microphone.setMuted(value)
    }

    func abortFailedStart() async {
        await finishLiveStreams()
        voiceprintTask.cancel()
        await microphone.stop()
    }

    private func finishLiveStreams() async {
        for continuation in feeds.values { continuation.finish() }
        feeds = [:]
        let pending = consumers
        consumers = []
        for consumer in pending { await consumer.value }
    }

    private func markTranscriptForRecovery() {
        transcriptRequiresRecovery = true
    }
}
