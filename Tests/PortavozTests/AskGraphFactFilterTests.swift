import ApplicationKit
import Foundation
import PortavozCore
import XCTest

final class AskGraphFactFilterTests: XCTestCase {
    func testDateRangeRequiresFiniteHalfOpenBounds() {
        let start = Date(timeIntervalSince1970: 1_000)

        XCTAssertTrue(AskGraphFactDateRange(
            startInclusive: start,
            endExclusive: start.addingTimeInterval(20)).isValid)
        XCTAssertFalse(AskGraphFactDateRange(
            startInclusive: start,
            endExclusive: start).isValid)
        XCTAssertFalse(AskGraphFactDateRange(
            startInclusive: Date(timeIntervalSinceReferenceDate: .infinity),
            endExclusive: Date.distantFuture).isValid)
    }

    func testCoreFilterUsesHalfOpenOccurrenceBoundsAndTypedStatus() {
        let start = Date(timeIntervalSince1970: 1_000)
        let filter = MeetingMemoryGraphFactFilter(
            occurredAtOrAfter: start,
            occurredBefore: start.addingTimeInterval(20),
            status: .active)

        XCTAssertTrue(filter.includes(occurredAt: start, status: .active))
        XCTAssertTrue(filter.includes(
            occurredAt: start.addingTimeInterval(19),
            status: .active))
        XCTAssertFalse(filter.includes(
            occurredAt: start.addingTimeInterval(20),
            status: .active))
        XCTAssertFalse(filter.includes(
            occurredAt: start,
            status: .confirmed))
    }

    func testCoreFilterIntersectionCombinesBoundsAndRejectsDisjointFilters() {
        let start = Date(timeIntervalSince1970: 1_000)
        let first = MeetingMemoryGraphFactFilter(
            occurredAtOrAfter: start,
            occurredBefore: start.addingTimeInterval(30),
            status: .active)
        let second = MeetingMemoryGraphFactFilter(
            occurredAtOrAfter: start.addingTimeInterval(10),
            occurredBefore: start.addingTimeInterval(20))

        XCTAssertEqual(
            first.intersection(with: second),
            MeetingMemoryGraphFactFilter(
                occurredAtOrAfter: start.addingTimeInterval(10),
                occurredBefore: start.addingTimeInterval(20),
                status: .active))
        XCTAssertNil(first.intersection(with: MeetingMemoryGraphFactFilter(
            status: .confirmed)))
        XCTAssertNil(first.intersection(with: MeetingMemoryGraphFactFilter(
            occurredAtOrAfter: start.addingTimeInterval(30))))
    }

    func testResolvedFilterRejectsInvalidConstraintsBeforeStorage() {
        let invalid = ResolvedAskGraphFactFilter(
            factFilter: MeetingMemoryGraphFactFilter(
                occurredAtOrAfter: Date(
                    timeIntervalSinceReferenceDate: .infinity)))

        XCTAssertEqual(
            invalid.applying(to: .personCommitments(PersonCommitmentsQuery(
                personID: PersonID()))),
            .abstained(.invalidQuery))
    }

    func testResolvedFilterRejectsInvalidExactQueryBeforeIntersection() {
        let filter = ResolvedAskGraphFactFilter(
            factFilter: MeetingMemoryGraphFactFilter(status: .active))
        let invalidExactFilter = MeetingMemoryGraphFactFilter(
            occurredAtOrAfter: Date(timeIntervalSinceReferenceDate: .infinity))
        let queries = AskGraphFactQuerySamples().all(filter: invalidExactFilter)

        XCTAssertEqual(
            queries.map(filter.applying),
            Array(
                repeating: .abstained(.invalidQuery),
                count: queries.count))
    }

    func testResolvedFilterIntersectsEveryExactQueryWithoutLosingFields() {
        let samples = AskGraphFactQuerySamples()
        let start = Date(timeIntervalSince1970: 1_000)
        let exactFilter = MeetingMemoryGraphFactFilter(
            occurredAtOrAfter: start,
            occurredBefore: start.addingTimeInterval(40))
        let requestedFilter = MeetingMemoryGraphFactFilter(
            occurredAtOrAfter: start.addingTimeInterval(10),
            occurredBefore: start.addingTimeInterval(30),
            status: .active)
        let resolved = ResolvedAskGraphFactFilter(factFilter: requestedFilter)
        let expected = samples.all(filter: requestedFilter)
            .map(AskGraphFactQueryApplication.query)

        XCTAssertEqual(
            samples.all(filter: exactFilter).map(resolved.applying),
            expected)
    }

