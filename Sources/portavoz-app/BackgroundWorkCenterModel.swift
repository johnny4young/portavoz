import ApplicationKit
import Foundation
import Observation
import PortavozCore

enum BackgroundWorkOwner: String, CaseIterable, Identifiable, Sendable {
    case recovery
    case processing
    case spotlight
    case semanticIndex = "semantic-index"
    case memoryGraph = "memory-graph"

    var id: String { rawValue }
}

enum BackgroundWorkPhase: Equatable, Sendable {
    case idle
    case running
    case waitingForRecording
    case retryScheduled(Date?)
    case failed
}

enum BackgroundWorkStage: Equatable, Sendable {
    case recoveringRecordings
    case processing(ProcessingJobKind?)
    case spotlightScheduled
    case spotlightProjecting
    case spotlightPublishing
    case semanticIndexing
    case projectingMemoryGraph
}

enum BackgroundWorkOutcome: String, Equatable, Sendable {
    case succeeded
    case failed
    case cancelled
    case suspended
    case leaseLost
}

enum BackgroundWorkFailureCategory: String, Equatable, Sendable {
    case recoveryExpiredLeases
    case recoveryCandidates
    case recoveryPreservation
    case processingClaim
    case processingPreservation
    case scheduling
    case coordination
}

struct BackgroundWorkMetrics: Equatable, Sendable {
    var recoveredLeases = 0
    var reconciledRecordings = 0
    var deferredRecordings = 0
    var preservedRecoveryFailures = 0
    var processedJobs = 0
    var invalidatedSegments = 0
    var embeddedSegments = 0
    var excludedSegments = 0
    var skippedSegments = 0
    var rebuiltGraphScopes = 0
    var publishedGraphEdges = 0
}

struct BackgroundWorkSnapshot: Equatable, Identifiable, Sendable {
    let owner: BackgroundWorkOwner
    var phase: BackgroundWorkPhase
    var stage: BackgroundWorkStage?
    var attempt: Int?
    var lastOutcome: BackgroundWorkOutcome?
    var lastFailure: BackgroundWorkFailureCategory?
    var metrics: BackgroundWorkMetrics
    var updatedAt: Date?

    var id: BackgroundWorkOwner { owner }

    static func idle(_ owner: BackgroundWorkOwner) -> Self {
        Self(
            owner: owner,
            phase: .idle,
            stage: nil,
            attempt: nil,
            lastOutcome: nil,
            lastFailure: nil,
            metrics: .init(),
            updatedAt: nil)
    }
}

struct BackgroundWorkRunToken: Equatable, Sendable {
    let owner: BackgroundWorkOwner
    fileprivate let generation: UInt64
}

/// One process-owned, content-free projection of the five existing background
/// owners. Owners push typed transitions; the model never polls their stores or
/// replaces their scheduling authority.
@MainActor
@Observable
final class BackgroundWorkCenterModel {
    private(set) var snapshots: [BackgroundWorkOwner: BackgroundWorkSnapshot]

    @ObservationIgnored private var generations: [BackgroundWorkOwner: UInt64]
    @ObservationIgnored private var installsUITestFixture = false

    init() {
        let initial = BackgroundWorkOwner.allCases.map {
            ($0, BackgroundWorkSnapshot.idle($0))
        }
        snapshots = Dictionary(uniqueKeysWithValues: initial)
        generations = Dictionary(
            uniqueKeysWithValues: BackgroundWorkOwner.allCases.map { ($0, 0) })
    }

    var items: [BackgroundWorkSnapshot] {
        BackgroundWorkOwner.allCases.compactMap { snapshots[$0] }
    }

    var hasVisibleActivity: Bool {
        items.contains { snapshot in
            switch snapshot.phase {
            case .idle: false
            case .running, .waitingForRecording, .retryScheduled, .failed: true
            }
        }
    }

