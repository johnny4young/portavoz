import ApplicationKit
import Foundation
import PortavozCore
import XCTest

final class AskMeetingsUseCaseTests: XCTestCase {
    func testSearchEvidenceAndAnswerShareOneTrimmedWorkflow() async throws {
        let fixture = AskWorkflowFixture()
        let retrieval = AskMeetingRetrievalFake(
            searches: fixture.searches,
            citations: fixture.citations)
        let answering = AskMeetingAnsweringFake(text: "El viernes.")
        let useCase = AskMeetings(retrieval: retrieval, answering: answering)

        let searches = try await useCase.search("  rollout  ", limit: 4)
        let citations = try await useCase.evidence("  rollout  ", limit: 5)
        let answer = try await useCase.answer("  rollout  ", limit: 6)

        XCTAssertEqual(searches, fixture.searches)
        XCTAssertEqual(citations, fixture.citations)
        XCTAssertEqual(answer.question, "rollout")
        XCTAssertEqual(answer.generatedText, "El viernes.")
        XCTAssertEqual(answer.citations, fixture.citations)
        let retrievalCalls = await retrieval.calls
        XCTAssertEqual(retrievalCalls, [
            .search("rollout", 4),
            .retrieve("rollout", 5),
            .retrieve("rollout", 6),
        ])
        let answerCallCount = await answering.callCount
        XCTAssertEqual(answerCallCount, 1)
    }

    func testNoEvidenceSkipsGenerationAndKeepsTypedEmptyAnswer() async throws {
        let retrieval = AskMeetingRetrievalFake(searches: [], citations: [])
        let answering = AskMeetingAnsweringFake(text: "must not be used")
        let useCase = AskMeetings(retrieval: retrieval, answering: answering)

        let result = try await useCase.answer("unknown")

        XCTAssertEqual(result.question, "unknown")
        XCTAssertNil(result.generatedText)
        XCTAssertTrue(result.citations.isEmpty)
        let answerCallCount = await answering.callCount
        XCTAssertEqual(answerCallCount, 0)
    }

    func testGenerationFailureDegradesToEvidenceInsteadOfLosingReceipts() async throws {
        let fixture = AskWorkflowFixture()
        let retrieval = AskMeetingRetrievalFake(
            searches: fixture.searches,
            citations: fixture.citations)
        let answering = AskMeetingAnsweringFake(error: AskWorkflowError.generation)
        let useCase = AskMeetings(retrieval: retrieval, answering: answering)

        let result = try await useCase.answer("rollout")

        XCTAssertNil(result.generatedText)
        XCTAssertEqual(result.citations, fixture.citations)
    }

    func testGenerationCancellationPropagatesInsteadOfMasqueradingAsEvidence() async throws {
        let fixture = AskWorkflowFixture()
        let retrieval = AskMeetingRetrievalFake(
            searches: fixture.searches,
            citations: fixture.citations)
        let answering = AskMeetingAnsweringFake(error: CancellationError())
        let useCase = AskMeetings(retrieval: retrieval, answering: answering)

        do {
            _ = try await useCase.answer("rollout")
            XCTFail("cancellation must leave the application workflow")
        } catch is CancellationError {
            // Expected: presentation owners discard cancelled work by generation.
        }
    }

    func testProgressiveAnswerPublishesLexicalEvidenceBeforeGeneration() async throws {
        let fixture = AskWorkflowFixture()
        let retrieval = ProgressiveAskMeetingRetrievalFake(
            lexical: fixture.citations,
            fused: fixture.citations)
        let answering = AskMeetingAnsweringFake(text: "El viernes.")
        let updates = AskEvidenceUpdateRecorder()
        let useCase = AskMeetings(retrieval: retrieval, answering: answering)

        let task = Task {
            try await useCase.answer(
                "rollout",
                onEvidence: { update in
                    await updates.receive(update)
                })
        }
        await retrieval.waitUntilLexicalEvidenceIsPublished()

        let lexicalUpdates = await updates.values
        let callsBeforeFusion = await answering.callCount
        XCTAssertEqual(
            lexicalUpdates,
            [AskEvidenceUpdate(
                phase: .lexical,
                citations: fixture.citations)])
        XCTAssertEqual(callsBeforeFusion, 0)

        await retrieval.releaseFusion()
        let result = try await task.value
        let finalUpdates = await updates.values
        let finalCallCount = await answering.callCount

        XCTAssertEqual(result.generatedText, "El viernes.")
        XCTAssertEqual(result.citations, fixture.citations)
        XCTAssertEqual(
            finalUpdates,
            [
                AskEvidenceUpdate(
                    phase: .lexical,
                    citations: fixture.citations),
                AskEvidenceUpdate(
                    phase: .fused,
                    citations: fixture.citations),
            ])
        XCTAssertEqual(finalCallCount, 1)
    }

