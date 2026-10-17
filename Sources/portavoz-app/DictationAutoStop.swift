import Foundation
import ModelStoreKit
import TranscriptionKit

/// Off by default. Only a dictation started with a tap stops itself; a held
/// key or button already ends capture on release.
enum DictationAutoStop {
    static let defaultsKey = "dictationAutoStop"
    static let pauseKey = "dictationAutoStopPause"
    static let pauses: [TimeInterval] = [1.5, 2, 3]
    static let defaultPause: TimeInterval = 2

    static func isEnabled(in defaults: UserDefaults) -> Bool {
        defaults.bool(forKey: defaultsKey)
    }

    static func pause(in defaults: UserDefaults) -> TimeInterval {
        let stored = defaults.double(forKey: pauseKey)
        return pauses.contains(stored) ? stored : defaultPause
    }

    /// Uses the speech gate's verified detector; a missing model means no auto-stop.
    static func silero(
        store: ModelStore, pause: TimeInterval, onPause: @escaping @Sendable () -> Void
    ) -> DictationPauseDetector {
        DictationPauseDetector(pause: pause, load: {
            let detector = try await SileroVoiceActivityDetector.load(from: store, channel: .microphone)
            return { chunk in DictationSpeechGate.heardSpeech(try await detector.process(chunk)) }
        }, onPause: onPause)
    }
}
