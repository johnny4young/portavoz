import Foundation

/// Content-free liveness evidence emitted while structural audio capture is
/// active. A stall means frames stopped arriving; it does not mean the channel
/// was merely silent, because silent PCM still produces frames.
public enum RecordingCaptureHealthEvent: Equatable, Sendable {
    case stalled(channel: AudioChannel, secondsWithoutFrames: TimeInterval)
    case recoveryRequested(
        channel: AudioChannel,
        attempt: Int,
        secondsWithoutFrames: TimeInterval
    )
    case recovered(channel: AudioChannel, outageSeconds: TimeInterval)
    case streamFailed(channel: AudioChannel)
}