    func testResolvedFilterAbstainsForDisjointConstraintsInEveryGraphJob() {
        let samples = AskGraphFactQuerySamples()
        let exactFilter = MeetingMemoryGraphFactFilter(status: .active)
        let resolved = ResolvedAskGraphFactFilter(
            factFilter: MeetingMemoryGraphFactFilter(status: .confirmed))
        let queries = samples.all(filter: exactFilter)

        XCTAssertEqual(
            queries.map(resolved.applying),
            Array(
                repeating: .abstained(.noMatchingFacts),
                count: queries.count))
    }

    func testResolvedPersonIdentityOnlyAppliesToMatchingPersonQuery() {
        let samples = AskGraphFactQuerySamples()
        let matching = ResolvedAskGraphFactFilter(personID: samples.personID)
        let mismatching = ResolvedAskGraphFactFilter(personID: PersonID())
        let exact = samples.personCommitments()

        XCTAssertEqual(matching.applying(to: exact), .query(exact))
        XCTAssertEqual(
            mismatching.applying(to: exact),
            .abstained(.invalidQuery))
        for incompatible in samples.queriesWithoutPersonIdentity() {
            XCTAssertEqual(
                matching.applying(to: incompatible),
                .abstained(.invalidQuery))
        }
    }

    func testResolvedTopicIdentityOnlyAppliesToMatchingTopicQueries() {
        let samples = AskGraphFactQuerySamples()
        let matching = ResolvedAskGraphFactFilter(topicID: samples.topicID)
        let mismatching = ResolvedAskGraphFactFilter(topicID: TopicID())

        for exact in samples.topicQueries() {
            XCTAssertEqual(matching.applying(to: exact), .query(exact))
            XCTAssertEqual(
                mismatching.applying(to: exact),
                .abstained(.invalidQuery))
        }
        for incompatible in samples.queriesWithoutTopicIdentity() {
            XCTAssertEqual(
                matching.applying(to: incompatible),
                .abstained(.invalidQuery))
        }
    }

    func testResolvedFilterRejectsCombinedIdentityDimensions() {
        let invalid = ResolvedAskGraphFactFilter(
            personID: PersonID(),
            topicID: TopicID())

        XCTAssertEqual(
            invalid.applying(to: AskGraphFactQuerySamples().personCommitments()),
            .abstained(.invalidQuery))
    }

    func testResolverProducesOnlyExactCanonicalPersonIdentityAndFilters() async throws {
        let person = Person(preferredName: "Mara")
        let candidates = AskGraphFilterCandidateFake(people: [person], topics: [])
        let range = AskGraphFactDateRange(
            startInclusive: Date(timeIntervalSince1970: 1_000),
            endExclusive: Date(timeIntervalSince1970: 2_000))
        let resolver = LocalAskGraphFactFilterResolver(
            people: candidates,
            topics: candidates)

        let result = try await resolver.resolve(AskGraphFactFilterRequest(
            personAlias: "mára",
            dateRange: range,
            status: .active))

        XCTAssertEqual(result, .resolved(ResolvedAskGraphFactFilter(
            personID: person.id,
            factFilter: MeetingMemoryGraphFactFilter(
                occurredAtOrAfter: range.startInclusive,
                occurredBefore: range.endExclusive,
                status: .active))))
        let calls = await candidates.calls
        XCTAssertEqual(calls, [.person("mára")])
    }

    func testResolverProducesOnlyExactCanonicalTopicIdentity() async throws {
        let topic = Topic(preferredLabel: "Project Atlas")
        let candidates = AskGraphFilterCandidateFake(people: [], topics: [topic])
        let resolver = LocalAskGraphFactFilterResolver(
            people: candidates,
            topics: candidates)

        let result = try await resolver.resolve(AskGraphFactFilterRequest(
            topicAlias: "Project Atlas"))

        XCTAssertEqual(result, .resolved(ResolvedAskGraphFactFilter(
            topicID: topic.id)))
        let calls = await candidates.calls
        XCTAssertEqual(calls, [.topic("Project Atlas")])
    }

