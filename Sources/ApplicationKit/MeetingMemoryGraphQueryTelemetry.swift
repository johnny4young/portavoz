import Foundation
import PortavozCore

/// Closed product jobs for the six exact Meeting Memory Graph reads. This
/// vocabulary deliberately carries no query, person, topic, meeting, or
/// commitment identity.
public enum MeetingMemoryGraphQueryJob: String, CaseIterable, Sendable {
    case commitmentBlockers
    case topicFirstDiscussion
    case personCommitments
    case decisionConflicts
    case changeSince
    case decisionHistory
}

/// Content-free terminal state for one graph query. Successful fact and
/// abstention outcomes stay distinct without exposing counts or domain reasons;
/// thrown errors are reduced to cancellation versus failure.
public enum MeetingMemoryGraphQueryOutcome: String, CaseIterable, Sendable {
    case facts
    case abstained
    case cancelled
    case failed
}

/// Random process-local correlation for one measured read.
public struct MeetingMemoryGraphQueryTrace: Equatable, Sendable {
    public let id: UUID
    public let job: MeetingMemoryGraphQueryJob

    public init(
        id: UUID = UUID(),
        job: MeetingMemoryGraphQueryJob
    ) {
        self.id = id
        self.job = job
    }
}

public enum MeetingMemoryGraphQueryEvent: Equatable, Sendable {
    case started(MeetingMemoryGraphQueryTrace)
    case finished(
        MeetingMemoryGraphQueryTrace,
        outcome: MeetingMemoryGraphQueryOutcome)
}

/// Synchronous, content-free telemetry port for exact graph reads. Application
/// use cases emit closed values; the executable composition root decides
/// whether to record a timing interval. Tests and non-app consumers default to
/// the inert value.
public struct MeetingMemoryGraphQueryTelemetry: Sendable {
    private let receiver: @Sendable (MeetingMemoryGraphQueryEvent) -> Void

    public init(
        receiver: @escaping @Sendable (MeetingMemoryGraphQueryEvent) -> Void
    ) {
        self.receiver = receiver
    }

    public static let disabled = Self { _ in }

    public func measure(
        _ job: MeetingMemoryGraphQueryJob,
        operation: @Sendable () async throws -> MeetingMemoryGraphQueryResult
    ) async rethrows -> MeetingMemoryGraphQueryResult {
        let trace = MeetingMemoryGraphQueryTrace(job: job)
        receiver(.started(trace))
        do {
            let result = try await operation()
            let outcome: MeetingMemoryGraphQueryOutcome = switch result {
            case .facts: .facts
            case .abstained: .abstained
            }
            receiver(.finished(trace, outcome: outcome))
            return result
        } catch {
            receiver(.finished(
                trace,
                outcome: error is CancellationError ? .cancelled : .failed))
            throw error
        }
    }
}
