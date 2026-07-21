import Foundation
import PortavozCore

/// A source of audio (microphone, per-app system tap, room device).
/// Implementations: `MicrophoneSource` (AVAudioEngine), `ProcessTapSource`
/// (Core Audio process taps, macOS 14.4+). Arrives in M1.
public protocol AudioCaptureSource: Sendable {
    var channel: AudioChannel { get }
    /// Starts capture. The stream finishes on `stop()` and throws on device errors.
    func start() async throws -> AsyncThrowingStream<AudioChunk, Error>
    func stop() async
}

/// Optional capability for sources that can rebuild their platform graph
/// without ending the recording stream. RecordingSession discovers this
/// capability after a liveness stall; ordinary sources remain valid and are
/// still reported as stalled even when they cannot recover in place.
public protocol RecoverableAudioCaptureSource: AudioCaptureSource {
    func requestRecovery() async
}

/// Moved to PortavozCore in M5 so StorageKit can persist it per meeting;
/// the alias keeps existing `import AudioCaptureKit` call sites compiling.
public typealias AudioRetentionPolicy = PortavozCore.AudioRetentionPolicy
