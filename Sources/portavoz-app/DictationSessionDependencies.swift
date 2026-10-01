import AppKit
import AudioCaptureKit
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
    /// Capture admission is independent of the model's active-use lease.
    /// Its completion belongs to this session, never the controller's next one.
    var beginCapture: () -> () -> Void
    var waitForFirstBufferDeadline: @Sendable () async throws -> Void = {
        try await Task.sleep(for: .seconds(5))
    }

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
            beginCapture: beginCapture)
    }
}
