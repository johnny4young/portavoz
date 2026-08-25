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
        if BenchSyntheticCapturePolicy.requested(
            arguments: ProcessInfo.processInfo.arguments
        ) {
            runtime = BenchSyntheticStartRecordingRuntime(
                services: self,
                audioRoot: Self.audioRoot)
        } else if isRecordingFailureFixture {
            runtime = UITestStartRecordingFailureRuntime()
        } else if isSystemCaptureStallFixture {
            runtime = UITestSystemCaptureStallRuntime()
        } else if isSystemAudioClippingFixture {
            runtime = UITestSystemAudioClippingRuntime()
        } else if isInterviewAssistFixture {
            runtime = UITestInterviewAssistRuntime()
        } else if isLiveTranscriptBrowsingFixture {
            runtime = UITestLiveTranscriptBrowsingRuntime()
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
            runtime: runtime,
            telemetry: workloadTelemetry)
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

    private var isSystemAudioClippingFixture: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains("-use-temp-store")
            && arguments.contains("-simulate-system-audio-clipping")
    }

    private var isLiveTranscriptionAttachFixture: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains("-use-temp-store")
            && arguments.contains("-simulate-live-transcription-attach")
    }

    private var isLiveTranscriptBrowsingFixture: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains("-use-temp-store")
            && arguments.contains("-simulate-live-transcript-browsing")
    }

    private var isInterviewAssistFixture: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains("-use-temp-store")
            && arguments.contains("-simulate-interview-assist")
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

private struct UITestSystemAudioClippingRuntime: StartRecordingRuntime {
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
        let observationCount = Int(
            SustainedCeilingDetector.minimumObservedDuration / 0.01)
        for index in 0..<observationCount {
            request.callbacks.level(PersistedAudioLevel(
                channel: .system,
                peak: 1,
                rms: 0.4,
                timestamp: TimeInterval(index) / 100,
                duration: 0.01))
        }
        return UITestSystemCaptureStallSession()
    }

    func cancelPreparation() async {}
    func scheduleIdleRelease() async {}
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
        UITestRuntimeSignal.mark(
            environmentKey: "PORTAVOZ_UI_TEST_ATTACH_PREPARING_PATH")
        Task {
            do {
                try await UITestRuntimeSignal.wait(
                    forEnvironmentKey: "PORTAVOZ_UI_TEST_ATTACH_CONTINUE_PATH")
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

private struct UITestLiveTranscriptBrowsingRuntime: StartRecordingRuntime {
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
        request.callbacks.liveTranscription(.available)
        Task {
            do {
                try await Task.sleep(for: .milliseconds(400))
                for index in 1...18 {
                    try await emit(index, request: request)
                }
                UITestRuntimeSignal.mark(
                    environmentKey: "PORTAVOZ_UI_TEST_LIVE_FRONTIER_PATH")
                // XCUITest owns this boundary: the first 18 rows remain a
                // stable reader frontier until the test has scrolled away.
                try await UITestRuntimeSignal.wait(
                    forEnvironmentKey: "PORTAVOZ_UI_TEST_LIVE_RESUME_PATH")
                for index in 19...24 {
                    try await emit(index, request: request)
                }
                UITestRuntimeSignal.mark(
                    environmentKey: "PORTAVOZ_UI_TEST_LIVE_COMPLETE_PATH")
            } catch {
                return
            }
        }
        return UITestSystemCaptureStallSession()
    }

    func cancelPreparation() async {}
    func scheduleIdleRelease() async {}

    private func emit(
        _ index: Int,
        request: StartRecordingCaptureRequest
    ) async throws {
        let proactive = ProcessInfo.processInfo.arguments.contains(
            "-simulate-proactive-assist")
        let start = TimeInterval(index * (proactive ? 20 : 2))
        let isRemote = index.isMultiple(of: 2)
        let text: String
        if ProcessInfo.processInfo.arguments.contains("-seed-showcase") {
            text = PublicShowcaseFixture.liveTranscriptLines[index - 1]
        } else {
            text = isRemote
                ? String(
                    format: "History row %02d remains readable during live updates.",
                    index)
                : String(
                    format: "My local update %02d stays distinct while I browse earlier captions.",
                    index)
        }
        await request.callbacks.caption(TranscriptSegment(
            meetingID: request.meetingID,
            channel: isRemote ? .system : .microphone,
            text: text,
            language: ProcessInfo.processInfo.arguments.contains("-seed-showcase")
                ? "es"
                : "en",
            startTime: start,
            endTime: start + (proactive ? 5 : 1),
            isFinal: true))
        try await Task.sleep(for: .milliseconds(90))
    }
}

private struct UITestInterviewAssistRuntime: StartRecordingRuntime {
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
        request.callbacks.liveTranscription(.available)
        Task {
            do {
                try await Task.sleep(for: .milliseconds(350))
                let spanish = Locale.current.language.languageCode?.identifier == "es"
                let rows: [(AudioChannel, String, TimeInterval)] = spanish
                    ? [
                        (.microphone,
                         "Camila: Avisaría a la responsable de base de datos "
                            + "en cinco minutos y congelaría escrituras antes "
                            + "de reconstruir réplicas.",
                         44),
                        (.microphone,
                         "Camila: No desactivaría alertas ni esperaría treinta minutos antes de avisar.",
                         71),
                        (.system,
                         "¿Qué haría Camila primero durante el incidente?",
                         90)
                    ]
                    : [
                        (.microphone,
                         "Jordan: I would page the database owner within five "
                            + "minutes and freeze writes before rebuilding replicas.",
                         41),
                        (.microphone,
                         "Jordan: I would not disable alerts or wait thirty minutes before paging the owner.",
                         67),
                        (.system,
                         "What would Jordan do first during the database incident?",
                         90)
                    ]
                for (channel, text, timestamp) in rows {
                    await request.callbacks.caption(TranscriptSegment(
                        meetingID: request.meetingID,
                        channel: channel,
                        text: text,
                        language: spanish ? "es" : "en",
                        startTime: timestamp,
                        endTime: timestamp + 2,
                        isFinal: true))
                    try await Task.sleep(for: .milliseconds(80))
                }
            } catch {
                return
            }
        }
        return UITestSystemCaptureStallSession()
    }

    func cancelPreparation() async {}
    func scheduleIdleRelease() async {}
}