    func testResolverRejectsInvalidAndAmbiguousAliasesWithoutGuessing() async throws {
        let candidates = AskGraphFilterCandidateFake(
            people: [Person(preferredName: "Alex"), Person(preferredName: "Alex")],
            topics: [])
        let resolver = LocalAskGraphFactFilterResolver(
            people: candidates,
            topics: candidates)

        let invalid = try await resolver.resolve(AskGraphFactFilterRequest(
            personAlias: "   "))
        let ambiguous = try await resolver.resolve(AskGraphFactFilterRequest(
            personAlias: "Alex"))

        XCTAssertEqual(invalid, .abstained(.invalidQuery))
        XCTAssertEqual(ambiguous, .abstained(.ambiguousPerson))
        let calls = await candidates.calls
        XCTAssertEqual(calls, [.person("Alex")])
    }

    func testResolverRejectsCombinedIdentityDimensionsAndNonfiniteDates() async throws {
        let candidates = AskGraphFilterCandidateFake(people: [], topics: [])
        let resolver = LocalAskGraphFactFilterResolver(
            people: candidates,
            topics: candidates)

        let combined = try await resolver.resolve(AskGraphFactFilterRequest(
            personAlias: "Mara",
            topicAlias: "Atlas"))
        let nonfinite = try await resolver.resolve(AskGraphFactFilterRequest(
            dateRange: AskGraphFactDateRange(
                startInclusive: Date(timeIntervalSinceReferenceDate: .infinity),
                endExclusive: Date.distantFuture)))

        XCTAssertEqual(combined, .abstained(.invalidQuery))
        XCTAssertEqual(nonfinite, .abstained(.invalidQuery))
        let calls = await candidates.calls
        XCTAssertTrue(calls.isEmpty)
    }

    func testResolverRejectsAmbiguousTopicsWithoutGuessing() async throws {
        let candidates = AskGraphFilterCandidateFake(
            people: [],
            topics: [
                Topic(preferredLabel: "Atlas"),
                Topic(preferredLabel: "Atlas")
            ])
        let resolver = LocalAskGraphFactFilterResolver(
            people: candidates,
            topics: candidates)

        let result = try await resolver.resolve(AskGraphFactFilterRequest(
            topicAlias: "Atlas"))

        XCTAssertEqual(result, .abstained(.ambiguousTopic))
    }

    func testAskBundlePushesFilterIntoExactQueryBeforeFactRetrieval() async throws {
        let personID = PersonID()
        let graphResult = MeetingMemoryGraphQueryResult.abstained(
            .projectionNotReady)
        let graph = AskFilteredGraphRetrievalFake(
            result: graphResult)
        let resolver = AskGraphFilterResolverFake(
            result: .resolved(ResolvedAskGraphFactFilter(
                personID: personID,
                factFilter: MeetingMemoryGraphFactFilter(status: .active))))
        let useCase = AskMeetings(
            retrieval: EmptyAskRetrievalFake(),
            answering: EmptyAskAnsweringFake(),
            graphFacts: graph,
            graphFilterResolver: resolver)
        let query = AskGraphFactQuery.personCommitments(
            PersonCommitmentsQuery(personID: personID))

        let bundle = try await useCase.evidenceBundle(
            "commitments",
            graphQuery: query,
            graphFilter: AskGraphFactFilterRequest(
                personAlias: "Mara",
                status: .active))

        XCTAssertEqual(bundle.graphFacts, .result(graphResult))
        let requests = await resolver.requests
        let queries = await graph.queries
        XCTAssertEqual(requests, [AskGraphFactFilterRequest(
            personAlias: "Mara",
            status: .active)])
        XCTAssertEqual(queries, [.personCommitments(PersonCommitmentsQuery(
            personID: personID,
            filter: MeetingMemoryGraphFactFilter(status: .active)))])
    }

    func testFilterAbstentionStopsExactFactRetrieval() async throws {
        let graph = AskFilteredGraphRetrievalFake(
            result: .abstained(.projectionNotReady))
        let resolver = AskGraphFilterResolverFake(
            result: .abstained(.ambiguousPerson))
        let useCase = AskMeetings(
            retrieval: EmptyAskRetrievalFake(),
            answering: EmptyAskAnsweringFake(),
            graphFacts: graph,
            graphFilterResolver: resolver)

        let bundle = try await useCase.evidenceBundle(
            "commitments",
            graphQuery: .personCommitments(PersonCommitmentsQuery(
                personID: PersonID())),
            graphFilter: AskGraphFactFilterRequest(personAlias: "Alex"))

        XCTAssertEqual(bundle.graphFacts, .result(.abstained(.ambiguousPerson)))
        let queries = await graph.queries
        XCTAssertTrue(queries.isEmpty)
    }

