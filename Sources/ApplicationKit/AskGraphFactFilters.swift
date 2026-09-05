import Foundation
import PortavozCore
import StorageKit

/// Caller-extracted half-open range. Locale and end-of-day interpretation must
/// happen before this boundary; graph retrieval receives exact instants only.
public struct AskGraphFactDateRange: Equatable, Sendable {
    public let startInclusive: Date
    public let endExclusive: Date

    public init(startInclusive: Date, endExclusive: Date) {
        self.startInclusive = startInclusive
        self.endExclusive = endExclusive
    }

    public var isValid: Bool {
        startInclusive.timeIntervalSinceReferenceDate.isFinite
            && endExclusive.timeIntervalSinceReferenceDate.isFinite
            && startInclusive < endExclusive
    }

    var graphFilter: MeetingMemoryGraphFactFilter {
        MeetingMemoryGraphFactFilter(
            occurredAtOrAfter: startInclusive,
            occurredBefore: endExclusive)
    }
}

/// Exact filters extracted by a caller. Identity aliases remain separate from
/// the graph job so this layer can resolve or abstain without guessing.
public struct AskGraphFactFilterRequest: Equatable, Sendable {
    public let personAlias: String?
    public let topicAlias: String?
    public let dateRange: AskGraphFactDateRange?
    public let status: MeetingMemoryGraphFactStatus?

    public init(
        personAlias: String? = nil,
        topicAlias: String? = nil,
        dateRange: AskGraphFactDateRange? = nil,
        status: MeetingMemoryGraphFactStatus? = nil
    ) {
        self.personAlias = personAlias
        self.topicAlias = topicAlias
        self.dateRange = dateRange
        self.status = status
    }

    public var isValid: Bool {
        guard personAlias == nil || topicAlias == nil else { return false }
        if let personAlias,
           PersonAliasNormalizer.normalize(personAlias) == nil {
            return false
        }
        if let topicAlias,
           TopicAliasNormalizer.normalize(topicAlias) == nil {
            return false
        }
        return dateRange?.isValid != false
    }
}

/// Identity-safe constraints admitted after exact alias resolution. Applying
/// one creates another exact graph query; it never post-filters a bounded page.
public struct ResolvedAskGraphFactFilter: Equatable, Sendable {
    public let personID: PersonID?
    public let topicID: TopicID?
    public let factFilter: MeetingMemoryGraphFactFilter

    public init(
        personID: PersonID? = nil,
        topicID: TopicID? = nil,
        factFilter: MeetingMemoryGraphFactFilter = MeetingMemoryGraphFactFilter()
    ) {
        self.personID = personID
        self.topicID = topicID
        self.factFilter = factFilter
    }

    public func applying(
        to query: AskGraphFactQuery
    ) -> AskGraphFactQueryApplication {
        guard personID == nil || topicID == nil,
              factFilter.isValid
        else {
            return .abstained(.invalidQuery)
        }
        switch query {
        case .commitmentBlockers(let exact):
            return applying(to: exact)
        case .topicFirstDiscussion(let exact):
            return applying(to: exact)
        case .personCommitments(let exact):
            return applying(to: exact)
        case .decisionConflicts(let exact):
            return applying(to: exact)
        case .decisionHistory(let exact):
            return applying(to: exact)
        case .changeSince(let exact):
            return applying(to: exact)
        }
    }

    private func applying(
        to exact: CommitmentBlockerQuery
    ) -> AskGraphFactQueryApplication {
        applying(
            exactIsValid: exact.isValid,
            identityIsCompatible: personID == nil && topicID == nil,
            exactFilter: exact.filter
        ) { filter in
            .commitmentBlockers(CommitmentBlockerQuery(
                commitmentID: exact.commitmentID,
                itemLimit: exact.itemLimit,
                filter: filter))
        }
    }

    private func applying(
        to exact: TopicFirstDiscussionQuery
    ) -> AskGraphFactQueryApplication {
        applyingToTopic(
            topicID: exact.topicID,
            exactIsValid: exact.isValid,
            exactFilter: exact.filter
        ) { filter in
            .topicFirstDiscussion(TopicFirstDiscussionQuery(
                topicID: exact.topicID,
                filter: filter))
        }
    }

    private func applying(
        to exact: PersonCommitmentsQuery
    ) -> AskGraphFactQueryApplication {
        applying(
            exactIsValid: exact.isValid,
            identityIsCompatible: topicID == nil
                && (personID == nil || personID == exact.personID),
            exactFilter: exact.filter
        ) { filter in
            .personCommitments(PersonCommitmentsQuery(
                personID: exact.personID,
                itemLimit: exact.itemLimit,
                filter: filter))
        }
    }

