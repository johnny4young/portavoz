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
            guard exact.isValid,
                  personID == nil,
                  topicID == nil
            else {
                return .abstained(.invalidQuery)
            }
            guard let filter = exact.filter.intersection(with: factFilter) else {
                return .abstained(.noMatchingFacts)
            }
            return .query(.commitmentBlockers(CommitmentBlockerQuery(
                commitmentID: exact.commitmentID,
                itemLimit: exact.itemLimit,
                filter: filter)))
        case .topicFirstDiscussion(let exact):
            guard exact.isValid,
                  personID == nil,
                  topicID == nil || topicID == exact.topicID
            else { return .abstained(.invalidQuery) }
            guard let filter = exact.filter.intersection(with: factFilter) else {
                return .abstained(.noMatchingFacts)
            }
            return .query(.topicFirstDiscussion(TopicFirstDiscussionQuery(
                topicID: exact.topicID,
                filter: filter)))
        case .personCommitments(let exact):
            guard exact.isValid,
                  topicID == nil,
                  personID == nil || personID == exact.personID
            else { return .abstained(.invalidQuery) }
            guard let filter = exact.filter.intersection(with: factFilter) else {
                return .abstained(.noMatchingFacts)
            }
            return .query(.personCommitments(PersonCommitmentsQuery(
                personID: exact.personID,
                itemLimit: exact.itemLimit,
                filter: filter)))
        }
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