    func testResolvedIdentityMustMatchExactGraphQueryBeforeRetrieval() async throws {
        let graph = AskFilteredGraphRetrievalFake(result: .facts(makePage(facts: [])))
        let resolver = AskGraphFilterResolverFake(
            result: .resolved(ResolvedAskGraphFactFilter(personID: PersonID())))
        let useCase = AskMeetings(
            retrieval: EmptyAskRetrievalFake(),
            answering: EmptyAskAnsweringFake(),
            graphFacts: graph,
            graphFilterResolver: resolver)

        let bundle = try await useCase.evidenceBundle(
            "commitments",
            graphQuery: .personCommitments(PersonCommitmentsQuery(
                personID: PersonID())),
            graphFilter: AskGraphFactFilterRequest(personAlias: "Mara"))

        XCTAssertEqual(bundle.graphFacts, .result(.abstained(.invalidQuery)))
        let queries = await graph.queries
        XCTAssertTrue(queries.isEmpty)
    }

    func testIdentityFilterCannotChangeGraphJobKind() async throws {
        let graph = AskFilteredGraphRetrievalFake(result: .facts(makePage(facts: [])))
        let resolver = AskGraphFilterResolverFake(
            result: .resolved(ResolvedAskGraphFactFilter(topicID: TopicID())))
        let useCase = AskMeetings(
            retrieval: EmptyAskRetrievalFake(),
            answering: EmptyAskAnsweringFake(),
            graphFacts: graph,
            graphFilterResolver: resolver)

        let bundle = try await useCase.evidenceBundle(
            "blockers",
            graphQuery: .commitmentBlockers(CommitmentBlockerQuery(
                commitmentID: CommitmentID())),
            graphFilter: AskGraphFactFilterRequest(topicAlias: "Atlas"))

        XCTAssertEqual(bundle.graphFacts, .result(.abstained(.invalidQuery)))
        let queries = await graph.queries
        XCTAssertTrue(queries.isEmpty)
    }

    func testFilterWithoutGraphJobIsInvalidAndEntersNoCapability() async throws {
        let graph = AskFilteredGraphRetrievalFake(
            result: .abstained(.projectionNotReady))
        let resolver = AskGraphFilterResolverFake(
            result: .resolved(ResolvedAskGraphFactFilter()))
        let useCase = AskMeetings(
            retrieval: EmptyAskRetrievalFake(),
            answering: EmptyAskAnsweringFake(),
            graphFacts: graph,
            graphFilterResolver: resolver)

        let bundle = try await useCase.evidenceBundle(
            "commitments",
            graphFilter: AskGraphFactFilterRequest(status: .active))

        XCTAssertEqual(bundle.graphFacts, .result(.abstained(.invalidQuery)))
        let queries = await graph.queries
        let requests = await resolver.requests
        XCTAssertTrue(queries.isEmpty)
        XCTAssertTrue(requests.isEmpty)
    }
}

private struct AskGraphFactQuerySamples {
    let commitmentID = CommitmentID()
    let topicID = TopicID()
    let personID = PersonID()
    let sinceMeetingID = MeetingID()

    func all(
        filter: MeetingMemoryGraphFactFilter = MeetingMemoryGraphFactFilter()
    ) -> [AskGraphFactQuery] {
        [
            commitmentBlockers(filter: filter),
            topicFirstDiscussion(filter: filter),
            personCommitments(filter: filter),
            decisionConflicts(filter: filter),
            decisionHistory(filter: filter),
            changeSince(filter: filter)
        ]
    }

    func topicQueries() -> [AskGraphFactQuery] {
        [
            topicFirstDiscussion(),
            decisionConflicts(),
            decisionHistory(),
            changeSince()
        ]
    }

    func queriesWithoutPersonIdentity() -> [AskGraphFactQuery] {
        [commitmentBlockers()] + topicQueries()
    }