    var needsAttention: Bool {
        items.contains { snapshot in
            if case .failed = snapshot.phase { return true }
            return snapshot.lastFailure != nil
        }
    }

    @discardableResult
    func begin(
        _ owner: BackgroundWorkOwner,
        stage: BackgroundWorkStage,
        attempt: Int? = nil,
        at timestamp: Date = Date()
    ) -> BackgroundWorkRunToken {
        let generation = (generations[owner] ?? 0) &+ 1
        generations[owner] = generation
        let token = BackgroundWorkRunToken(owner: owner, generation: generation)
        guard !installsUITestFixture else { return token }
        mutate(owner) {
            $0.phase = .running
            $0.stage = stage
            $0.attempt = attempt
            $0.lastFailure = nil
            $0.updatedAt = timestamp
        }
        return token
    }

    func markWaitingForRecording(
        _ owner: BackgroundWorkOwner,
        at timestamp: Date = Date()
    ) {
        guard !installsUITestFixture else { return }
        let stage: BackgroundWorkStage = owner == .semanticIndex
            ? .semanticIndexing : .projectingMemoryGraph
        mutate(owner) {
            $0.phase = .waitingForRecording
            $0.stage = stage
            $0.updatedAt = timestamp
        }
    }

    func finishRecovery(
        _ token: BackgroundWorkRunToken,
        result: RecoverInterruptedMeetingsResult,
        at timestamp: Date = Date()
    ) {
        guard accepts(token) else { return }
        let failure = result.issues.first.map(Self.recoveryFailureCategory)
        mutate(.recovery) {
            $0.phase = failure == nil ? .idle : .failed
            $0.stage = nil
            $0.lastOutcome = failure == nil ? .succeeded : .failed
            $0.lastFailure = failure
            $0.metrics.recoveredLeases = result.recoveredLeaseCount
            $0.metrics.reconciledRecordings = result.reconciledMeetingCount
            $0.metrics.deferredRecordings = result.deferredMeetingCount
            $0.metrics.preservedRecoveryFailures = result.preservedFailureCount
            $0.updatedAt = timestamp
        }
    }

    func finishProcessingJob(
        _ token: BackgroundWorkRunToken,
        kind: ProcessingJobKind,
        attempt: Int,
        outcome: PostCaptureProcessingOutcome,
        at timestamp: Date = Date()
    ) {
        guard accepts(token) else { return }
        mutate(.processing) {
            $0.stage = .processing(kind)
            $0.attempt = attempt
            $0.lastOutcome = Self.processingOutcome(outcome)
            $0.updatedAt = timestamp
        }
    }

    func finishProcessingDrain(
        _ token: BackgroundWorkRunToken?,
        result: ProcessPostCaptureJobsResult,
        retryAt: Date?,
        schedulingFailed: Bool = false,
        at timestamp: Date = Date()
    ) {
        let effectiveToken = token ?? begin(
            .processing,
            stage: .processing(nil),
            at: timestamp)
        guard accepts(effectiveToken) else { return }
        let issue = result.issues.first.map(Self.processingFailureCategory)
        let failure = schedulingFailed ? .scheduling : issue
        mutate(.processing) {
            $0.phase = failure != nil
                ? .failed
                : retryAt.map { .retryScheduled($0) } ?? .idle
            $0.stage = nil
            $0.lastFailure = failure
            if result.processedJobCount > 0 {
                $0.metrics.processedJobs += result.processedJobCount
            }
            if failure != nil { $0.lastOutcome = .failed }
            $0.updatedAt = timestamp
        }
    }