/// File-backed handshakes keep disposable UI fixtures deterministic even when
/// a hosted runner needs several seconds to snapshot the accessibility tree.
/// Production recording never sets these environment keys, so its scheduler
/// and timing remain untouched.
private enum UITestRuntimeSignal {
    /// An exhausted handshake throws so the fixture stops emitting instead of
    /// resuming on a timer — a silent fallback would reintroduce the exact
    /// race this handshake removes, just 30 seconds later.
    struct HandshakeTimedOut: Error {}

    static func mark(environmentKey: String) {
        guard let path = ProcessInfo.processInfo.environment[environmentKey] else {
            return
        }
        FileManager.default.createFile(atPath: path, contents: Data())
    }

    static func wait(
        forEnvironmentKey environmentKey: String,
        attempts: Int = 600
    ) async throws {
        guard let path = ProcessInfo.processInfo.environment[environmentKey] else {
            return
        }
        for _ in 0..<attempts {
            try Task.checkCancellation()
            if FileManager.default.fileExists(atPath: path) {
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw HandshakeTimedOut()
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
        let liveTranscriptionRuntime: LiveTranscriptionRuntime?
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
        guard await services.authorizeMicrophoneForRecording() else {
            throw StartRecordingRuntimeError.preparationUnavailable
        }
        let microphoneID = preferences.preferredInputDeviceID.flatMap { identifier in
            (try? AudioDeviceCatalog.inputDevice(matching: identifier)) != nil
                ? identifier : nil
        }
        let liveSpeech = try services.acquireResidentLiveSpeechRuntime()
        let liveTranscriptionRuntime = liveSpeech.map {
            services.liveTranscriptionRuntime($0)
        }
        let microphone = MicrophoneSource(
            deviceIdentifier: microphoneID,
            // A meeting recorder must be observational. Enabling AVAudioEngine
            // voice processing also changes the output node and can duck the
            // call or contend with the meeting app's own microphone processing.
            voiceProcessing: false)
        let warmup = Task { await microphone.warmUp() }

        var sources: [any AudioCaptureSource] = [microphone]
        var tappedMeetingApps: [String] = []
        if #available(macOS 14.4, *) {
            let system = await makeSystemTapSource(mode: preferences.captureMode)
            sources.append(system.source)
            tappedMeetingApps = system.appNames
        }
        prepared = Prepared(
            microphone: microphone,
            warmup: warmup,
            sources: sources,
            liveTranscriptionRuntime: liveTranscriptionRuntime)
        return StartRecordingPreparedRuntime(
            channels: sources.map(\.channel),
            tappedMeetingApps: tappedMeetingApps,
            liveTranscriptionAvailable: liveTranscriptionRuntime != nil)
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
            liveTranscriptionRuntime: prepared.liveTranscriptionRuntime,
            transcriberLoader: { @MainActor [weak services] in
                guard let services else {
                    throw StartRecordingRuntimeError.preparationUnavailable
                }
                let runtime = try await services.acquireLiveSpeechRuntime()
                return services.liveTranscriptionRuntime(runtime)
            },
            telemetry: services.workloadTelemetry,
            voiceprintTask: Task.detached(priority: .utility) {
                try? voiceprintStore.load()
            })
        do {
            // Warm-up owns the same AVAudioEngine and restart queue as
            // capture. Do not install a tap while it may still be preparing
            // the graph on another task.
            await prepared.warmup.value
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
        prepared.liveTranscriptionRuntime?.finish()
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
    typealias TranscriberLoader = LiveTranscriptionAttacher.Loader

    private let recordingSession: RecordingSession
    private let microphone: MicrophoneSource
    private let sources: [any AudioCaptureSource]
    private var initialLiveTranscriptionRuntime: LiveTranscriptionRuntime?
    private let transcriberLoader: TranscriberLoader
    private let telemetry: ResourceWorkloadTelemetry
    private let voiceprintTask: Task<Voiceprint?, Never>
    private var liveAttacher: LiveTranscriptionAttacher?
    private var stoppedCapture: StopRecordingCapture?

    init(
        outputDirectory: URL,
        microphone: MicrophoneSource,
        sources: [any AudioCaptureSource],
        liveTranscriptionRuntime: LiveTranscriptionRuntime?,
        transcriberLoader: @escaping TranscriberLoader,
        telemetry: ResourceWorkloadTelemetry,
        voiceprintTask: Task<Voiceprint?, Never>
    ) {
        recordingSession = RecordingSession(outputDirectory: outputDirectory)
        self.microphone = microphone
        self.sources = sources
        initialLiveTranscriptionRuntime = liveTranscriptionRuntime
        self.transcriberLoader = transcriberLoader
        self.telemetry = telemetry
        self.voiceprintTask = voiceprintTask
    }

    func start(_ request: StartRecordingCaptureRequest) async throws {
        let initialRuntime = initialLiveTranscriptionRuntime
        initialLiveTranscriptionRuntime = nil
        let attacher = LiveTranscriptionAttacher(
            channels: sources.map(\.channel),
            hints: TranscriptionHints(
                language: request.languageHint,
                vocabulary: request.vocabulary,
                meetingID: request.meetingID),
            callbacks: request.callbacks,
            initialRuntime: initialRuntime,
            telemetry: telemetry)
        liveAttacher = attacher
        let liveFeeds = attacher.feeds
        let chunk = request.callbacks.chunk
        let level = request.callbacks.level
        do {
            try await recordingSession.start(sources: sources) { audio in
                liveFeeds.yield(audio)
                chunk(audio)
            } onLevel: { sample in
                level(sample)
            } onHealthEvent: { event in
                request.callbacks.health(event)
            }
            await attacher.recordingDidStart(loader: transcriberLoader)
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
        guard let liveAttacher else {
            let runtime = initialLiveTranscriptionRuntime
            initialLiveTranscriptionRuntime = nil
            await runtime?.finish()
            return runtime == nil
        }
        self.liveAttacher = nil
        return await liveAttacher.finish()
    }
}
