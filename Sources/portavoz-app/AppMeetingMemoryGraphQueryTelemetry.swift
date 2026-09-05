import ApplicationKit
import Foundation
import OSLog

/// Platform timing adapter for exact graph reads. Unified logging receives
/// only the closed job and terminal outcome; query identities, user content,
/// counts, abstention reasons, and errors never cross this boundary.
final class AppMeetingMemoryGraphQueryTelemetry: @unchecked Sendable {
    typealias Observer = @Sendable (MeetingMemoryGraphQueryEvent) -> Void

    static let shared = AppMeetingMemoryGraphQueryTelemetry()

    private static let signposter = OSSignposter(
        subsystem: "app.portavoz.mac",
        category: .pointsOfInterest)

    private let lock = NSLock()
    private var intervals: [UUID: OSSignpostIntervalState] = [:]
    private var observers: [UUID: Observer] = [:]

    var telemetry: MeetingMemoryGraphQueryTelemetry {
        MeetingMemoryGraphQueryTelemetry { [weak self] event in
            self?.receive(event)
        }
    }

    func addObserver(_ observer: @escaping Observer) -> UUID {
        let identifier = UUID()
        lock.lock()
        observers[identifier] = observer
        lock.unlock()
        return identifier
    }

    func removeObserver(_ identifier: UUID) {
        lock.lock()
        observers.removeValue(forKey: identifier)
        lock.unlock()
    }

    private func receive(_ event: MeetingMemoryGraphQueryEvent) {
        let installedObservers: [Observer]
        switch event {
        case .started(let trace):
            let interval = Self.signposter.beginInterval(
                "Memory graph query",
                "job=\(trace.job.rawValue, privacy: .public)")
            lock.lock()
            intervals[trace.id] = interval
            installedObservers = Array(observers.values)
            lock.unlock()

        case .finished(let trace, let outcome):
            lock.lock()
            let interval = intervals.removeValue(forKey: trace.id)
            installedObservers = Array(observers.values)
            lock.unlock()
            if let interval {
                Self.signposter.endInterval(
                    "Memory graph query",
                    interval,
                    "outcome=\(outcome.rawValue, privacy: .public)")
            }
        }
        for observer in installedObservers {
            observer(event)
        }
    }
}