    func receiveSpotlight(
        _ status: SpotlightIndexer.Status,
        retryAt: Date? = nil,
        at timestamp: Date = Date()
    ) {
        guard !installsUITestFixture else { return }
        mutate(.spotlight) { snapshot in
            switch status {
            case .idle:
                snapshot.lastOutcome = snapshot.stage == .spotlightPublishing
                    ? .succeeded : snapshot.lastOutcome
                snapshot.phase = .idle
                snapshot.stage = nil
                snapshot.attempt = nil
                snapshot.lastFailure = nil
            case .scheduled:
                snapshot.phase = .running
                snapshot.stage = .spotlightScheduled
                snapshot.lastFailure = nil
            case .projecting:
                snapshot.phase = .running
                snapshot.stage = .spotlightProjecting
            case .publishing:
                snapshot.phase = .running
                snapshot.stage = .spotlightPublishing
            case .retrying(let attempt):
                snapshot.phase = .retryScheduled(retryAt)
                snapshot.attempt = attempt
                snapshot.lastOutcome = .failed
                snapshot.lastFailure = .coordination
            case .failed(let attempts):
                snapshot.phase = .failed
                snapshot.stage = nil
                snapshot.attempt = attempts
                snapshot.lastOutcome = .failed
                snapshot.lastFailure = .coordination
            }
            snapshot.updatedAt = timestamp
        }
    }

    func observeSemantic(
        _ token: BackgroundWorkRunToken?,
        run: SemanticCorpusMaintenanceRun
    ) {
        guard let token, accepts(token) else { return }
        mutate(.semanticIndex) {
            $0.metrics.invalidatedSegments += run.indexing.invalidatedSegments
            $0.metrics.embeddedSegments += run.indexing.embeddedSegments
            $0.metrics.excludedSegments += run.indexing.excludedSegments
            $0.metrics.skippedSegments += run.indexing.skippedSegments
        }
    }

    func finishSemantic(
        _ token: BackgroundWorkRunToken?,
        run: SemanticCorpusMaintenanceRun,
        at timestamp: Date = Date()
    ) {
        guard let token, accepts(token) else { return }
        settleMaintenance(
            token,
            paused: run.indexing.pausedByPolicy,
            retryAt: run.retryAt,
            terminalFailure: run.terminalFailure,
            timestamp: timestamp)
    }

    func observeMemoryGraph(
        _ token: BackgroundWorkRunToken?,
        run: MeetingMemoryGraphMaintenanceRun
    ) {
        guard let token, accepts(token) else { return }
        mutate(.memoryGraph) {
            $0.metrics.rebuiltGraphScopes += run.projection.rebuiltScopes
            $0.metrics.publishedGraphEdges += run.projection.publishedEdges
        }
    }

    func finishMemoryGraph(
        _ token: BackgroundWorkRunToken?,
        run: MeetingMemoryGraphMaintenanceRun,
        at timestamp: Date = Date()
    ) {
        guard let token, accepts(token) else { return }
        settleMaintenance(
            token,
            paused: run.projection.pausedByPolicy,
            retryAt: run.retryAt,
            terminalFailure: run.terminalFailure,
            timestamp: timestamp)
    }

    /// Presentation-only deterministic fixture. Both flags are required, so a
    /// production launch cannot replace real owner evidence with sample state.
    func installUITestFixtureIfRequested(
        arguments: [String],
        at timestamp: Date = Date()
    ) {
        guard arguments.contains("-use-temp-store"),
              arguments.contains("-seed-background-work")
        else { return }
        installsUITestFixture = true
        snapshots[.recovery] = BackgroundWorkSnapshot(
            owner: .recovery,
            phase: .idle,
            stage: nil,
            attempt: nil,
            lastOutcome: .succeeded,
            lastFailure: nil,
            metrics: BackgroundWorkMetrics(
                recoveredLeases: 1,
                reconciledRecordings: 2),
            updatedAt: timestamp)
        snapshots[.processing] = BackgroundWorkSnapshot(
            owner: .processing,
            phase: .retryScheduled(timestamp.addingTimeInterval(300)),
            stage: .processing(.summary),
            attempt: 2,
            lastOutcome: .failed,
            lastFailure: .processingPreservation,
            metrics: BackgroundWorkMetrics(processedJobs: 1),
            updatedAt: timestamp)
        snapshots[.spotlight] = BackgroundWorkSnapshot(
            owner: .spotlight,
            phase: .idle,
            stage: nil,
            attempt: nil,
            lastOutcome: .succeeded,
            lastFailure: nil,
            metrics: .init(),
            updatedAt: timestamp)
        snapshots[.semanticIndex] = BackgroundWorkSnapshot(
            owner: .semanticIndex,
            phase: .idle,
            stage: nil,
            attempt: nil,
            lastOutcome: .succeeded,
            lastFailure: nil,
            metrics: BackgroundWorkMetrics(
                invalidatedSegments: 2,
                embeddedSegments: 12,
                excludedSegments: 3),
            updatedAt: timestamp)
        snapshots[.memoryGraph] = BackgroundWorkSnapshot(
            owner: .memoryGraph,
            phase: .failed,
            stage: nil,
            attempt: 3,
            lastOutcome: .failed,
            lastFailure: .coordination,
            metrics: BackgroundWorkMetrics(
                rebuiltGraphScopes: 4,
                publishedGraphEdges: 9),
            updatedAt: timestamp)
    }

