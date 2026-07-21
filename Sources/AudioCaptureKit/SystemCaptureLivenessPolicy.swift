import Foundation
import PortavozCore

/// Deterministic state machine for the field failure where microphone frames
/// keep arriving after the remote/system tap stops calling back entirely.
/// Silence is intentionally irrelevant: a silent tap still supplies frames.
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
        case stalled(secondsWithoutFrames: TimeInterval)
        case recoveryDue(attempt: Int, secondsWithoutFrames: TimeInterval)
        case recovered(outageSeconds: TimeInterval)
    }

    private struct Incident {
        let startedAt: TimeInterval
        var attempts: Int
        var lastAttemptAt: TimeInterval
    }

    private let configuration: Configuration
    private var lastSystemFrameAt: TimeInterval?
    private var incident: Incident?

    init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    mutating func observe(channel: AudioChannel, at timestamp: TimeInterval) -> [Signal] {
        switch channel {
        case .system:
            lastSystemFrameAt = timestamp
            guard let incident else { return [] }
            self.incident = nil
            return [.recovered(outageSeconds: max(0, timestamp - incident.startedAt))]

        case .microphone:
            guard let lastSystemFrameAt else { return [] }
            let outage = max(0, timestamp - lastSystemFrameAt)
            guard outage >= configuration.stallAfter else { return [] }

            if var incident {
                guard timestamp - incident.lastAttemptAt >= configuration.retryEvery else {
                    return []
                }
                incident.attempts += 1
                incident.lastAttemptAt = timestamp
                self.incident = incident
                return [.recoveryDue(
                    attempt: incident.attempts,
                    secondsWithoutFrames: outage)]
            }

            incident = Incident(startedAt: lastSystemFrameAt, attempts: 1, lastAttemptAt: timestamp)
            return [
                .stalled(secondsWithoutFrames: outage),
                .recoveryDue(attempt: 1, secondsWithoutFrames: outage)
            ]

        case .room:
            return []
        }
    }
}

/// Lock-protected façade that keeps callback liveness off the
/// `RecordingSession` actor's hot path. Audio writers ask this monitor for a
/// pure state transition after each persisted chunk; only the rare non-empty
/// signal list crosses back to the actor to request source recovery.
final class SystemCaptureLivenessMonitor: @unchecked Sendable {
    private let lock = NSLock()
    private let configuration: SystemCaptureLivenessPolicy.Configuration
    private let monotonicNow: @Sendable () -> TimeInterval
    private var policy: SystemCaptureLivenessPolicy

    init(
        configuration: SystemCaptureLivenessPolicy.Configuration = .init(),
        monotonicNow: @escaping @Sendable () -> TimeInterval = {
            ProcessInfo.processInfo.systemUptime
        }
    ) {
        self.configuration = configuration
        self.monotonicNow = monotonicNow
        policy = SystemCaptureLivenessPolicy(configuration: configuration)
    }

    func observe(channel: AudioChannel) -> [SystemCaptureLivenessPolicy.Signal] {
        lock.withLock {
            policy.observe(channel: channel, at: monotonicNow())
        }
    }

    func reset() {
        lock.withLock {
            policy = SystemCaptureLivenessPolicy(configuration: configuration)
        }
    }
}
