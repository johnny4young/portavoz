import Foundation
import PortavozCore

/// Closed, content-free Ask entry points. The operation identifies product
/// behavior without admitting a question, meeting, citation, or model name.
public enum AskPipelineOperation: String, CaseIterable, Sendable {
    case search
    case evidence
    case answer
}

/// Stable stages inside local Ask retrieval. Keeping this vocabulary in
/// ApplicationKit lets benchmarks compare implementations without coupling
/// the workflow to OSLog or a concrete vector engine.
public enum AskPipelineStage: String, CaseIterable, Sendable {
    case corpusReadiness
    case expansion
    case lexicalQuery
    case queryEmbedding
    case semanticScan
    case fusion
    case citationFetch
}

/// User-observable progress boundaries that are not intervals themselves.
public enum AskPipelineMilestone: String, CaseIterable, Sendable {
    case firstEvidence
    case firstToken
}

public struct AskPipelineTraceIdentity: Equatable, Sendable {
    public let id: UUID
    public let operation: AskPipelineOperation

    public init(
        id: UUID = UUID(),
        operation: AskPipelineOperation
    ) {
        self.id = id
        self.operation = operation
    }
}

public struct AskPipelineStageSpan: Equatable, Sendable {
    public let id: UUID
    public let trace: AskPipelineTraceIdentity
    public let stage: AskPipelineStage

    public init(
        id: UUID = UUID(),
        trace: AskPipelineTraceIdentity,
        stage: AskPipelineStage
    ) {
        self.id = id
        self.trace = trace
        self.stage = stage
    }
}

public enum AskPipelineEvent: Equatable, Sendable {
    case started(AskPipelineTraceIdentity)
    case stageStarted(AskPipelineStageSpan)
    case stageFinished(AskPipelineStageSpan, outcome: ResourceWorkloadOutcome)
    case reached(AskPipelineTraceIdentity, milestone: AskPipelineMilestone)
    case finished(AskPipelineTraceIdentity, outcome: ResourceWorkloadOutcome)
}

/// One operation-local trace. It emits only closed enums and random
/// process-local correlation tokens, never payload fields.
public struct AskPipelineTrace: Sendable {
    public let identity: AskPipelineTraceIdentity
    private let receiver: @Sendable (AskPipelineEvent) -> Void

    init(
        identity: AskPipelineTraceIdentity,
        receiver: @escaping @Sendable (AskPipelineEvent) -> Void
    ) {
        self.identity = identity
        self.receiver = receiver
    }

    public func reach(_ milestone: AskPipelineMilestone) {
        receiver(.reached(identity, milestone: milestone))
    }

    public func measure<Value: Sendable>(
        _ stage: AskPipelineStage,
        operation: @Sendable () async throws -> Value
    ) async rethrows -> Value {
        let span = AskPipelineStageSpan(
            trace: identity,
            stage: stage)
        receiver(.stageStarted(span))
        do {
            let value = try await operation()
            receiver(.stageFinished(span, outcome: .completed))
            return value
        } catch {
            receiver(.stageFinished(
                span,
                outcome: ResourceWorkloadOutcome(error: error)))
            throw error
        }
    }
}

/// Synchronous telemetry port for the complete Ask pipeline. Product code
/// emits capability-neutral events; app and benchmark composition choose how
/// to retain timings. The default is inert.
public struct AskPipelineTelemetry: Sendable {
    private let receiver: @Sendable (AskPipelineEvent) -> Void

    public init(
        receiver: @escaping @Sendable (AskPipelineEvent) -> Void
    ) {
        self.receiver = receiver
    }

    public static let disabled = Self { _ in }

    public func measure<Value: Sendable>(
        _ operation: AskPipelineOperation,
        body: @Sendable (AskPipelineTrace) async throws -> Value
    ) async rethrows -> Value {
        let identity = AskPipelineTraceIdentity(operation: operation)
        let trace = AskPipelineTrace(
            identity: identity,
            receiver: receiver)
        receiver(.started(identity))
        do {
            let value = try await body(trace)
            receiver(.finished(identity, outcome: .completed))
            return value
        } catch {
            receiver(.finished(
                identity,
                outcome: ResourceWorkloadOutcome(error: error)))
            throw error
        }
    }
}
