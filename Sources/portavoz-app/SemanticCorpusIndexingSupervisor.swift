import ApplicationKit
import Foundation
import OSLog
import PortavozCore
import StorageKit

private protocol SignalDrivenMaintenanceRun: Sendable {
    static var empty: Self { get }
    static var coordinationFailure: Self { get }
    var shouldRerun: Bool { get }
    var retryAt: Date? { get }
    var terminalFailure: Bool { get }
}

extension SemanticCorpusMaintenanceRun: SignalDrivenMaintenanceRun {}
extension MeetingMemoryGraphMaintenanceRun: SignalDrivenMaintenanceRun {}

private extension SemanticCorpusMaintenanceRun {
    static var coordinationFailure: Self {
        SemanticCorpusMaintenanceRun(terminalFailure: true)
    }
}

private extension MeetingMemoryGraphMaintenanceRun {
    static var coordinationFailure: Self {
        MeetingMemoryGraphMaintenanceRun(terminalFailure: true)
    }
}

/// Reusable process owner for signal-driven durable maintenance. Bursts
/// collapse to one rerun, one drain runs at a time, and retry wakes are exact;
/// no derived subsystem polls SQLite.
@MainActor
private final class SignalDrivenMaintenanceSupervisor<Run: SignalDrivenMaintenanceRun> {
    typealias Drain = @Sendable (_ owner: String) async throws -> Run

    private static var logger: Logger {
        Logger(subsystem: "app.portavoz.mac", category: "derived-maintenance")
    }

    private let isEnabled: Bool
    private let drain: Drain
    private let owner: String
    private let didStart: () -> BackgroundWorkRunToken?
    private let didObserve: (BackgroundWorkRunToken?, Run) -> Void
    private let didFinish: (Run) -> Void
    private let didSettle: (BackgroundWorkRunToken?, Run) -> Void
    private var drainTask: Task<Void, Never>?
    private var wakeTask: Task<Void, Never>?
    private var rerunRequested = false
    private var runToken: BackgroundWorkRunToken?

    init(
        kind: DerivedMaintenanceKind,
        isEnabled: Bool,
        drain: @escaping Drain,
        didStart: @escaping () -> BackgroundWorkRunToken? = { nil },
        didObserve: @escaping (BackgroundWorkRunToken?, Run) -> Void = { _, _ in },
        didFinish: @escaping (Run) -> Void = { _ in },
        didSettle: @escaping (BackgroundWorkRunToken?, Run) -> Void = { _, _ in }
    ) {
        self.isEnabled = isEnabled
        self.drain = drain
        owner = "\(kind.rawValue)-maintenance-\(UUID().uuidString.lowercased())"
        self.didStart = didStart
        self.didObserve = didObserve
        self.didFinish = didFinish
        self.didSettle = didSettle
    }

    func kick() {
        guard isEnabled else { return }
        wakeTask?.cancel()
        wakeTask = nil
        guard drainTask == nil else {
            rerunRequested = true
            return
        }

        rerunRequested = false
        runToken = didStart()
        let drain = drain
        let owner = owner
        drainTask = Task { @MainActor [weak self] in
            let run: Run
            do {
                run = try await drain(owner)
            } catch is CancellationError {
                run = .empty
            } catch {
                run = .coordinationFailure
                Self.logger.error(
                    "Derived maintenance coordination failed; durable work remains replayable")
            }
            self?.finishedDrain(run)
        }
    }

    private func finishedDrain(_ run: Run) {
        drainTask = nil
        didObserve(runToken, run)
        if rerunRequested || run.shouldRerun {
            rerunRequested = false
            kick()
            return
        }
        didFinish(run)
        didSettle(runToken, run)
        runToken = nil
        if let retryAt = run.retryAt {
            scheduleWake(at: retryAt)
        }
    }

    private func scheduleWake(at date: Date) {
        let delay = max(0, date.timeIntervalSinceNow)
        wakeTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            self.wakeTask = nil
            self.kick()
        }
    }
}

/// Process-owned, signal-driven semantic maintenance.
@MainActor
final class SemanticCorpusIndexingSupervisor {
    typealias Drain = @Sendable (_ owner: String) async throws
        -> SemanticCorpusMaintenanceRun
    typealias BackgroundEvent = (
        BackgroundWorkRunToken?, SemanticCorpusMaintenanceRun
    ) -> Void

    private let supervisor:
        SignalDrivenMaintenanceSupervisor<SemanticCorpusMaintenanceRun>

    init(
        isEnabled: Bool = true,
        maintenanceState: SemanticCorpusMaintenanceState = .init(),
        didStart: @escaping () -> BackgroundWorkRunToken? = { nil },
        didObserve: @escaping BackgroundEvent = { _, _ in },
        didSettle: @escaping BackgroundEvent = { _, _ in },
        drain: @escaping Drain
    ) {
        supervisor = SignalDrivenMaintenanceSupervisor(
            kind: .semanticCorpus,
            isEnabled: isEnabled,
            drain: drain,
            didStart: {
                maintenanceState.transition(to: .building)
                return didStart()
            },
            didObserve: didObserve,
            didFinish: { run in
                maintenanceState.transition(to: run.terminalFailure ? .failed : .idle)
            },
            didSettle: didSettle)
    }

    func kick() {
        supervisor.kick()
    }
}

@MainActor
final class MeetingMemoryGraphProjectionSupervisor {
    typealias Drain = @Sendable (_ owner: String) async throws
        -> MeetingMemoryGraphMaintenanceRun
    typealias BackgroundEvent = (
        BackgroundWorkRunToken?, MeetingMemoryGraphMaintenanceRun
    ) -> Void

    private let supervisor:
        SignalDrivenMaintenanceSupervisor<MeetingMemoryGraphMaintenanceRun>

    init(
        isEnabled: Bool = true,
        didStart: @escaping () -> BackgroundWorkRunToken? = { nil },
        didObserve: @escaping BackgroundEvent = { _, _ in },
        didSettle: @escaping BackgroundEvent = { _, _ in },
        drain: @escaping Drain
    ) {
        supervisor = SignalDrivenMaintenanceSupervisor(
            kind: .meetingMemoryGraph,
            isEnabled: isEnabled,
            drain: drain,
            didStart: didStart,
            didObserve: didObserve,
            didSettle: didSettle)
    }

    func kick() {
        supervisor.kick()
    }
}

/// Production adapter for the background semantic owner. It checks cheap
/// durable state before borrowing the runtime and never downloads OS assets.
struct AppSemanticCorpusBackgroundIndexer: Sendable {
    let store: MeetingStore
    let runtime: any SemanticEmbeddingRuntimeClient
    let coordinator: SemanticCorpusIndexingCoordinator
    let captureState: AppResourceCaptureState

    func drain(
        owner: String = "semantic-maintenance-test-owner"
    ) async throws -> SemanticCorpusMaintenanceRun {
        try await ProcessSemanticCorpusMaintenance(
            store: store,
            runtime: runtime,
            coordinator: coordinator,
            mayStart: { captureState.current == .inactive }
        ).execute(owner: owner)
    }
}

struct AppMeetingMemoryGraphBackgroundProjector: Sendable {
    let store: MeetingStore
    let projector: ProjectMeetingMemoryGraph
    let captureState: AppResourceCaptureState

    func drain(
        owner: String = "memory-graph-maintenance-test-owner"
    ) async throws -> MeetingMemoryGraphMaintenanceRun {
        try await ProcessMeetingMemoryGraphMaintenance(
            store: store,
            projector: projector,
            mayStart: { captureState.current == .inactive }
        ).execute(owner: owner)
    }
}