    func testEvidenceBundleKeepsTranscriptAndGraphLanesIndependent() async throws {
        let fixture = AskWorkflowFixture()
        let retrieval = AskMeetingRetrievalFake(
            searches: fixture.searches,
            citations: fixture.citations)
        let expected = MeetingMemoryGraphQueryResult.abstained(
            .projectionNotReady)
        let graph = AskGraphFactRetrievalFake(result: expected)
        let query = AskGraphFactQuery.personCommitments(
            PersonCommitmentsQuery(personID: PersonID(), itemLimit: 4))
        let useCase = AskMeetings(
            retrieval: retrieval,
            answering: AskMeetingAnsweringFake(text: nil),
            graphFacts: graph)

        let result = try await useCase.evidenceBundle(
            "rollout",
            limit: 5,
            graphQuery: query)

        XCTAssertEqual(result.transcriptCitations, fixture.citations)
        XCTAssertEqual(result.graphFacts, .result(expected))
        let graphCalls = await graph.calls
        XCTAssertEqual(graphCalls, [query])
    }

    func testGraphFailureIsDisclosedWithoutErasingTranscriptEvidence() async throws {
        let fixture = AskWorkflowFixture()
        let graph = AskGraphFactRetrievalFake(error: AskWorkflowError.graph)
        let useCase = AskMeetings(
            retrieval: AskMeetingRetrievalFake(
                searches: fixture.searches,
                citations: fixture.citations),
            answering: AskMeetingAnsweringFake(text: nil),
            graphFacts: graph)

        let result = try await useCase.evidenceBundle(
            "rollout",
            graphQuery: .topicFirstDiscussion(
                TopicFirstDiscussionQuery(topicID: TopicID())))

        XCTAssertEqual(result.transcriptCitations, fixture.citations)
        XCTAssertEqual(result.graphFacts, .unavailable)
    }

    func testEvidenceBundleWithoutGraphQueryKeepsLaneNotRequested() async throws {
        let fixture = AskWorkflowFixture()
        let graph = AskGraphFactRetrievalFake(
            result: .abstained(.projectionNotReady))
        let useCase = AskMeetings(
            retrieval: AskMeetingRetrievalFake(
                searches: fixture.searches,
                citations: fixture.citations),
            answering: AskMeetingAnsweringFake(text: nil),
            graphFacts: graph)

        let result = try await useCase.evidenceBundle("rollout")

        XCTAssertEqual(result.transcriptCitations, fixture.citations)
        XCTAssertEqual(result.graphFacts, .notRequested)
        let graphCalls = await graph.calls
        XCTAssertTrue(graphCalls.isEmpty)
    }

    func testGraphFactsCannotReplaceFailedTranscriptRetrieval() async throws {
        let graph = AskGraphFactRetrievalFake(
            result: .abstained(.projectionNotReady))
        let useCase = AskMeetings(
            retrieval: FailingAskMeetingRetrievalFake(),
            answering: AskMeetingAnsweringFake(text: nil),
            graphFacts: graph)

        do {
            _ = try await useCase.evidenceBundle(
                "rollout",
                graphQuery: .topicFirstDiscussion(
                    TopicFirstDiscussionQuery(topicID: TopicID())))
            XCTFail("graph facts cannot replace failed transcript retrieval")
        } catch AskWorkflowError.transcript {
            // Expected: the released transcript lane remains authoritative.
        }
    }

