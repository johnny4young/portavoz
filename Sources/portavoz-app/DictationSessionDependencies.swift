import AppKit
import AudioCaptureKit
import Foundation
import PortavozCore
import TranscriptionKit

/// Session-scoped side effects. The controller still owns the production
/// lifecycle; disposable tests replace audio and model work, not that lifecycle.
@MainActor
struct DictationSessionDependencies {
    struct Microphone: Sendable {
        let source: any AudioCaptureSource
        let warmUp: @Sendable () async -> Void
    }

    var makeMicrophone: () -> Microphone
    var acquireRuntime: () async throws -> LiveTranscriptionRuntime
    var canInsert: () -> Bool
    var targetName: () -> String?
    var insert: (String) async -> TextInserter.InsertionResult
    var defaults: UserDefaults
    var now: () -> Date = Date.init
    /// Capture admission is independent of the model's active-use lease.
    /// Its completion belongs to this session, never the controller's next one.
    var beginCapture: () -> () -> Void
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
            makeMicrophone: {
                let source = MicrophoneSource()
                return Microphone(source: source, warmUp: { await source.warmUp() })
            },
            acquireRuntime: { [weak services] in
                guard let services else { throw CancellationError() }
                return try await services.acquireLiveTranscriptionRuntime(for: .dictation)
            },
            canInsert: { TextInserter.canInsert(promptIfNeeded: true) },
            targetName: { NSWorkspace.shared.frontmostApplication?.localizedName },
            insert: { await TextInserter.insert($0) },
            defaults: services.defaults,
            beginCapture: beginCapture)
    }
}