    private func applying(
        to exact: DecisionConflictsQuery
    ) -> AskGraphFactQueryApplication {
        applyingToTopic(
            topicID: exact.topicID,
            exactIsValid: exact.isValid,
            exactFilter: exact.filter
        ) { filter in
            .decisionConflicts(DecisionConflictsQuery(
                topicID: exact.topicID,
                itemLimit: exact.itemLimit,
                filter: filter))
        }
    }

    private func applying(
        to exact: DecisionHistoryQuery
    ) -> AskGraphFactQueryApplication {
        applyingToTopic(
            topicID: exact.topicID,
            exactIsValid: exact.isValid,
            exactFilter: exact.filter
        ) { filter in
            .decisionHistory(DecisionHistoryQuery(
                topicID: exact.topicID,
                itemLimit: exact.itemLimit,
                filter: filter))
        }
    }

    private func applying(
        to exact: ChangeSinceQuery
    ) -> AskGraphFactQueryApplication {
        applyingToTopic(
            topicID: exact.topicID,
            exactIsValid: exact.isValid,
            exactFilter: exact.filter
        ) { filter in
            .changeSince(ChangeSinceQuery(
                topicID: exact.topicID,
                sinceMeetingID: exact.sinceMeetingID,
                itemLimit: exact.itemLimit,
                filter: filter))
        }
    }

    private func applyingToTopic(
        topicID exactTopicID: TopicID,
        exactIsValid: Bool,
        exactFilter: MeetingMemoryGraphFactFilter,
        makeQuery: (MeetingMemoryGraphFactFilter) -> AskGraphFactQuery
    ) -> AskGraphFactQueryApplication {
        applying(
            exactIsValid: exactIsValid,
            identityIsCompatible: personID == nil
                && (topicID == nil || topicID == exactTopicID),
            exactFilter: exactFilter,
            makeQuery: makeQuery)
    }

    private func applying(
        exactIsValid: Bool,
        identityIsCompatible: Bool,
        exactFilter: MeetingMemoryGraphFactFilter,
        makeQuery: (MeetingMemoryGraphFactFilter) -> AskGraphFactQuery
    ) -> AskGraphFactQueryApplication {
        guard exactIsValid, identityIsCompatible else {
            return .abstained(.invalidQuery)
        }
        guard let filter = exactFilter.intersection(with: factFilter) else {
            return .abstained(.noMatchingFacts)
        }
        return .query(makeQuery(filter))
    }
}

public enum AskGraphFactQueryApplication: Equatable, Sendable {
    case query(AskGraphFactQuery)
    case abstained(MeetingMemoryGraphQueryAbstention)
}

public enum AskGraphFactFilterResolution: Equatable, Sendable {
    case resolved(ResolvedAskGraphFactFilter)
    case abstained(MeetingMemoryGraphQueryAbstention)
}

public protocol AskGraphFactFilterResolving: Sendable {
    func resolve(
        _ request: AskGraphFactFilterRequest
    ) async throws -> AskGraphFactFilterResolution
}

/// Read-only exact alias resolver. Duplicate aliases remain visible as
/// ambiguity; this capability never mutates person or topic continuity.
public struct LocalAskGraphFactFilterResolver: AskGraphFactFilterResolving {
    private let people: any CanonicalPersonCandidateReading
    private let topics: any CanonicalTopicCandidateReading

    public init(store: MeetingStore) {
        people = store
        topics = store
    }

    public init(
        people: any CanonicalPersonCandidateReading,
        topics: any CanonicalTopicCandidateReading
    ) {
        self.people = people
        self.topics = topics
    }

    public func resolve(
        _ request: AskGraphFactFilterRequest
    ) async throws -> AskGraphFactFilterResolution {
        guard request.isValid else { return .abstained(.invalidQuery) }
        let factFilter = MeetingMemoryGraphFactFilter(
            occurredAtOrAfter: request.dateRange?.startInclusive,
            occurredBefore: request.dateRange?.endExclusive,
            status: request.status)

        if let alias = request.personAlias {
            let candidates = try await people.people(matchingAlias: alias)
            guard !candidates.isEmpty else {
                return .abstained(.personUnavailable)
            }
            guard candidates.count == 1, let person = candidates.first else {
                return .abstained(.ambiguousPerson)
            }
            return .resolved(ResolvedAskGraphFactFilter(
                personID: person.id,
                factFilter: factFilter))
        }

        if let alias = request.topicAlias {
            let candidates = try await topics.topics(matchingAlias: alias)
            guard !candidates.isEmpty else {
                return .abstained(.topicUnavailable)
            }
            guard candidates.count == 1, let topic = candidates.first else {
                return .abstained(.ambiguousTopic)
            }
            return .resolved(ResolvedAskGraphFactFilter(
                topicID: topic.id,
                factFilter: factFilter))
        }

        return .resolved(ResolvedAskGraphFactFilter(factFilter: factFilter))
    }
}