    func testExistingEvidencePathNeverImplicitlyEntersGraphLane() async throws {
        let fixture = AskWorkflowFixture()
        let graph = AskGraphFactRetrievalFake(
            result: .abstained(.projectionNotReady))
        let useCase = AskMeetings(
            retrieval: AskMeetingRetrievalFake(
                searches: fixture.searches,
                citations: fixture.citations),
            answering: AskMeetingAnsweringFake(text: nil),
            graphFacts: graph)

        let citations = try await useCase.evidence("rollout")

        XCTAssertEqual(citations, fixture.citations)
        let graphCalls = await graph.calls
        XCTAssertTrue(graphCalls.isEmpty)
    }

    func testGraphCancellationCancelsTheCompleteEvidenceBundle() async throws {
        let fixture = AskWorkflowFixture()
        let useCase = AskMeetings(
            retrieval: AskMeetingRetrievalFake(
                searches: fixture.searches,
                citations: fixture.citations),
            answering: AskMeetingAnsweringFake(text: nil),
            graphFacts: AskGraphFactRetrievalFake(error: CancellationError()))

        do {
            _ = try await useCase.evidenceBundle(
                "rollout",
                graphQuery: .commitmentBlockers(
                    CommitmentBlockerQuery(commitmentID: CommitmentID())))
            XCTFail("graph cancellation must cancel the evidence request")
        } catch is CancellationError {
            // Expected: a cancelled lane cannot publish a partial final bundle.
        }
    }

    func testLocalGraphAdapterRoutesEveryExactQueryWithoutSynthesis() async throws {
        let repository = AskGraphFactRepositoryFake()
        let adapter = LocalAskGraphFactRetrieval(
            blockers: repository,
            topics: repository,
            commitments: repository)
        let queries: [AskGraphFactQuery] = [
            .commitmentBlockers(CommitmentBlockerQuery(
                commitmentID: CommitmentID(),
                itemLimit: 3)),
            .topicFirstDiscussion(TopicFirstDiscussionQuery(
                topicID: TopicID())),
            .personCommitments(PersonCommitmentsQuery(
                personID: PersonID(),
                itemLimit: 5)),
        ]

        for query in queries {
            let result = try await adapter.retrieve(query)
            XCTAssertEqual(result, .abstained(.projectionNotReady))
        }

        let calls = await repository.calls
        XCTAssertEqual(calls, queries)
    }

    func testWhitespaceAndNonPositiveLimitsDoNotEnterCapabilities() async throws {
        let retrieval = AskMeetingRetrievalFake(searches: [], citations: [])
        let answering = AskMeetingAnsweringFake(text: "unused")
        let useCase = AskMeetings(retrieval: retrieval, answering: answering)

        let searches = try await useCase.search("   ")
        let citations = try await useCase.evidence("question", limit: 0)
        XCTAssertTrue(searches.isEmpty)
        XCTAssertTrue(citations.isEmpty)
        let answer = try await useCase.answer("\n")

        XCTAssertTrue(answer.citations.isEmpty)
        let retrievalCalls = await retrieval.calls
        let answerCallCount = await answering.callCount
        XCTAssertTrue(retrievalCalls.isEmpty)
        XCTAssertEqual(answerCallCount, 0)
    }
}

private struct AskWorkflowFixture {
    let meetingID = MeetingID()
    let segmentID = UUID()

    var searches: [AskSearchResult] {
        [AskSearchResult(
            meetingID: meetingID,
            meetingTitle: "Planning",
            segmentID: segmentID,
            snippet: "rollout",
            timestamp: 3)]
    }

    var citations: [AskCitation] {
        [AskCitation(
            segmentID: segmentID,
            meetingID: meetingID,
            meetingTitle: "Planning",
            timestamp: 3,
            text: "El rollout queda para el viernes.")]
    }
}

private actor AskMeetingRetrievalFake: AskMeetingRetrieving {
    enum Call: Equatable {
        case search(String, Int)
        case retrieve(String, Int)
    }

    let searches: [AskSearchResult]
    let citations: [AskCitation]
    private(set) var calls: [Call] = []

    init(searches: [AskSearchResult], citations: [AskCitation]) {
        self.searches = searches
        self.citations = citations
    }

    func search(query: String, limit: Int) -> [AskSearchResult] {
        calls.append(.search(query, limit))
        return searches
    }

    func retrieve(question: String, limit: Int) -> [AskCitation] {
        calls.append(.retrieve(question, limit))
        return citations
    }
}

