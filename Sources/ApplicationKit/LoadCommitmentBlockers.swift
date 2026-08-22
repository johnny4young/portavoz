import PortavozCore
import StorageKit

public protocol CommitmentBlockerFactReading: Sendable {
    func commitmentBlockerFacts(
        _ query: CommitmentBlockerQuery
    ) async throws -> MeetingMemoryGraphQueryResult
}

extension MeetingStore: CommitmentBlockerFactReading {}

/// Application boundary for the first source-backed Meeting Memory Graph
/// retrieval lane. Ask may compose this later, but this use case returns facts
/// and exact evidence only; it never synthesizes prose.
public struct LoadCommitmentBlockers: ApplicationUseCase {
    private let repository: any CommitmentBlockerFactReading
    private let telemetry: MeetingMemoryGraphQueryTelemetry

    public init(
        repository: any CommitmentBlockerFactReading,
        telemetry: MeetingMemoryGraphQueryTelemetry = .disabled
    ) {
        self.repository = repository
        self.telemetry = telemetry
    }

    public func execute(
        _ query: CommitmentBlockerQuery
    ) async throws -> MeetingMemoryGraphQueryResult {
        try await telemetry.measure(.commitmentBlockers) {
            try await repository.commitmentBlockerFacts(query)
        }
    }
}
