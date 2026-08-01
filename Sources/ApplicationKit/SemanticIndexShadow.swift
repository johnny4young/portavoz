import Foundation
import PortavozCore
import StorageKit

/// Closed research adapter families. The value is safe to retain because it
/// cannot contain a query, meeting, model name, citation, or transcript text.
public enum SemanticIndexShadowAdapter: String, CaseIterable, Sendable {
    case sqliteVecExact
    case coreSpotlightSemantic
    case usearchHNSW
    case sqliteVecANNResearch
}

/// Query contract for one concrete research candidate.
///
/// The closed adapter identity belongs to the implementation instead of a
/// parallel call-site label, so comparison evidence cannot accidentally name
/// a different engine family than the searcher that produced it.
public protocol SemanticIndexShadowCandidateSearching: SemanticIndexSearching {
    var adapter: SemanticIndexShadowAdapter { get }
}

public enum SemanticIndexShadowOutcome: String, CaseIterable, Sendable {
    case completed
    case cancelled
    case failed
    case skippedPolicy
    case skippedBusy
    case skippedCapture

    init(error: any Error) {
        self = error is CancellationError ? .cancelled : .failed
    }
}

public enum SemanticIndexShadowSkipReason: String, CaseIterable, Sendable {
    case policy
    case busy
    case capture

    var outcome: SemanticIndexShadowOutcome {
        switch self {
        case .policy: .skippedPolicy
        case .busy: .skippedBusy
        case .capture: .skippedCapture
        }
    }
}

/// One payload-free comparison emitted after a shadow candidate finishes.
///
/// Result identity is reduced to aggregate agreement before this value is
/// created. No query vector, segment ID, meeting ID, title, text, model name,
/// error message, or filesystem location can cross the telemetry boundary.
public struct SemanticIndexShadowEvent: Equatable, Sendable {
    public let candidate: SemanticIndexShadowAdapter
    public let outcome: SemanticIndexShadowOutcome
    public let queryDimension: Int
    public let requestedLimit: Int
    public let controlResultCount: Int
    public let candidateResultCount: Int?
    public let overlapCount: Int?
    public let sameRankCount: Int?
    public let topHitAgreement: Bool?
    public let controlDuration: Duration
    public let candidateDuration: Duration
}

/// Synchronous payload-free receiver. Candidate work may block its receiver,
/// but never the exact control result already returned to the caller.
public struct SemanticIndexShadowTelemetry: Sendable {
    private let receiver: @Sendable (SemanticIndexShadowEvent) -> Void

    public init(
        receiver: @escaping @Sendable (SemanticIndexShadowEvent) -> Void
    ) {
        self.receiver = receiver
    }

    func record(_ event: SemanticIndexShadowEvent) {
        receiver(event)
    }
}

/// Scheduling boundary for shadow work. The shipped executor starts a utility
/// detached task; benchmark composition can inject stricter admission and tests
/// can inject a manual queue. Product composition does not install this path.
public struct SemanticIndexShadowExecutor: Sendable {
    private let submit: @Sendable (
        _ operation: @escaping @Sendable () async -> Void,
        _ skipped: @escaping @Sendable (SemanticIndexShadowSkipReason) -> Void
    ) -> Void

    public init(
        submit: @escaping @Sendable (
            _ operation: @escaping @Sendable () async -> Void,
            _ skipped: @escaping @Sendable (SemanticIndexShadowSkipReason) -> Void
        ) -> Void
    ) {
        self.submit = submit
    }

    public static let utilityDetached = Self { operation, _ in
        _ = Task.detached(priority: .utility) {
            await operation()
        }
    }

    func execute(
        _ operation: @escaping @Sendable () async -> Void,
        skipped: @escaping @Sendable (SemanticIndexShadowSkipReason) -> Void
    ) {
        submit(operation, skipped)
    }
}

/// Benchmark-only Strangler adapter. Exact control remains authoritative and
/// returns without awaiting candidate work. Candidate success, failure, or
/// cancellation can only produce a payload-free comparison event.
public struct ShadowComparingSemanticIndex: SemanticIndexSearching {
    private struct EvidenceKey: Hashable, Sendable {
        let segmentID: UUID
        let transcriptRevision: Int
    }