private struct FailingAskMeetingRetrievalFake: AskMeetingRetrieving {
    func search(query _: String, limit _: Int) -> [AskSearchResult] {
        []
    }

    func retrieve(
        question _: String,
        limit _: Int
    ) throws -> [AskCitation] {
        throw AskWorkflowError.transcript
    }
}

private actor AskMeetingAnsweringFake: AskMeetingAnswering {
    let text: String?
    let error: Error?
    private(set) var callCount = 0

    init(text: String? = nil, error: Error? = nil) {
        self.text = text
        self.error = error
    }

    func answer(
        question _: String,
        citations _: [AskCitation]
    ) throws -> String? {
        callCount += 1
        if let error { throw error }
        return text
    }
}

private actor ProgressiveAskMeetingRetrievalFake: AskMeetingRetrieving {
    let lexical: [AskCitation]
    let fused: [AskCitation]
    private var didPublishLexical = false
    private var fusionContinuation: CheckedContinuation<Void, Never>?

    init(lexical: [AskCitation], fused: [AskCitation]) {
        self.lexical = lexical
        self.fused = fused
    }

    func search(query _: String, limit _: Int) -> [AskSearchResult] {
        []
    }

    func retrieve(question _: String, limit _: Int) -> [AskCitation] {
        fused
    }

    func retrieve(
        question _: String,
        limit _: Int,
        trace _: AskPipelineTrace,
        onEvidence: @escaping AskEvidenceReceiver
    ) async -> [AskCitation] {
        await onEvidence(AskEvidenceUpdate(
            phase: .lexical,
            citations: lexical))
        didPublishLexical = true
        await withCheckedContinuation { continuation in
            fusionContinuation = continuation
        }
        await onEvidence(AskEvidenceUpdate(
            phase: .fused,
            citations: fused))
        return fused
    }

    func waitUntilLexicalEvidenceIsPublished() async {
        while !didPublishLexical {
            await Task.yield()
        }
    }

    func releaseFusion() {
        fusionContinuation?.resume()
        fusionContinuation = nil
    }
}

private actor AskEvidenceUpdateRecorder {
    private(set) var values: [AskEvidenceUpdate] = []

    func receive(_ update: AskEvidenceUpdate) {
        values.append(update)
    }
}

private actor AskGraphFactRetrievalFake: AskGraphFactRetrieving {
    let result: MeetingMemoryGraphQueryResult?
    let error: Error?
    private(set) var calls: [AskGraphFactQuery] = []

    init(
        result: MeetingMemoryGraphQueryResult? = nil,
        error: Error? = nil
    ) {
        self.result = result
        self.error = error
    }

    func retrieve(
        _ query: AskGraphFactQuery
    ) throws -> MeetingMemoryGraphQueryResult {
        calls.append(query)
        if let error { throw error }
        return result ?? .abstained(.projectionNotReady)
    }
}

private actor AskGraphFactRepositoryFake:
    CommitmentBlockerFactReading,
    TopicFirstDiscussionReading,
    PersonCommitmentFactReading {
    private(set) var calls: [AskGraphFactQuery] = []

    func commitmentBlockerFacts(
        _ query: CommitmentBlockerQuery
    ) -> MeetingMemoryGraphQueryResult {
        calls.append(.commitmentBlockers(query))
        return .abstained(.projectionNotReady)
    }

    func topicFirstDiscussion(
        _ query: TopicFirstDiscussionQuery
    ) -> MeetingMemoryGraphQueryResult {
        calls.append(.topicFirstDiscussion(query))
        return .abstained(.projectionNotReady)
    }

    func personCommitmentFacts(
        _ query: PersonCommitmentsQuery
    ) -> MeetingMemoryGraphQueryResult {
        calls.append(.personCommitments(query))
        return .abstained(.projectionNotReady)
    }
}

private enum AskWorkflowError: Error {
    case generation
    case graph
    case transcript
}
