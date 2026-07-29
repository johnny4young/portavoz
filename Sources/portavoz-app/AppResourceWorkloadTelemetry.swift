import Foundation
import OSLog
import PortavozCore

/// The only platform recorder for the resource-workload port. It translates
/// allowlisted Core enums into Points of Interest intervals and deliberately
/// has no API for content, identifiers, paths, model names, or errors.
final class AppResourceWorkloadTelemetry: @unchecked Sendable {
    static let shared = AppResourceWorkloadTelemetry()

    private static let signposter = OSSignposter(
        subsystem: "app.portavoz.mac",
        category: .pointsOfInterest)

    private let lock = NSLock()
    private var intervals: [UUID: OSSignpostIntervalState] = [:]

    var telemetry: ResourceWorkloadTelemetry {
        ResourceWorkloadTelemetry { [weak self] event in
            self?.receive(event)
        }
    }

    private func receive(_ event: ResourceWorkloadEvent) {
        switch event {
        case .started(let span):
            let interval = Self.signposter.beginInterval(
                "Resource workload",
                "class=\(span.descriptor.workloadClass.rawValue, privacy: .public) kind=\(span.descriptor.kind.rawValue, privacy: .public) operation=\(span.descriptor.operation.rawValue, privacy: .public)")
            lock.lock()
            intervals[span.id] = interval
            lock.unlock()

        case .finished(let span, let outcome):
            lock.lock()
            let interval = intervals.removeValue(forKey: span.id)
            lock.unlock()
            guard let interval else { return }
            Self.signposter.endInterval(
                "Resource workload",
                interval,
                "outcome=\(outcome.rawValue, privacy: .public)")
        }
    }
}