    func queriesWithoutTopicIdentity() -> [AskGraphFactQuery] {
        [commitmentBlockers(), personCommitments()]
    }

    func commitmentBlockers(
        filter: MeetingMemoryGraphFactFilter = MeetingMemoryGraphFactFilter()
    ) -> AskGraphFactQuery {
        .commitmentBlockers(CommitmentBlockerQuery(
            commitmentID: commitmentID,
            itemLimit: 7,
            filter: filter))
    }

    func topicFirstDiscussion(
        filter: MeetingMemoryGraphFactFilter = MeetingMemoryGraphFactFilter()
    ) -> AskGraphFactQuery {
        .topicFirstDiscussion(TopicFirstDiscussionQuery(
            topicID: topicID,
            filter: filter))
    }

    func personCommitments(
        filter: MeetingMemoryGraphFactFilter = MeetingMemoryGraphFactFilter()
    ) -> AskGraphFactQuery {
        .personCommitments(PersonCommitmentsQuery(
            personID: personID,
            itemLimit: 8,
            filter: filter))
    }

    func decisionConflicts(
        filter: MeetingMemoryGraphFactFilter = MeetingMemoryGraphFactFilter()
    ) -> AskGraphFactQuery {
        .decisionConflicts(DecisionConflictsQuery(
            topicID: topicID,
            itemLimit: 9,
            filter: filter))
    }

    func decisionHistory(
        filter: MeetingMemoryGraphFactFilter = MeetingMemoryGraphFactFilter()
    ) -> AskGraphFactQuery {
        .decisionHistory(DecisionHistoryQuery(
            topicID: topicID,
            itemLimit: 10,
            filter: filter))
    }

    func changeSince(
        filter: MeetingMemoryGraphFactFilter = MeetingMemoryGraphFactFilter()
    ) -> AskGraphFactQuery {
        .changeSince(ChangeSinceQuery(
            topicID: topicID,
            sinceMeetingID: sinceMeetingID,
            itemLimit: 11,
            filter: filter))
    }
}

private func makePage(
    facts: [MeetingMemoryGraphFact],
    hasMore: Bool = false
) -> MeetingMemoryGraphFactPage {
    MeetingMemoryGraphFactPage(
        facts: facts,
        hasMore: hasMore,
        projectionGeneration: 7,
        omittedStaleCount: 2,
        omittedUnavailableCount: 3)
}

private actor AskGraphFilterCandidateFake:
    CanonicalPersonCandidateReading,
    CanonicalTopicCandidateReading {
    enum Call: Equatable {
        case person(String)
        case topic(String)
    }

    let people: [Person]
    let topics: [Topic]
    private(set) var calls: [Call] = []

    init(people: [Person], topics: [Topic]) {
        self.people = people
        self.topics = topics
    }

    func people(matchingAlias alias: String) -> [Person] {
        calls.append(.person(alias))
        return people
    }

    func topics(matchingAlias alias: String) -> [Topic] {
        calls.append(.topic(alias))
        return topics
    }
}

private actor AskGraphFilterResolverFake: AskGraphFactFilterResolving {
    let result: AskGraphFactFilterResolution
    private(set) var requests: [AskGraphFactFilterRequest] = []

    init(result: AskGraphFactFilterResolution) {
        self.result = result
    }

    func resolve(
        _ request: AskGraphFactFilterRequest
    ) -> AskGraphFactFilterResolution {
        requests.append(request)
        return result
    }
}

private actor AskFilteredGraphRetrievalFake: AskGraphFactRetrieving {
    let result: MeetingMemoryGraphQueryResult
    private(set) var queries: [AskGraphFactQuery] = []

    init(result: MeetingMemoryGraphQueryResult) {
        self.result = result
    }

    func retrieve(
        _ query: AskGraphFactQuery
    ) -> MeetingMemoryGraphQueryResult {
        queries.append(query)
        return result
    }
}

private struct EmptyAskRetrievalFake: AskMeetingRetrieving {
    func search(query _: String, limit _: Int) -> [AskSearchResult] { [] }
    func retrieve(question _: String, limit _: Int) -> [AskCitation] { [] }
}

private struct EmptyAskAnsweringFake: AskMeetingAnswering {
    func answer(question _: String, citations _: [AskCitation]) -> String? { nil }
}
