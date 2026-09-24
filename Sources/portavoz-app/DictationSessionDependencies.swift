import AppKit
import AudioCaptureKit
import Foundation
import PlatformKit
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
    var targetName: () -> String?
    var insert: (String) async -> TextInserter.InsertionResult
    var defaults: UserDefaults
    var now: () -> Date = Date.init
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

    static func live(services: AppServices) -> Self {
        Self(
            authorizeMicrophone: { [weak services] in
                guard let services else { return false }
                return await services.microphonePermissions.authorizeIfNeeded()
            },
            makeMicrophone: { liveMicrophone(defaults: .standard) },
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
