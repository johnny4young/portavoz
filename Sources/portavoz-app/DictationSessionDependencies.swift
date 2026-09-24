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
    var targetName: () -> String?
    var insert: (String) async -> TextInserter.InsertionResult
    var defaults: UserDefaults
    var now: () -> Date = Date.init
    var waitForFeedbackDismissal: @MainActor (Duration) async throws -> Void = {
        try await Task.sleep(for: $0)
    }

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
            targetName: { NSWorkspace.shared.frontmostApplication?.localizedName },
            insert: { await TextInserter.insert($0) },
            defaults: .standard)
    }
}
