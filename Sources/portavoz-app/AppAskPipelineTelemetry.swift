import ApplicationKit
import Foundation
import OSLog
import PortavozCore

/// Platform recorder for Ask pipeline timing. Only closed operation, stage,
/// milestone, and outcome enums enter Points of Interest; questions, meetings,
/// citations, model names, and errors are outside this API.
final class AppAskPipelineTelemetry: @unchecked Sendable {
    typealias Observer = @Sendable (AskPipelineEvent) -> Void

    static let shared = AppAskPipelineTelemetry()

    private static let signposter = OSSignposter(
        subsystem: "app.portavoz.mac",
        category: .pointsOfInterest)

    private let lock = NSLock()
    private var traces: [UUID: OSSignpostIntervalState] = [:]
    private var stages: [UUID: OSSignpostIntervalState] = [:]
    private var observers: [UUID: Observer] = [:]

    var telemetry: AskPipelineTelemetry {
        AskPipelineTelemetry { [weak self] event in
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

    private func receive(_ event: AskPipelineEvent) {
        let installedObservers: [Observer]
        switch event {
        case .started(let trace):
            let interval = Self.signposter.beginInterval(
                "Ask pipeline",
                "operation=\(trace.operation.rawValue, privacy: .public)")
            lock.lock()
            traces[trace.id] = interval
            installedObservers = Array(observers.values)
            lock.unlock()

        case .stageStarted(let span):
            let interval = Self.signposter.beginInterval(
                "Ask stage",
                "operation=\(span.trace.operation.rawValue, privacy: .public) stage=\(span.stage.rawValue, privacy: .public)")
            lock.lock()
            stages[span.id] = interval
            installedObservers = Array(observers.values)
            lock.unlock()

        case .stageFinished(let span, let outcome):
            lock.lock()
            let interval = stages.removeValue(forKey: span.id)
            installedObservers = Array(observers.values)
            lock.unlock()
            if let interval {
                Self.signposter.endInterval(
                    "Ask stage",
                    interval,
                    "outcome=\(outcome.rawValue, privacy: .public)")
            }

        case .reached(let trace, let milestone):
            Self.signposter.emitEvent(
                "Ask milestone",
                "operation=\(trace.operation.rawValue, privacy: .public) milestone=\(milestone.rawValue, privacy: .public)")
            lock.lock()
            installedObservers = Array(observers.values)
            lock.unlock()

        case .finished(let trace, let outcome):
            lock.lock()
            let interval = traces.removeValue(forKey: trace.id)
            installedObservers = Array(observers.values)
            lock.unlock()
            if let interval {
                Self.signposter.endInterval(
                    "Ask pipeline",
                    interval,
                    "outcome=\(outcome.rawValue, privacy: .public)")
            }
        }
        for observer in installedObservers {
            observer(event)
        }
    }
}
