import Foundation
import OSLog
import PortavozCore

/// The only platform recorder for the resource-workload port. It translates
/// allowlisted Core enums into Points of Interest intervals and deliberately
/// has no API for content, identifiers, paths, model names, or errors.
final class AppResourceWorkloadTelemetry: @unchecked Sendable {
    typealias Observer = @Sendable (ResourceWorkloadEvent) -> Void

    static let shared = AppResourceWorkloadTelemetry()

    private static let signposter = OSSignposter(
        subsystem: "app.portavoz.mac",
        category: .pointsOfInterest)

    private let lock = NSLock()
    private var intervals: [UUID: OSSignpostIntervalState] = [:]
    private var activeSpans: [UUID: ResourceWorkloadSpan] = [:]
    private var observers: [UUID: Observer] = [:]

    var telemetry: ResourceWorkloadTelemetry {
        ResourceWorkloadTelemetry { [weak self] event in
            self?.receive(event)
        }
    }

    /// Hidden benchmark probes can observe the same closed event stream
    /// without parsing Instruments XML. Normal app composition installs no
    /// observers, and the returned token makes teardown explicit.
    func addObserver(
        replayingActive: Bool = false,
        _ observer: @escaping Observer
    ) -> UUID {
        let identifier = UUID()
        lock.lock()
        observers[identifier] = observer
        if replayingActive {
            // Replay while holding the adapter lock so a concurrent finish
            // cannot overtake its start at the newly installed observer.
            for span in activeSpans.values {
                observer(.started(span))
            }
        }
        lock.unlock()
        return identifier
    }

    func removeObserver(_ identifier: UUID) {
        lock.lock()
        observers.removeValue(forKey: identifier)
        lock.unlock()
    }

    private func receive(_ event: ResourceWorkloadEvent) {
        let installedObservers: [Observer]
        switch event {
        case .started(let span):
            let interval = Self.signposter.beginInterval(
                "Resource workload",
                "class=\(span.descriptor.workloadClass.rawValue, privacy: .public) kind=\(span.descriptor.kind.rawValue, privacy: .public) operation=\(span.descriptor.operation.rawValue, privacy: .public)")
            lock.lock()
            intervals[span.id] = interval
            activeSpans[span.id] = span
            installedObservers = Array(observers.values)
            lock.unlock()

        case .finished(let span, let outcome):
            lock.lock()
            let interval = intervals.removeValue(forKey: span.id)
            activeSpans.removeValue(forKey: span.id)
            installedObservers = Array(observers.values)
            lock.unlock()
            if let interval {
                Self.signposter.endInterval(
                    "Resource workload",
                    interval,
                    "outcome=\(outcome.rawValue, privacy: .public)")
            }
        }
        for observer in installedObservers {
            observer(event)
        }
    }
}
