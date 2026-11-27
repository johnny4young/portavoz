import Foundation
import PortavozCore
import Synchronization

/// Deterministic state machine for the field failure where one capture channel
/// keeps delivering frames after its peer stops calling back entirely.
/// Silence is intentionally irrelevant: a silent source still supplies frames.
struct SystemCaptureLivenessPolicy {
    struct Configuration: Sendable {
        let stallAfter: TimeInterval
        let retryEvery: TimeInterval

        init(stallAfter: TimeInterval = 8, retryEvery: TimeInterval = 8) {
            self.stallAfter = stallAfter
            self.retryEvery = retryEvery
        }
    }

    enum Signal: Equatable {
        case stalled(channel: AudioChannel, secondsWithoutFrames: TimeInterval)
        case recoveryDue(channel: AudioChannel, attempt: Int, secondsWithoutFrames: TimeInterval)
        case recovered(channel: AudioChannel, outageSeconds: TimeInterval)
    }

    private struct Incident {
        let startedAt: TimeInterval
        var attempts: Int
        var lastAttemptAt: TimeInterval
    }

    private let configuration: Configuration
    private var lastFrameAt: [AudioChannel: TimeInterval] = [:]
    private var incidents: [AudioChannel: Incident] = [:]

    init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    mutating func retire(channel: AudioChannel) {
        lastFrameAt.removeValue(forKey: channel)
        incidents.removeValue(forKey: channel)
    }

    mutating func observe(channel: AudioChannel, at timestamp: TimeInterval) -> [Signal] {
        guard let peer = Self.peer(for: channel) else { return [] }
        lastFrameAt[channel] = timestamp

        var signals: [Signal] = []
        if let recoveredIncident = incidents.removeValue(forKey: channel) {
            signals.append(.recovered(
                channel: channel,
                outageSeconds: max(0, timestamp - recoveredIncident.startedAt)))
        }

        guard let peerLastFrameAt = lastFrameAt[peer] else { return signals }
        let outage = max(0, timestamp - peerLastFrameAt)
        guard outage >= configuration.stallAfter else { return signals }

        if var incident = incidents[peer] {
            guard timestamp - incident.lastAttemptAt >= configuration.retryEvery else {
                return signals
            }
            incident.attempts += 1
            incident.lastAttemptAt = timestamp
            incidents[peer] = incident
            signals.append(.recoveryDue(
                channel: peer,
                attempt: incident.attempts,
                secondsWithoutFrames: outage))
            return signals
        }

        incidents[peer] = Incident(
            startedAt: peerLastFrameAt,
            attempts: 1,
            lastAttemptAt: timestamp)
        signals.append(.stalled(channel: peer, secondsWithoutFrames: outage))
        signals.append(.recoveryDue(channel: peer, attempt: 1, secondsWithoutFrames: outage))
        return signals
    }

    private static func peer(for channel: AudioChannel) -> AudioChannel? {
        switch channel {
        case .microphone: .system
        case .system: .microphone
        case .room: nil
        }
    }
}

/// Lock-protected façade that keeps callback liveness off the
/// `RecordingSession` actor's hot path. Audio writers ask this monitor for a
/// pure state transition after each persisted chunk; only the rare non-empty
/// signal list crosses back to the actor to request source recovery.
final class SystemCaptureLivenessMonitor: Sendable {
    private let configuration: SystemCaptureLivenessPolicy.Configuration
    private let monotonicNow: @Sendable () -> TimeInterval
    private let policy: Mutex<SystemCaptureLivenessPolicy>

    init(
        configuration: SystemCaptureLivenessPolicy.Configuration = .init(),
        monotonicNow: @escaping @Sendable () -> TimeInterval = {
            ProcessInfo.processInfo.systemUptime
        }
    ) {
        self.configuration = configuration
        self.monotonicNow = monotonicNow
        policy = Mutex(SystemCaptureLivenessPolicy(configuration: configuration))
    }

    func observe(channel: AudioChannel) -> [SystemCaptureLivenessPolicy.Signal] {
        policy.withLock { state in
            state.observe(channel: channel, at: monotonicNow())
        }
    }

    func retire(channel: AudioChannel) {
        policy.withLock { state in
            state.retire(channel: channel)
        }
    }

    func reset() {
        policy.withLock { state in
            state = SystemCaptureLivenessPolicy(configuration: configuration)
        }
    }
}