    /// Keeps the real-app fixture interactive without introducing a second
    /// scheduler. Production always returns false and routes to the real owner.
    func resolveUITestActionIfNeeded(
        for owner: BackgroundWorkOwner,
        at timestamp: Date = Date()
    ) -> Bool {
        guard installsUITestFixture else { return false }
        mutate(owner) {
            $0.phase = .idle
            $0.stage = nil
            $0.attempt = nil
            $0.lastOutcome = .succeeded
            $0.lastFailure = nil
            $0.updatedAt = timestamp
        }
        return true
    }

    private func settleMaintenance(
        _ token: BackgroundWorkRunToken,
        paused: Bool,
        retryAt: Date?,
        terminalFailure: Bool,
        timestamp: Date
    ) {
        guard accepts(token) else { return }
        mutate(token.owner) {
            if paused {
                $0.phase = .waitingForRecording
                $0.lastOutcome = .suspended
                $0.lastFailure = nil
            } else if terminalFailure {
                $0.phase = .failed
                $0.lastOutcome = .failed
                $0.lastFailure = .coordination
            } else if let retryAt {
                $0.phase = .retryScheduled(retryAt)
                $0.lastOutcome = .failed
                $0.lastFailure = .coordination
            } else {
                $0.phase = .idle
                $0.lastOutcome = .succeeded
                $0.lastFailure = nil
            }
            $0.stage = nil
            $0.updatedAt = timestamp
        }
    }

    private func mutate(
        _ owner: BackgroundWorkOwner,
        _ update: (inout BackgroundWorkSnapshot) -> Void
    ) {
        var snapshot = snapshots[owner] ?? .idle(owner)
        update(&snapshot)
        snapshots[owner] = snapshot
    }

    private func accepts(_ token: BackgroundWorkRunToken) -> Bool {
        !installsUITestFixture && generations[token.owner] == token.generation
    }

    private static func recoveryFailureCategory(
        _ issue: RecoverInterruptedMeetingsIssue
    ) -> BackgroundWorkFailureCategory {
        switch issue.stage {
        case .expiredLeaseRecovery: .recoveryExpiredLeases
        case .candidateLoading: .recoveryCandidates
        case .failurePreservation: .recoveryPreservation
        }
    }

    private static func processingFailureCategory(
        _ issue: PostCaptureProcessingIssue
    ) -> BackgroundWorkFailureCategory {
        switch issue.stage {
        case .claim: .processingClaim
        case .failurePreservation: .processingPreservation
        }
    }

    private static func processingOutcome(
        _ outcome: PostCaptureProcessingOutcome
    ) -> BackgroundWorkOutcome {
        switch outcome {
        case .succeeded: .succeeded
        case .failed: .failed
        case .cancelled: .cancelled
        case .suspended: .suspended
        case .leaseLost: .leaseLost
        }
    }
}
