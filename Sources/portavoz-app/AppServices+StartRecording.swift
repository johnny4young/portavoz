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
        let runtime: any StartRecordingRuntime
        if isRecordingFailureFixture {
            runtime = UITestStartRecordingFailureRuntime()
        } else if isSystemCaptureStallFixture {
            runtime = UITestSystemCaptureStallRuntime()
        } else if isLiveTranscriptionAttachFixture {
            runtime = UITestLiveTranscriptionAttachRuntime()
        } else {
            runtime = AppStartRecordingRuntime(
                services: self,
                audioRoot: Self.audioRoot)
        }
        return StartRecording(
            preferences: AppStartRecordingPreferences(),
            audioFiles: AppStartRecordingAudioFiles(root: Self.audioRoot),
            store: store,
            runtime: runtime)
    }

    private var isRecordingFailureFixture: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains("-use-temp-store")
            && arguments.contains("-simulate-recording-start-failure")
    }

    private var isSystemCaptureStallFixture: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains("-use-temp-store")
            && arguments.contains("-simulate-system-capture-stall")
    }

    private var isLiveTranscriptionAttachFixture: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains("-use-temp-store")
            && arguments.contains("-simulate-live-transcription-attach")
    }
}

private struct UITestStartRecordingFailureRuntime: StartRecordingRuntime {
    func prepare(
        preferences: StartRecordingPreferencesSnapshot
    ) async throws -> StartRecordingPreparedRuntime {
        throw StartRecordingRuntimeError.preparationUnavailable
    }

    func startCapture(
        _ request: StartRecordingCaptureRequest
    ) async throws -> any StartRecordingSession {
        throw StartRecordingRuntimeError.preparationUnavailable
    }

    func cancelPreparation() async {}
    func scheduleIdleRelease() async {}
}

private struct UITestSystemCaptureStallRuntime: StartRecordingRuntime {
    func prepare(
        preferences: StartRecordingPreferencesSnapshot
    ) async throws -> StartRecordingPreparedRuntime {
        StartRecordingPreparedRuntime(
            channels: [.microphone, .system],
            tappedMeetingApps: ["Meet"],
            liveTranscriptionAvailable: true)
    }

    func startCapture(
        _ request: StartRecordingCaptureRequest
    ) async throws -> any StartRecordingSession {
        request.callbacks.health(.stalled(
            channel: .system,
            secondsWithoutFrames: 130))
        request.callbacks.health(.recoveryRequested(
            channel: .system,
            attempt: 1,
            secondsWithoutFrames: 130))
        return UITestSystemCaptureStallSession()
    }

    func cancelPreparation() async {}
    func scheduleIdleRelease() async {}
}

private actor UITestSystemCaptureStallSession: StartRecordingSession {
    func stop() async -> StopRecordingCapture {
        StopRecordingCapture(publishedFiles: [:])
    }

    func voiceprint() async -> Voiceprint? { nil }
    func cancelVoiceprintRead() async {}
    nonisolated func setMicrophoneMuted(_ value: Bool) {}
}

private struct UITestLiveTranscriptionAttachRuntime: StartRecordingRuntime {
    func prepare(
        preferences: StartRecordingPreferencesSnapshot
    ) async throws -> StartRecordingPreparedRuntime {
        StartRecordingPreparedRuntime(
            channels: [.microphone, .system],
            tappedMeetingApps: ["Meet"],
            liveTranscriptionAvailable: false)
    }

    func startCapture(
        _ request: StartRecordingCaptureRequest
    ) async throws -> any StartRecordingSession {
        request.callbacks.liveTranscription(.preparing)
        Task {
            do {
                try await Task.sleep(for: .seconds(2))
            } catch {
                return
            }
            request.callbacks.liveTranscription(.available)
            await request.callbacks.caption(TranscriptSegment(
                meetingID: request.meetingID,
                channel: .system,
                text: "Live captions are available now.",
                language: "en",
                startTime: 0,
                endTime: 2,
                isFinal: true))
        }
        return UITestSystemCaptureStallSession()
    }

    func cancelPreparation() async {}
    func scheduleIdleRelease() async {}
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
        guard let services else {
            throw StartRecordingRuntimeError.preparationUnavailable
        }
        self.prepared = nil
        let voiceprintStore = services.voiceprintStore
        let active = AppStartRecordingSession(
            outputDirectory: audioRoot.appendingPathComponent(request.audioDirectory),
            microphone: prepared.microphone,
            sources: prepared.sources,
            transcriber: prepared.transcriber,
            transcriberLoader: { @MainActor [weak services] in
                guard let services else {
                    throw StartRecordingRuntimeError.preparationUnavailable
                }
                return try await services.loadTranscriberIfNeeded()
            },
            voiceprintTask: Task.detached(priority: .utility) {
                try? voiceprintStore.load()
            })
        do {
            try await active.start(request)
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
    typealias TranscriberLoader = @MainActor @Sendable () async throws -> any TranscriptionEngine

    private let recordingSession: RecordingSession
    private let microphone: MicrophoneSource
    private let sources: [any AudioCaptureSource]
    private let initialTranscriber: (any TranscriptionEngine)?
    private let transcriberLoader: TranscriberLoader
    private let voiceprintTask: Task<Voiceprint?, Never>
    private var liveAttacher: LiveTranscriptionAttacher?
    private var stoppedCapture: StopRecordingCapture?

    init(
        outputDirectory: URL,
        microphone: MicrophoneSource,
        sources: [any AudioCaptureSource],
        transcriber: (any TranscriptionEngine)?,
        transcriberLoader: @escaping TranscriberLoader,
        voiceprintTask: Task<Voiceprint?, Never>
    ) {
        recordingSession = RecordingSession(outputDirectory: outputDirectory)
        self.microphone = microphone
        self.sources = sources
        initialTranscriber = transcriber
        self.transcriberLoader = transcriberLoader
        self.voiceprintTask = voiceprintTask
    }

    func start(_ request: StartRecordingCaptureRequest) async throws {
        let attacher = LiveTranscriptionAttacher(
            channels: sources.map(\.channel),
            hints: TranscriptionHints(
                language: request.languageHint,
                vocabulary: request.vocabulary,
                meetingID: request.meetingID),
            callbacks: request.callbacks,
            initialTranscriberAvailable: initialTranscriber != nil)
        liveAttacher = attacher
        let liveFeeds = attacher.feeds
        let chunk = request.callbacks.chunk
        do {
            try await recordingSession.start(sources: sources) { audio in
                liveFeeds.yield(audio)
                chunk(audio)
            } onHealthEvent: { event in
                request.callbacks.health(event)
            }
            await attacher.recordingDidStart(
                initialTranscriber: initialTranscriber,
                loader: transcriberLoader)
        } catch {
            _ = await finishLiveStreams()
            throw error
        }
    }

    func stop() async -> StopRecordingCapture {
        if let stoppedCapture { return stoppedCapture }
        let summary = await recordingSession.stop()
        let transcriptRequiresRecovery = await finishLiveStreams()
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
        _ = await finishLiveStreams()
        voiceprintTask.cancel()
        await microphone.stop()
    }

    private func finishLiveStreams() async -> Bool {
        guard let liveAttacher else { return initialTranscriber == nil }
        self.liveAttacher = nil
        return await liveAttacher.finish()
    }
}
