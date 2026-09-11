import PortavozCore
import StorageKit

public protocol PersonCommitmentFactReading: Sendable {
    func personCommitmentFacts(
        _ query: PersonCommitmentsQuery
    ) async throws -> MeetingMemoryGraphQueryResult
}

extension MeetingStore: PersonCommitmentFactReading {}

/// Caller-extracted alias lookup before the exact person fact query. This is
/// deliberately not a natural-language parser.
public struct PersonCommitmentsAliasQuery: Equatable, Sendable {
    public let alias: String
    public let itemLimit: Int

    public init(
        alias: String,
        itemLimit: Int = PersonCommitmentsQuery.defaultItemLimit
    ) {
        self.alias = alias
        self.itemLimit = itemLimit
    }

    public var isValid: Bool {
        PersonAliasNormalizer.normalize(alias) != nil
            && (1...PersonCommitmentsQuery.maximumItemLimit).contains(itemLimit)
    }
}

/// Application boundary for source-backed current commitments owned by one
/// exact canonical person. Identity discovery and answer synthesis remain
/// separate concerns.
public struct LoadPersonCommitments: ApplicationUseCase {
    private let repository: any PersonCommitmentFactReading
    private let telemetry: MeetingMemoryGraphQueryTelemetry

    public init(
        repository: any PersonCommitmentFactReading,
        telemetry: MeetingMemoryGraphQueryTelemetry = .disabled
    ) {
        self.repository = repository
        self.telemetry = telemetry
    }

    public func execute(
        _ query: PersonCommitmentsQuery
    ) async throws -> MeetingMemoryGraphQueryResult {
        try await telemetry.measure(.personCommitments) {
            try await repository.personCommitmentFacts(query)
        }
    }
}

/// Resolves one exact normalized alias and delegates only an unambiguous
/// canonical identity to the source-backed fact reader. Zero or multiple
/// candidates fail closed before StorageKit receives a person query.
public struct LoadPersonCommitmentsByAlias: ApplicationUseCase {
    private let people: any CanonicalPersonCandidateReading
    private let commitments: any PersonCommitmentFactReading
    private let telemetry: MeetingMemoryGraphQueryTelemetry

    public init(
        people: any CanonicalPersonCandidateReading,
        commitments: any PersonCommitmentFactReading,
        telemetry: MeetingMemoryGraphQueryTelemetry = .disabled
    ) {
        self.people = people
        self.commitments = commitments
        self.telemetry = telemetry
    }

    public func execute(
        _ query: PersonCommitmentsAliasQuery
    ) async throws -> MeetingMemoryGraphQueryResult {
        guard query.isValid else { return .abstained(.invalidQuery) }
        let candidates = try await people.people(matchingAlias: query.alias)
        guard !candidates.isEmpty else {
            return .abstained(.personUnavailable)
        }
        guard candidates.count == 1, let person = candidates.first else {
            return .abstained(.ambiguousPerson)
        }
        return try await LoadPersonCommitments(
            repository: commitments,
            telemetry: telemetry).execute(
            PersonCommitmentsQuery(
                personID: person.id,
                itemLimit: query.itemLimit))
    }
}
