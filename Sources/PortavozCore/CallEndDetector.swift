import Foundation

/// Notices a call that ended while the recording kept running: the remote side
/// was heard, then both channels stayed quiet. Time is captured audio time, so
/// buffer sizes and delivery jitter do not change the policy.
public struct CallEndDetector: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case listening
        case asking(secondsUntilStop: Int)
        case stopping
    }

    public static let askAfterQuiet: TimeInterval = 180
    public static let stopAfterAsking: TimeInterval = 300
    /// Remote sound needed before quiet can mean the call ended; a meeting
    /// recorded only through the microphone never asks.
    static let minimumRemoteSound: TimeInterval = 10
    /// About -50 dBFS: below any remote speech, above a silent tap.
    static let systemQuietRMS: Float = 0.003
    /// About -40 dBFS: room noise stays under it, nearby speech does not.
    static let microphoneQuietRMS: Float = 0.01
    /// Smoothing keeps a click or a cough from cancelling the countdown.
    static let smoothingTime: TimeInterval = 2

    public private(set) var state: State = .listening
    private var systemRMS: Float = 0
    private var microphoneRMS: Float = 0
    private var remoteSound: TimeInterval = 0
    private var quiet: TimeInterval = 0
    private var keptRecording = false

    public init() {}

    @discardableResult
    public mutating func observe(_ level: PersistedAudioLevel) -> State {
        guard level.duration.isFinite, level.duration > 0 else { return state }
        let weight = Float(1 - exp(-level.duration / Self.smoothingTime))
        switch level.channel {
        case .system:
            systemRMS += (level.rms - systemRMS) * weight
            if systemRMS >= Self.systemQuietRMS {
                remoteSound += level.duration
                quiet = 0
                keptRecording = false
            } else {
                quiet += level.duration
            }
        case .microphone:
            microphoneRMS += (level.rms - microphoneRMS) * weight
            if microphoneRMS >= Self.microphoneQuietRMS { quiet = 0 }
        case .room:
            return state
        }
        state = Self.state(
            quiet: quiet,
            armed: remoteSound >= Self.minimumRemoteSound && !keptRecording)
        return state
    }

    /// The user said the call is still on: stay quiet until the remote side
    /// is heard again.
    public mutating func keepRecording() {
        keptRecording = true
        quiet = 0
        state = .listening
    }

    private static func state(quiet: TimeInterval, armed: Bool) -> State {
        guard armed, quiet >= askAfterQuiet else { return .listening }
        let remaining = askAfterQuiet + stopAfterAsking - quiet
        guard remaining > 0 else { return .stopping }
        return .asking(secondsUntilStop: Int(remaining.rounded(.up)))
    }
}
