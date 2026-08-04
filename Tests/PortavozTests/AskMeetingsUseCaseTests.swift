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
        let answerInputs = await answering.citationInputs
        XCTAssertEqual(answerCallCount, 1)
        XCTAssertEqual(answerInputs, [fixture.citations])
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

    func testAnswerBundleSendsTypedFactPageAndExactSourcesToOptInGeneration() async throws {
        let fixture = AskWorkflowFixture()
        let fact = graphFact(
            meetingID: fixture.meetingID,
            segmentID: fixture.segmentID)
        let page = graphPage(
            [fact],
            hasMore: true,
            omittedStaleCount: 2,
            omittedUnavailableCount: 1)
        let bundleAnswering = AskEvidenceBundleAnsweringFake(text: "El viernes.")
        let useCase = AskMeetings(
            retrieval: AskMeetingRetrievalFake(
                searches: fixture.searches,
                citations: fixture.citations),
            answering: AskMeetingAnsweringFake(text: nil),
            bundleAnswering: bundleAnswering,
            graphFacts: AskGraphFactRetrievalFake(result: .facts(page)))

        let result = try await useCase.answerBundle(
            "rollout",
            graphQuery: .personCommitments(PersonCommitmentsQuery(
                personID: PersonID())))

        XCTAssertEqual(result.generatedText, "El viernes.")
        XCTAssertEqual(result.evidence.transcriptCitations, fixture.citations)
        XCTAssertEqual(result.evidence.graphFacts, .result(.facts(page)))
        let inputs = await bundleAnswering.inputs
        XCTAssertEqual(inputs.count, 1)
        XCTAssertEqual(inputs[0].transcriptCitations, fixture.citations)
        guard case .facts(let synthesisPage) = inputs[0].graphFacts else {
            return XCTFail("typed graph facts must enter a separate synthesis lane")
        }
        XCTAssertTrue(synthesisPage.hasMore)
        XCTAssertEqual(synthesisPage.projectionGeneration, 7)
        XCTAssertEqual(synthesisPage.omittedStaleCount, 2)
        XCTAssertEqual(synthesisPage.omittedUnavailableCount, 1)
        XCTAssertFalse(synthesisPage.isComplete)
        XCTAssertEqual(synthesisPage.facts.map(\.fact), [fact])
        XCTAssertEqual(synthesisPage.facts[0].sourceSegments, [AskCitation(
            segmentID: fixture.segmentID,
            meetingID: fixture.meetingID,
            meetingTitle: "Planning",
            timestamp: 3,
            transcriptRevision: 0,
            text: "El rollout queda para el viernes.")])
    }

    func testInvalidGraphProvenanceFailsClosedWithoutTranscriptOnlyGeneration() async throws {
        let fixture = AskWorkflowFixture()
        let invalid = graphFact(
            meetingID: fixture.meetingID,
            segmentID: fixture.segmentID,
            primarySegmentID: UUID())
        let bundleAnswering = AskEvidenceBundleAnsweringFake(
            text: "must not be used")
        let useCase = AskMeetings(
            retrieval: AskMeetingRetrievalFake(
                searches: fixture.searches,
                citations: fixture.citations),
            answering: AskMeetingAnsweringFake(text: "Transcript only."),
            bundleAnswering: bundleAnswering,
            graphFacts: AskGraphFactRetrievalFake(
                result: .facts(graphPage([invalid]))))

        let result = try await useCase.answerBundle(
            "rollout",
            graphQuery: .topicFirstDiscussion(TopicFirstDiscussionQuery(
                topicID: TopicID())))

        XCTAssertNil(result.generatedText)
        XCTAssertEqual(result.evidence.synthesisInput.graphFacts, .invalidEvidence)
        let callCount = await bundleAnswering.callCount
        XCTAssertEqual(callCount, 0)
    }

    func testGraphFactsNeverReplaceEmptyTranscriptEvidence() async throws {
        let fixture = AskWorkflowFixture()
        let fact = graphFact(
            meetingID: fixture.meetingID,
            segmentID: fixture.segmentID)
        let bundleAnswering = AskEvidenceBundleAnsweringFake(
            text: "must not be used")
        let useCase = AskMeetings(
            retrieval: AskMeetingRetrievalFake(searches: [], citations: []),
            answering: AskMeetingAnsweringFake(text: nil),
            bundleAnswering: bundleAnswering,
            graphFacts: AskGraphFactRetrievalFake(
                result: .facts(graphPage([fact]))))

        let result = try await useCase.answerBundle(
            "when",
            graphQuery: .personCommitments(PersonCommitmentsQuery(
                personID: PersonID())))

        XCTAssertNil(result.generatedText)
        XCTAssertFalse(result.evidence.synthesisInput.isFactAwareGenerationReady)
        let callCount = await bundleAnswering.callCount
        XCTAssertEqual(callCount, 0)
    }

    func testGraphAbstentionWithTranscriptEvidenceSkipsFactAwareGeneration() async throws {
        let fixture = AskWorkflowFixture()
        let bundleAnswering = AskEvidenceBundleAnsweringFake(
            text: "must not be used")
        let useCase = AskMeetings(
            retrieval: AskMeetingRetrievalFake(
                searches: fixture.searches,
                citations: fixture.citations),
            answering: AskMeetingAnsweringFake(text: nil),
            bundleAnswering: bundleAnswering,
            graphFacts: AskGraphFactRetrievalFake(
                result: .abstained(.noMatchingFacts)))

        let result = try await useCase.answerBundle(
            "when",
            graphQuery: .topicFirstDiscussion(TopicFirstDiscussionQuery(
                topicID: TopicID())))

        XCTAssertNil(result.generatedText)
        XCTAssertEqual(
            result.evidence.synthesisInput.graphFacts,
            .abstained(.noMatchingFacts))
        let callCount = await bundleAnswering.callCount
        XCTAssertEqual(callCount, 0)
    }

    func testBundleGenerationFailureKeepsBothEvidenceLanes() async throws {
        let fixture = AskWorkflowFixture()
        let page = graphPage([graphFact(
            meetingID: fixture.meetingID,
            segmentID: fixture.segmentID)])
        let useCase = AskMeetings(
            retrieval: AskMeetingRetrievalFake(
                searches: fixture.searches,
                citations: fixture.citations),
            answering: AskMeetingAnsweringFake(text: nil),
            bundleAnswering: AskEvidenceBundleAnsweringFake(
                error: AskWorkflowError.generation),
            graphFacts: AskGraphFactRetrievalFake(result: .facts(page)))

        let result = try await useCase.answerBundle(
            "when",
            graphQuery: .personCommitments(PersonCommitmentsQuery(
                personID: PersonID())))

        XCTAssertNil(result.generatedText)
        XCTAssertEqual(result.evidence.transcriptCitations, fixture.citations)
        XCTAssertEqual(result.evidence.graphFacts, .result(.facts(page)))
    }

    func testBundleGenerationCancellationPropagates() async throws {
        let fixture = AskWorkflowFixture()
        let page = graphPage([graphFact(
            meetingID: fixture.meetingID,
            segmentID: fixture.segmentID)])
        let useCase = AskMeetings(
            retrieval: AskMeetingRetrievalFake(
                searches: fixture.searches,
                citations: fixture.citations),
            answering: AskMeetingAnsweringFake(text: nil),
            bundleAnswering: AskEvidenceBundleAnsweringFake(
                error: CancellationError()),
            graphFacts: AskGraphFactRetrievalFake(result: .facts(page)))

        do {
            _ = try await useCase.answerBundle(
                "when",
                graphQuery: .personCommitments(PersonCommitmentsQuery(
                    personID: PersonID())))
            XCTFail("fact-aware generation cancellation must propagate")
        } catch is CancellationError {
            // Expected: callers discard the cancelled bundle answer.
        }
    }

    func testBundleCancellationAfterGenerationDoesNotPublishLateAnswer() async throws {
        let fixture = AskWorkflowFixture()
        let page = graphPage([graphFact(
            meetingID: fixture.meetingID,
            segmentID: fixture.segmentID)])
        let bundleAnswering = BlockingAskEvidenceBundleAnsweringFake()
        let useCase = AskMeetings(
            retrieval: AskMeetingRetrievalFake(
                searches: fixture.searches,
                citations: fixture.citations),
            answering: AskMeetingAnsweringFake(text: nil),
            bundleAnswering: bundleAnswering,
            graphFacts: AskGraphFactRetrievalFake(result: .facts(page)))
        let task = Task {
            try await useCase.answerBundle(
                "when",
                graphQuery: .personCommitments(PersonCommitmentsQuery(
                    personID: PersonID())))
        }
        await bundleAnswering.waitUntilStarted()

        task.cancel()
        await bundleAnswering.release()

        do {
            _ = try await task.value
            XCTFail("a cancelled bundle answer must not publish late output")
        } catch is CancellationError {
            // Expected: the post-generation cancellation checkpoint wins.
        }
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

private func graphFact(
    meetingID: MeetingID,
    segmentID: UUID,
    primarySegmentID: UUID? = nil,
    transcriptRevision: Int = 0
) -> MeetingMemoryGraphFact {
    let commitmentID = CommitmentID()
    return MeetingMemoryGraphFact(
        id: .commitment(commitmentID),
        kind: .personCommittedTo,
        subject: .person(PersonID()),
        object: .commitment(commitmentID),
        subjectText: "Mara",
        objectText: "Ship rollout",
        status: .active,
        occurredAt: Date(timeIntervalSince1970: 1_000),
        evidence: [MeetingMemoryGraphEvidence(
            meetingID: meetingID,
            meetingTitle: "Planning",
            meetingStartedAt: Date(timeIntervalSince1970: 997),
            transcriptRevision: transcriptRevision,
            segmentID: segmentID,
            startTime: 3,
            endTime: 5,
            text: "El rollout queda para el viernes.",
            language: "es")],
        primaryEvidenceSegmentID: primarySegmentID ?? segmentID)
}

private func graphPage(
    _ facts: [MeetingMemoryGraphFact],
    hasMore: Bool = false,
    omittedStaleCount: Int = 0,
    omittedUnavailableCount: Int = 0
) -> MeetingMemoryGraphFactPage {
    MeetingMemoryGraphFactPage(
        facts: facts,
        hasMore: hasMore,
        projectionGeneration: 7,
        omittedStaleCount: omittedStaleCount,
        omittedUnavailableCount: omittedUnavailableCount)
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
    private(set) var citationInputs: [[AskCitation]] = []

    init(text: String? = nil, error: Error? = nil) {
        self.text = text
        self.error = error
    }

    func answer(
        question _: String,
        citations: [AskCitation]
    ) throws -> String? {
        callCount += 1
        citationInputs.append(citations)
        if let error { throw error }
        return text
    }
}

private actor AskEvidenceBundleAnsweringFake: AskEvidenceBundleAnswering {
    let text: String?
    let error: Error?
    private(set) var callCount = 0
    private(set) var inputs: [AskSynthesisInput] = []

    init(text: String? = nil, error: Error? = nil) {
        self.text = text
        self.error = error
    }

    func answer(
        question _: String,
        evidence: AskSynthesisInput
    ) throws -> String? {
        callCount += 1
        inputs.append(evidence)
        if let error { throw error }
        return text
    }
}

private actor BlockingAskEvidenceBundleAnsweringFake: AskEvidenceBundleAnswering {
    private var started = false
    private var continuation: CheckedContinuation<Void, Never>?

    func answer(
        question _: String,
        evidence _: AskSynthesisInput
    ) async -> String? {
        started = true
        await withCheckedContinuation { continuation = $0 }
        return "late answer"
    }

    func waitUntilStarted() async {
        while !started {
            await Task.yield()
        }
    }

    func release() {
        continuation?.resume()
        continuation = nil
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
