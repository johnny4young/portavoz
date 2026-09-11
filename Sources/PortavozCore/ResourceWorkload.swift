import Foundation

/// Scheduling importance for resource-intensive work.
///
/// The class is independent from task priority: it describes the product
/// contract that the future resource governor must preserve.
public enum ResourceWorkloadClass: String, CaseIterable, Sendable {
    /// Start, capture, and Stop work whose delay can lose a recording.
    case recordingCritical
    /// Work that updates a live meeting while a person is watching.
    case liveInteractive
    /// Explicit work for which a person is currently waiting.
    case userInitiated
    /// Durable work admitted after captured audio is already safe.
    case postCapture
    /// Deferrable reconciliation, indexing, and cleanup.
    case maintenance
}

/// Closed, content-free resource families used for measurement and policy.
public enum ResourceWorkloadKind: String, CaseIterable, Sendable {
    case audioCapture
    case liveTranscription
    case qualityTranscription
    case speakerDiarization
    case languageInference
    case searchIndex
    case memoryGraph
    case librarySync
    case waveform
    case uiProjection
    case mediaExport
    case supportExport
}

/// Resource boundary being measured for a workload.
public enum ResourceWorkloadOperation: String, CaseIterable, Sendable {
    case queueWait
    case execute
    case prepare
    case load
    case release
}

public enum ResourceWorkloadOutcome: String, CaseIterable, Sendable {
    case completed
    case cancelled
    case failed

    public init(error: any Error) {
        self = error is CancellationError ? .cancelled : .failed
    }
}

/// An allowlisted description with no meeting, file, model, or content identity.
public struct ResourceWorkloadDescriptor: Equatable, Sendable {
    public let workloadClass: ResourceWorkloadClass
    public let kind: ResourceWorkloadKind
    public let operation: ResourceWorkloadOperation

    public init(
        workloadClass: ResourceWorkloadClass,
        kind: ResourceWorkloadKind,
        operation: ResourceWorkloadOperation
    ) {
        self.workloadClass = workloadClass
        self.kind = kind
        self.operation = operation
    }
}

/// A random process-local correlation token for one measured interval.
public struct ResourceWorkloadSpan: Equatable, Sendable {
    public let id: UUID
    public let descriptor: ResourceWorkloadDescriptor

    public init(
        id: UUID = UUID(),
        descriptor: ResourceWorkloadDescriptor
    ) {
        self.id = id
        self.descriptor = descriptor
    }
}

public enum ResourceWorkloadEvent: Equatable, Sendable {
    case started(ResourceWorkloadSpan)
    case finished(ResourceWorkloadSpan, outcome: ResourceWorkloadOutcome)
}

/// Synchronous, content-free telemetry port. Capability packages emit domain
/// values; the executable composition root decides whether and how to record
/// them. The disabled value keeps tests and non-app products deterministic.
public struct ResourceWorkloadTelemetry: Sendable {
    private let receiver: @Sendable (ResourceWorkloadEvent) -> Void

    public init(
        receiver: @escaping @Sendable (ResourceWorkloadEvent) -> Void
    ) {
        self.receiver = receiver
    }

    public static let disabled = Self { _ in }

    @discardableResult
    public func begin(_ descriptor: ResourceWorkloadDescriptor) -> ResourceWorkloadSpan {
        let span = ResourceWorkloadSpan(descriptor: descriptor)
        receiver(.started(span))
        return span
    }

    public func finish(
        _ span: ResourceWorkloadSpan,
        outcome: ResourceWorkloadOutcome
    ) {
        receiver(.finished(span, outcome: outcome))
    }

    func emit(_ event: ResourceWorkloadEvent) {
        receiver(event)
    }

    public func measure<Value: Sendable>(
        _ descriptor: ResourceWorkloadDescriptor,
        operation: @Sendable () async throws -> Value
    ) async rethrows -> Value {
        let span = begin(descriptor)
        do {
            let value = try await operation()
            finish(span, outcome: .completed)
            return value
        } catch {
            finish(span, outcome: ResourceWorkloadOutcome(error: error))
            throw error
        }
    }
}

/// A narrow installation seam for process-wide schedulers whose providers are
/// created ad hoc. It relays only allowlisted events and never stores payloads.
public final class ResourceWorkloadTelemetryRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var installed: ResourceWorkloadTelemetry

    public init(telemetry: ResourceWorkloadTelemetry = .disabled) {
        installed = telemetry
    }

    public func install(_ telemetry: ResourceWorkloadTelemetry) {
        lock.lock()
        installed = telemetry
        lock.unlock()
    }

    public var telemetry: ResourceWorkloadTelemetry {
        ResourceWorkloadTelemetry { [weak self] event in
            self?.receive(event)
        }
    }

    private func receive(_ event: ResourceWorkloadEvent) {
        lock.lock()
        let telemetry = installed
        lock.unlock()
        telemetry.emit(event)
    }
}