    private struct CandidateWork: Sendable {
        let candidate: any SemanticIndexShadowCandidateSearching
        let telemetry: SemanticIndexShadowTelemetry
        let query: [Float]
        let profile: SemanticEmbeddingProfile
        let limit: Int
        let controlKeys: [EvidenceKey]
        let controlDuration: Duration

        func run() async {
            let startedAt = ContinuousClock.now
            do {
                let hits = try await candidate.search(
                    query,
                    profile: profile,
                    limit: limit)
                let candidateKeys = hits.map(ShadowComparingSemanticIndex.evidenceKey)
                let overlap = Set(controlKeys).intersection(candidateKeys).count
                let sameRank = zip(controlKeys, candidateKeys).reduce(into: 0) { count, pair in
                    if pair.0 == pair.1 { count += 1 }
                }
                let topHitAgreement: Bool? = if let control = controlKeys.first,
                                                       let candidate = candidateKeys.first {
                    control == candidate
                } else {
                    nil
                }
                telemetry.record(SemanticIndexShadowEvent(
                    candidate: candidate.adapter,
                    outcome: .completed,
                    queryDimension: query.count,
                    requestedLimit: limit,
                    controlResultCount: controlKeys.count,
                    candidateResultCount: candidateKeys.count,
                    overlapCount: overlap,
                    sameRankCount: sameRank,
                    topHitAgreement: topHitAgreement,
                    controlDuration: controlDuration,
                    candidateDuration: startedAt.duration(to: .now)))
            } catch {
                telemetry.record(SemanticIndexShadowEvent(
                    candidate: candidate.adapter,
                    outcome: SemanticIndexShadowOutcome(error: error),
                    queryDimension: query.count,
                    requestedLimit: limit,
                    controlResultCount: controlKeys.count,
                    candidateResultCount: nil,
                    overlapCount: nil,
                    sameRankCount: nil,
                    topHitAgreement: nil,
                    controlDuration: controlDuration,
                    candidateDuration: startedAt.duration(to: .now)))
            }
        }

        func skip(_ reason: SemanticIndexShadowSkipReason) {
            telemetry.record(SemanticIndexShadowEvent(
                candidate: candidate.adapter,
                outcome: reason.outcome,
                queryDimension: query.count,
                requestedLimit: limit,
                controlResultCount: controlKeys.count,
                candidateResultCount: nil,
                overlapCount: nil,
                sameRankCount: nil,
                topHitAgreement: nil,
                controlDuration: controlDuration,
                candidateDuration: .zero))
        }
    }

    private let control: any SemanticIndexSearching
    private let candidate: any SemanticIndexShadowCandidateSearching
    private let telemetry: SemanticIndexShadowTelemetry
    private let executor: SemanticIndexShadowExecutor

    public init(
        control: any SemanticIndexSearching,
        candidate: any SemanticIndexShadowCandidateSearching,
        telemetry: SemanticIndexShadowTelemetry,
        executor: SemanticIndexShadowExecutor
    ) {
        self.control = control
        self.candidate = candidate
        self.telemetry = telemetry
        self.executor = executor
    }

    public func search(
        _ query: [Float],
        profile: SemanticEmbeddingProfile,
        limit: Int
    ) async throws -> [SearchHit] {
        let controlStartedAt = ContinuousClock.now
        let controlHits = try await control.search(
            query,
            profile: profile,
            limit: limit)
        let controlDuration = controlStartedAt.duration(to: .now)
        let controlKeys = controlHits.map(Self.evidenceKey)
        let work = CandidateWork(
            candidate: candidate,
            telemetry: telemetry,
            query: query,
            profile: profile,
            limit: limit,
            controlKeys: controlKeys,
            controlDuration: controlDuration)

        executor.execute {
            await work.run()
        } skipped: { reason in
            work.skip(reason)
        }

        return controlHits
    }

    private static func evidenceKey(_ hit: SearchHit) -> EvidenceKey {
        EvidenceKey(
            segmentID: hit.segmentID,
            transcriptRevision: hit.transcriptRevision)
    }
}
