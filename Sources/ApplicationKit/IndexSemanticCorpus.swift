import Foundation
import IntelligenceKit
import PortavozCore
import StorageKit

public protocol SemanticTextEmbedding: Sendable {
    func vectors(for texts: [String]) async throws -> [[Float]]
}

public protocol SemanticEmbeddingModel: SemanticTextEmbedding {
    var hasAvailableAssets: Bool { get async }

    func prepare(allowAssetDownload: Bool) async throws
}

/// Process composition injects this boundary into every production semantic
/// borrower. The client keeps one active-use lease around the complete
/// indexing-and-query operation instead of exposing a shared mutable model.
public protocol SemanticEmbeddingRuntimeClient: Sendable {
    var hasAvailableAssets: Bool { get async }

    func prepare(allowAssetDownload: Bool) async throws

    func withPreparedEmbedding<Result: Sendable>(
        allowAssetDownload: Bool,
        operation: @Sendable (
            _ embedder: any SemanticTextEmbedding
        ) async throws -> Result
    ) async throws -> Result
}

extension SentenceEmbedder: SemanticEmbeddingModel {
    public func vectors(for texts: [String]) async throws -> [[Float]] {
        try embed(texts)
    }
}

public struct SemanticCorpusIndexingResult: Equatable, Sendable {
    public let embeddedSegments: Int
    public let excludedSegments: Int
    /// Expected governor suspension, distinct from cancellation or failure.
    /// Missing database rows remain the durable cursor for a later pass.
    public let pausedByPolicy: Bool

    public init(
        embeddedSegments: Int,
        excludedSegments: Int,
        pausedByPolicy: Bool = false
    ) {
        self.embeddedSegments = embeddedSegments
        self.excludedSegments = excludedSegments
        self.pausedByPolicy = pausedByPolicy
    }

    public static let empty = SemanticCorpusIndexingResult(
        embeddedSegments: 0,
        excludedSegments: 0)

    public static let paused = SemanticCorpusIndexingResult(
        embeddedSegments: 0,
        excludedSegments: 0,
        pausedByPolicy: true)

    public static func + (
        left: SemanticCorpusIndexingResult,
        right: SemanticCorpusIndexingResult
    ) -> SemanticCorpusIndexingResult {
        SemanticCorpusIndexingResult(
            embeddedSegments: left.embeddedSegments + right.embeddedSegments,
            excludedSegments: left.excludedSegments + right.excludedSegments,
            pausedByPolicy: left.pausedByPolicy || right.pausedByPolicy)
    }

    public static func += (
        left: inout SemanticCorpusIndexingResult,
        right: SemanticCorpusIndexingResult
    ) {
        left = left + right
    }

    func markingPolicyPause() -> SemanticCorpusIndexingResult {
        SemanticCorpusIndexingResult(
            embeddedSegments: embeddedSegments,
            excludedSegments: excludedSegments,
            pausedByPolicy: true)
    }
}

public enum SemanticCorpusIndexingError: Error, Equatable, LocalizedError {
    case invalidBatchSize
    case vectorCountMismatch(expected: Int, actual: Int)

    public var errorDescription: String? {
        switch self {
        case .invalidBatchSize:
            "semantic indexing batch size must be positive"
        case .vectorCountMismatch(let expected, let actual):
            "semantic embedder returned \(actual) vectors for \(expected) segments"
        }
    }
}

/// One application-owned semantic corpus maintenance operation.
///
/// Ask currently drains all missing rows and Library search advances one
/// bounded batch. Process composition coordinates those calls through one
/// shared flight owner. Keeping both paths on this operation preserves released
/// behavior while giving background indexing one tested extraction seam.
public struct IndexSemanticCorpus: Sendable {
    private static let minimumTextLength = 20
    private static let workload = ResourceWorkloadDescriptor(
        workloadClass: .maintenance,
        kind: .searchIndex,
        operation: .execute)

    private let store: MeetingStore
    private let telemetry: ResourceWorkloadTelemetry
    private let maintenanceGate: DurableMaintenanceGate

    public init(
        store: MeetingStore,
        telemetry: ResourceWorkloadTelemetry = .disabled,
        maintenanceGate: DurableMaintenanceGate = .unrestricted
    ) {
        self.store = store
        self.telemetry = telemetry
        self.maintenanceGate = maintenanceGate
    }

    public func nextBatch(
        using embedder: any SemanticTextEmbedding,
        limit: Int = 512
    ) async throws -> SemanticCorpusIndexingResult {
        guard limit > 0 else {
            throw SemanticCorpusIndexingError.invalidBatchSize
        }
        try Task.checkCancellation()
        guard shouldProceed(at: .admission) else { return .paused }
        let missing = try await store.segmentsNeedingEmbeddings(limit: limit)
        guard !missing.isEmpty else { return .empty }
        return try await measure {
            try await index(missing, using: embedder)
        }
    }

    public func all(
        using embedder: any SemanticTextEmbedding,
        batchSize: Int = 256
    ) async throws -> SemanticCorpusIndexingResult {
        guard batchSize > 0 else {
            throw SemanticCorpusIndexingError.invalidBatchSize
        }
        try Task.checkCancellation()
        guard shouldProceed(at: .admission) else { return .paused }
        let initial = try await store.segmentsNeedingEmbeddings(limit: batchSize)
        guard !initial.isEmpty else { return .empty }
        return try await measure {
            var result = try await index(initial, using: embedder)
            var batch = initial
            while batch.count == batchSize {
                try Task.checkCancellation()
                guard shouldProceed(at: .checkpoint) else {
                    return result.markingPolicyPause()
                }
                batch = try await store.segmentsNeedingEmbeddings(limit: batchSize)
                guard !batch.isEmpty else { break }
                result += try await index(batch, using: embedder)
            }
            return result
        }
    }

    private func measure(
        operation: @Sendable () async throws -> SemanticCorpusIndexingResult
    ) async throws -> SemanticCorpusIndexingResult {
        try await telemetry.measure(Self.workload) {
            try await operation()
        }
    }

    private func shouldProceed(
        at phase: ResourceGovernorEvaluationPhase
    ) -> Bool {
        maintenanceGate.disposition(
            for: Self.workload,
            phase: phase) == .proceed
    }

    private func index(
        _ missing: [(id: UUID, text: String)],
        using embedder: any SemanticTextEmbedding
    ) async throws -> SemanticCorpusIndexingResult {
        try Task.checkCancellation()
        let worthIndexing = missing.filter {
            $0.text.count >= Self.minimumTextLength
        }
        let vectors = try await embedder.vectors(
            for: worthIndexing.map(\.text))
        guard vectors.count == worthIndexing.count else {
            throw SemanticCorpusIndexingError.vectorCountMismatch(
                expected: worthIndexing.count,
                actual: vectors.count)
        }
        try Task.checkCancellation()
        var update = Dictionary(
            uniqueKeysWithValues: zip(worthIndexing.map(\.id), vectors))
        let excluded = missing.filter {
            $0.text.count < Self.minimumTextLength
        }
        for segment in excluded {
            update[segment.id] = []
        }
        try await store.storeEmbeddings(update)
        return SemanticCorpusIndexingResult(
            embeddedSegments: worthIndexing.count,
            excludedSegments: excluded.count)
    }
}
