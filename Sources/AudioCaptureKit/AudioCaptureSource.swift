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

/// What happens to raw audio files after a meeting — a first-class privacy
/// and disk-space control, configurable per meeting or globally.
public enum AudioRetentionPolicy: Codable, Sendable, Equatable {
    /// Keep the recording indefinitely.
    case keep
    /// Delete the audio N days after the meeting ends (transcript is kept).
    case deleteAfter(days: Int)
    /// Delete the audio as soon as transcription completes.
    case deleteAfterTranscription
}
