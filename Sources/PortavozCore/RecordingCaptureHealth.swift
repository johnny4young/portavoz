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

    public var channel: AudioChannel {
        switch self {
        case .stalled(let channel, _),
             .recoveryRequested(let channel, _, _),
             .recovered(let channel, _),
             .streamFailed(let channel):
            channel
        }
    }
}

/// A long callback outage may mean the call ended while Portavoz remained
/// open. Recovery continues, but presentation should make Stop prominent
/// after a conservative delay instead of ending a recording automatically.
public enum RecordingOutageNudgePolicy {
    public static let stopSuggestionDelay: TimeInterval = 120

    public static func shouldSuggestStop(
        secondsWithoutFrames: TimeInterval
    ) -> Bool {
        secondsWithoutFrames.isFinite
            && secondsWithoutFrames >= stopSuggestionDelay
    }
}
