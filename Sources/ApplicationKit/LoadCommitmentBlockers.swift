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

    public init(repository: any CommitmentBlockerFactReading) {
        self.repository = repository
    }

    public func execute(
        _ query: CommitmentBlockerQuery
    ) async throws -> MeetingMemoryGraphQueryResult {
        try await repository.commitmentBlockerFacts(query)
    }
}
