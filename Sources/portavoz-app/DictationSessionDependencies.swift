import AppKit
import AudioCaptureKit
import Foundation
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
    var captureDestination: () -> CapturedDictationDestination
    var copyText: (String) -> Bool
    var defaults: UserDefaults
    var now: () -> Date = Date.init

    static func live(services: AppServices) -> Self {
        Self(
            makeMicrophone: {
                let source = MicrophoneSource()
                return Microphone(source: source, warmUp: { await source.warmUp() })
            },
            acquireRuntime: { [weak services] in
                guard let services else { throw CancellationError() }
                return services.liveTranscriptionRuntime(try await services.acquireLiveSpeechRuntime())
            },
            canInsert: { TextInserter.canInsert(promptIfNeeded: true) },
            captureDestination: { TextInserter.captureDestination() },
            copyText: { TextInserter.copy($0) },
            defaults: .standard)
    }
}
