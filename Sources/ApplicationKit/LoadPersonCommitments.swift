import PortavozCore
import StorageKit

public protocol PersonCommitmentFactReading: Sendable {
    func personCommitmentFacts(
        _ query: PersonCommitmentsQuery
    ) async throws -> MeetingMemoryGraphQueryResult
}

extension MeetingStore: PersonCommitmentFactReading {}

/// Application boundary for source-backed current commitments owned by one
/// exact canonical person. Identity discovery and answer synthesis remain
/// separate concerns.
public struct LoadPersonCommitments: ApplicationUseCase {
    private let repository: any PersonCommitmentFactReading

    public init(repository: any PersonCommitmentFactReading) {
        self.repository = repository
    }

    public func execute(
        _ query: PersonCommitmentsQuery
    ) async throws -> MeetingMemoryGraphQueryResult {
        try await repository.personCommitmentFacts(query)
    }
}
