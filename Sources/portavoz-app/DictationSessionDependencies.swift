import AppKit
import AudioCaptureKit
import Carbon.HIToolbox
import Foundation
import PlatformKit
import PortavozCore
import TranscriptionKit

/// Session-scoped side effects. The controller still owns the production
/// lifecycle; disposable tests replace audio and model work, not that lifecycle.
@MainActor
struct DictationSessionDependencies {
    struct Microphone: Sendable {
        let source: any AudioCaptureSource
        let warmUp: @Sendable () async -> Void
        var usesSystemFallback = false
    }

    var authorizeMicrophone: () async -> Bool
    var makeMicrophone: () -> Microphone
    var acquireRuntime: () async throws -> LiveTranscriptionRuntime
    var canInsert: () -> Bool
    var captureDestination: () -> CapturedDictationDestination
    var copyText: (String) -> Bool
    var defaults: UserDefaults
    var now: () -> Date = Date.init
    var waitForFeedbackDismissal: @MainActor (Duration) async throws -> Void = {
        try await Task.sleep(for: $0)
    }
    /// Capture admission is independent of the model's active-use lease.
    /// Its completion belongs to this session, never the controller's next one.
    var beginCapture: () -> () -> Void
    var waitForFirstBufferDeadline: @Sendable () async throws -> Void = {
        try await Task.sleep(for: .seconds(5))
    }
    /// Where the strip first appears; nil keeps it bottom-center (disposable launches).
    var locatePanelAnchor: @MainActor () -> DictationPanelAnchor? = { nil }
    /// Claims Escape system-wide while capture runs; nil leaves cancel to the panel.
    var registerCancelKey: (@escaping () -> Void) -> (any GlobalHotkeyRegistration)? = { _ in nil }

    func authorizedMicrophone() async throws -> Microphone {
        guard await authorizeMicrophone() else { throw DictationMicrophoneReadiness.Failure.permissionRequired }
        try Task.checkCancellation()
        return makeMicrophone()
    }

    static func liveMicrophone(
        defaults: UserDefaults,
        isAvailable: (String) -> Bool = { (try? AudioDeviceCatalog.inputDevice(matching: $0)) != nil },
        makeSource: (String?) -> Microphone = { identifier in
            let source = MicrophoneSource(deviceIdentifier: identifier)
            return Microphone(source: source, warmUp: { await source.warmUp() })
        }
    ) -> Microphone {
        let selection = MicrophoneInputSelection.resolve(
            MicrophoneInputSelection.preferredIdentifier(defaults: defaults), isAvailable: isAvailable)
        var microphone = makeSource(selection.deviceIdentifier)
        microphone.usesSystemFallback = selection.usesSystemFallback
        return microphone
    }

    /// Nil in ordinary composition: no observation, file, timer or telemetry.
    var measurementSink: DictationSessionMeasurementRecorder.Sink?
    var measurementClock: DictationSessionMeasurementRecorder.Clock = { .now }
    var playCue: (DictationSoundCue) -> Void = { _ in }
    /// Nil leaves delivery to the lexical check alone (the gate is opt-in).
    var makeSpeechGate: () -> DictationSpeechGate? = { nil }
    var makePauseDetector: (@escaping @Sendable () -> Void) -> DictationPauseDetector? = { _ in nil }
    /// Nil when history is off: read once when the session starts.
    var beginHistory: () -> DictationHistoryWriter? = { nil }
    /// Counts a finished dictation when statistics are on; the store checks consent.
    var recordStats: (DictationStatsSample) -> Void = { _ in }

    func transcriptionHints() -> TranscriptionHints {
        let language = defaults.string(forKey: DictationController.languageKey)
        return TranscriptionHints(
            language: ["es", "en"].contains(language) ? language : nil,
            vocabulary: VocabularyPrompt.parse(defaults.string(forKey: "customVocabulary") ?? ""),
            meetingID: MeetingID(),
            filtersLiveScript: true)
    }

    static func live(
        services: AppServices, beginCapture: @escaping () -> () -> Void
    ) -> Self {
        Self(
            authorizeMicrophone: { [weak services] in
                guard let services else { return false }
                return await services.microphonePermissions.authorizeIfNeeded()
            },
            makeMicrophone: { [defaults = services.defaults] in liveMicrophone(defaults: defaults) },
            acquireRuntime: { [weak services] in
                guard let services else { throw CancellationError() }
                return try await services.acquireLiveTranscriptionRuntime(for: .dictation)
            },
            canInsert: { TextInserter.canInsert(promptIfNeeded: true) },
            captureDestination: { TextInserter.captureDestination() },
            copyText: { TextInserter.copy($0) },
            defaults: services.defaults,
            beginCapture: beginCapture,
            locatePanelAnchor: { DictationPanelAnchor.current() },
            registerCancelKey: { GlobalHotkey(keyCode: UInt32(kVK_Escape), modifiers: 0, onPress: $0) },
            playCue: DictationSoundCue.player(defaults: services.defaults),
            makeSpeechGate: { [defaults = services.defaults, store = services.modelStore] in
                DictationSpeechGate.isEnabled(in: defaults) ? .silero(store: store) : nil
            },
            makePauseDetector: { [defaults = services.defaults, store = services.modelStore] onPause in
                guard DictationAutoStop.isEnabled(in: defaults) else { return nil }
                let pause = DictationAutoStop.pause(in: defaults)
                return DictationAutoStop.silero(store: store, pause: pause, onPause: onPause)
            })
    }
}
