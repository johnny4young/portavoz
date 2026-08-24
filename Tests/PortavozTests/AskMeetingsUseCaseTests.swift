import ApplicationKit
import Foundation
import PortavozCore
import XCTest

final class AskMeetingsUseCaseTests: XCTestCase {
    func testWebScopeFailsClosedBeforeAnyMeetingCapabilityRuns() async throws {
        let retrieval = AskMeetingRetrievalFake(searches: [], citations: [])
        let answering = AskMeetingAnsweringFake(text: "must not run")
        let useCase = AskMeetings(retrieval: retrieval, answering: answering)

        do {
            _ = try await useCase.answer("rollout", source: .web)
            XCTFail("web must remain unavailable until its explicit adapter exists")
        } catch let error as AskSourcePolicyError {
            XCTAssertEqual(error, .webUnavailable)
        }

        let retrievalCalls = await retrieval.calls
        let answerCallCount = await answering.callCount
        XCTAssertTrue(retrievalCalls.isEmpty)
        XCTAssertEqual(answerCallCount, 0)
    }

    func testMeetingScopeCannotFallBackToAnUnscopedRetriever() async throws {
        let retrieval = AskMeetingRetrievalFake(searches: [], citations: [])
        let useCase = AskMeetings(
            retrieval: retrieval,
            answering: AskMeetingAnsweringFake(text: "must not run"))

        do {
            _ = try await useCase.answer(
                "rollout",
                source: .meeting(MeetingID()))
            XCTFail("an adapter without exact meeting authority must fail closed")
        } catch let error as AskSourcePolicyError {
            XCTAssertEqual(error, .meetingScopeUnavailable)
        }

        let retrievalCalls = await retrieval.calls
        XCTAssertTrue(retrievalCalls.isEmpty)
    }

    func testExactMeetingScopeReachesOnlyTheScopedRetriever() async throws {
        let fixture = AskWorkflowFixture()
        let retrieval = ScopedAskMeetingRetrievalFake(citations: fixture.citations)
        let useCase = AskMeetings(
            retrieval: retrieval,
            answering: AskMeetingAnsweringFake(text: "El viernes."))
        let source = AskSourceScope.meeting(fixture.meetingID)

        let result = try await useCase.answer("rollout", source: source)

        XCTAssertEqual(result.citations, fixture.citations)
        let sources = await retrieval.sources
        let unscopedCallCount = await retrieval.unscopedCallCount
        XCTAssertEqual(sources, [source])
        XCTAssertEqual(unscopedCallCount, 0)
    }

    func testMeetingScopeRejectsForeignSearchAndProgressiveEvidence() async throws {
        let foreign = AskWorkflowFixture()
        let target = MeetingID()
        let retrieval = ScopedAskMeetingRetrievalFake(
            searches: foreign.searches,
            citations: foreign.citations)
        let answering = AskMeetingAnsweringFake(text: "must not run")
        let updates = AskEvidenceUpdateRecorder()
        let useCase = AskMeetings(retrieval: retrieval, answering: answering)

        do {
            _ = try await useCase.search(
                "rollout",
                source: .meeting(target))
            XCTFail("foreign scoped search results must fail closed")
        } catch let error as AskSourcePolicyError {
            XCTAssertEqual(error, .sourceEvidenceMismatch)
        }

        do {
            _ = try await useCase.answer(
                "rollout",
                source: .meeting(target),
                onEvidence: { update in await updates.receive(update) })
            XCTFail("foreign progressive evidence must fail closed")
        } catch let error as AskSourcePolicyError {
            XCTAssertEqual(error, .sourceEvidenceMismatch)
        }

        let published = await updates.values
        let answerCallCount = await answering.callCount
        XCTAssertTrue(published.isEmpty)
        XCTAssertEqual(answerCallCount, 0)
    }

    func testGraphFactsRejectMeetingScopeBeforeEitherLaneRuns() async throws {
        let fixture = AskWorkflowFixture()
        let retrieval = ScopedAskMeetingRetrievalFake(citations: fixture.citations)
        let graph = AskGraphFactRetrievalFake(result: .abstained(.noMatchingFacts))
        let useCase = AskMeetings(
            retrieval: retrieval,
            answering: AskMeetingAnsweringFake(text: nil),
            graphFacts: graph)

        do {
            _ = try await useCase.evidenceBundle(
                "rollout",
                source: .meeting(fixture.meetingID),
                graphQuery: .personCommitments(PersonCommitmentsQuery(
                    personID: PersonID())))
            XCTFail("library graph facts must not widen one-meeting scope")
        } catch let error as AskSourcePolicyError {
            XCTAssertEqual(error, .graphFactsRequireLibrary)
        }

        let sources = await retrieval.sources
        let graphCalls = await graph.calls
        XCTAssertTrue(sources.isEmpty)
        XCTAssertTrue(graphCalls.isEmpty)
    }

    func testSearchEvidenceAndAnswerShareOneTrimmedWorkflow() async throws {
        let fixture = AskWorkflowFixture()
        let retrieval = AskMeetingRetrievalFake(
            searches: fixture.searches,
            citations: fixture.citations)
        let answering = AskMeetingAnsweringFake(text: "El viernes.")
        let useCase = AskMeetings(retrieval: retrieval, answering: answering)

        let searches = try await useCase.search("  rollout  ", source: .library, limit: 4)
        let citations = try await useCase.evidence("  rollout  ", source: .library, limit: 5)
        let answer = try await useCase.answer("  rollout  ", source: .library, limit: 6)

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

        let result = try await useCase.answer("unknown", source: .library)

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

        let result = try await useCase.answer("rollout", source: .library)

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
            _ = try await useCase.answer("rollout", source: .library)
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
                source: .library,
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

    func testProgressiveAnswerCoalescesCumulativeSnapshotsAndKeepsExactFinalText() async throws {
        let fixture = AskWorkflowFixture()
        let finalText = "El presupuesto se revisó y quedó para el viernes."
        let updates = AskAnswerUpdateRecorder()
        let useCase = AskMeetings(
            retrieval: AskMeetingRetrievalFake(
                searches: fixture.searches,
                citations: fixture.citations),
            answering: CharacterStreamingAskAnswerer(text: finalText))

        let result = try await useCase.answer(
            "rollout",
            source: .library,
            onEvidence: { _ in },
            onAnswer: { update in await updates.receive(update) })
        let values = await updates.values.map(\.text)

        XCTAssertEqual(result.generatedText, finalText)
        XCTAssertEqual(result.generationOutcome, .generated)
        XCTAssertEqual(values.last, finalText)
        XCTAssertLessThanOrEqual(values.count, 4)
        XCTAssertTrue(zip(values, values.dropFirst()).allSatisfy { previous, next in
            next.hasPrefix(previous)
        })
    }

    func testGenerationTimeoutPreservesEvidenceAndRejectsLateSnapshots() async throws {
        let fixture = AskWorkflowFixture()
        let updates = AskAnswerUpdateRecorder()
        let useCase = AskMeetings(
            retrieval: AskMeetingRetrievalFake(
                searches: fixture.searches,
                citations: fixture.citations),
            answering: CancellationIgnoringAskAnswerer(),
            answerTimeout: .milliseconds(20))

        let result = try await useCase.answer(
            "rollout",
            source: .library,
            onEvidence: { _ in },
            onAnswer: { update in await updates.receive(update) })

        XCTAssertEqual(result.citations, fixture.citations)
        XCTAssertNil(result.generatedText)
        XCTAssertEqual(result.generationOutcome, .timedOut)
        let published = await updates.values.map(\.text)
        XCTAssertEqual(published, ["El presupuesto"])
    }

    func testMalformedProgressiveAnswersFailClosed() async throws {
        let fixture = AskWorkflowFixture()
        let useCase = AskMeetings(
            retrieval: AskMeetingRetrievalFake(
                searches: fixture.searches,
                citations: fixture.citations),
            answering: NonMonotonicAskAnswerer())

        let result = try await useCase.answer("rollout", source: .library)

        XCTAssertEqual(result.citations, fixture.citations)
        XCTAssertNil(result.generatedText)
        XCTAssertEqual(result.generationOutcome, .failed)
    }

    func testOversizedAnswerFailsClosedWithoutPublishingSnapshots() async throws {
        let fixture = AskWorkflowFixture()
        let updates = AskAnswerUpdateRecorder()
        let useCase = AskMeetings(
            retrieval: AskMeetingRetrievalFake(
                searches: fixture.searches,
                citations: fixture.citations),
            answering: OversizedAskAnswerer())

        let result = try await useCase.answer(
            "rollout",
            source: .library,
            onEvidence: { _ in },
            onAnswer: { update in await updates.receive(update) })

        XCTAssertNil(result.generatedText)
        XCTAssertEqual(result.generationOutcome, .failed)
        let published = await updates.values
        XCTAssertTrue(published.isEmpty)
    }

    func testOversizedCitationProvenanceFailsClosedBeforeGeneration() async throws {
        let fixture = AskWorkflowFixture()
        let answering = AskMeetingAnsweringFake(text: "must not run")
        let citation = AskCitation(
            segmentID: fixture.segmentID,
            sourceSegmentIDs: (0...AskRequestLimits.maximumSourceSegmentsPerCitation)
                .map { _ in UUID() },
            meetingID: fixture.meetingID,
            meetingTitle: "Planning",
            timestamp: 7,
            text: "The rollout stays scheduled for Friday.")
        let useCase = AskMeetings(
            retrieval: AskMeetingRetrievalFake(
                searches: fixture.searches,
                citations: [citation]),
            answering: answering)

        do {
            _ = try await useCase.answer("rollout", source: .library)
            XCTFail("oversized citation provenance must fail closed")
        } catch {
            // The evidence cannot cross the bounded application contract.
        }
        let answerCallCount = await answering.callCount
        XCTAssertEqual(answerCallCount, 0)
    }

    func testProgressiveEvidenceMustMatchTheReturnedFusedEvidence() async throws {
        let fixture = AskWorkflowFixture()
        let answering = AskMeetingAnsweringFake(text: "must not run")
        let useCase = AskMeetings(
            retrieval: MismatchedProgressiveAskRetrieval(
                emitted: fixture.citations,
                returned: [AskCitation(
                    segmentID: UUID(),
                    meetingID: fixture.meetingID,
                    meetingTitle: "Planning",
                    timestamp: 7,
                    text: "Different evidence.")]),
            answering: answering)

        do {
            _ = try await useCase.answer("rollout", source: .library)
            XCTFail("mismatched fused evidence must fail closed")
        } catch {
            // The progressive provider violated its application contract.
        }
        let callCount = await answering.callCount
        XCTAssertEqual(callCount, 0)
    }

    func testOversizedRequestsAreRejectedBeforeCapabilitiesRun() async throws {
        let retrieval = AskMeetingRetrievalFake(searches: [], citations: [])
        let answering = AskMeetingAnsweringFake(text: "unused")
        let useCase = AskMeetings(retrieval: retrieval, answering: answering)
        let oversized = String(
            repeating: "a",
            count: AskRequestLimits.maximumQuestionCharacters + 1)

        do {
            _ = try await useCase.search(oversized, source: .library)
            XCTFail("oversized question must be rejected")
        } catch AskRequestError.questionTooLong {}
        do {
            _ = try await useCase.evidence(
                "valid",
                source: .library,
                limit: AskRequestLimits.maximumResultCount + 1)
            XCTFail("oversized limit must be rejected")
        } catch AskRequestError.resultLimitExceeded {}

        let retrievalCalls = await retrieval.calls
        let answerCallCount = await answering.callCount
        XCTAssertTrue(retrievalCalls.isEmpty)
        XCTAssertEqual(answerCallCount, 0)
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
            source: .library,
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
            source: .library,
            graphQuery: .personCommitments(PersonCommitmentsQuery(
                personID: PersonID())))

        XCTAssertEqual(result.generatedText, "El viernes.")
        XCTAssertEqual(result.evidence.transcriptCitations, fixture.citations)
        XCTAssertEqual(result.evidence.graphFacts, .result(.facts(page)))
        let inputs = await bundleAnswering.inputs
        XCTAssertEqual(inputs.count, 1)
        XCTAssertEqual(inputs[0].transcriptCitations, fixture.citations)
        XCTAssertEqual(inputs[0].selection,
                       AskFactAwareSelectionDisclosure(
                           transcriptCandidateCount: 1,
                           selectedTranscriptCount: 1,
                           graphFactCandidateCount: 1,
                           selectedGraphFactCount: 1,
                           additionalGraphSourceCount: 0,
                           omittedGraphFactCount: 0))
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

    func testAnswerBundleSelectsBoundedPrefixesButReturnsFullEvidence() async throws {
        let fixture = AskWorkflowFixture()
        let citations = (0..<8).map { index in
            AskCitation(
                segmentID: UUID(),
                meetingID: fixture.meetingID,
                meetingTitle: "Planning",
                timestamp: TimeInterval(index),
                transcriptRevision: 0,
                text: "Transcript candidate \(index)")
        }
        let facts = (0..<6).map { _ in
            graphFact(
                meetingID: fixture.meetingID,
                segmentID: UUID())
        }
        let page = graphPage(facts)
        let bundleAnswering = AskEvidenceBundleAnsweringFake(text: "Bounded.")
        let useCase = AskMeetings(
            retrieval: AskMeetingRetrievalFake(
                searches: fixture.searches,
                citations: citations),
            answering: AskMeetingAnsweringFake(text: nil),
            bundleAnswering: bundleAnswering,
            graphFacts: AskGraphFactRetrievalFake(result: .facts(page)))

        let result = try await useCase.answerBundle(
            "rollout",
            source: .library,
            graphQuery: .personCommitments(PersonCommitmentsQuery(
                personID: PersonID())))

        XCTAssertEqual(result.generatedText, "Bounded.")
        XCTAssertEqual(result.evidence.transcriptCitations, citations)
        XCTAssertEqual(result.evidence.graphFacts, .result(.facts(page)))
        let inputs = await bundleAnswering.inputs
        XCTAssertEqual(inputs.count, 1)
        XCTAssertEqual(
            inputs[0].transcriptCitations,
            Array(citations.prefix(6)))
        guard case .facts(let selectedPage) = inputs[0].graphFacts else {
            return XCTFail("the selected graph prefix must remain typed")
        }
        XCTAssertEqual(
            selectedPage.facts.map(\.fact),
            Array(facts.prefix(4)))
        XCTAssertEqual(selectedPage.selectionOmittedCount, 2)
        XCTAssertEqual(inputs[0].selection,
                       AskFactAwareSelectionDisclosure(
                           transcriptCandidateCount: 8,
                           selectedTranscriptCount: 6,
                           graphFactCandidateCount: 6,
                           selectedGraphFactCount: 4,
                           additionalGraphSourceCount: 4,
                           omittedGraphFactCount: 2))
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
            source: .library,
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
            source: .library,
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
            source: .library,
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
            source: .library,
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
                source: .library,
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
                source: .library,
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
            source: .library,
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

        let result = try await useCase.evidenceBundle("rollout", source: .library)

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
                source: .library,
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

        let citations = try await useCase.evidence("rollout", source: .library)

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
                source: .library,
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
            commitments: repository,
            conflicts: repository,
            changes: repository,
            history: repository)
        let queries: [AskGraphFactQuery] = [
            .commitmentBlockers(CommitmentBlockerQuery(
                commitmentID: CommitmentID(),
                itemLimit: 3)),
            .topicFirstDiscussion(TopicFirstDiscussionQuery(
                topicID: TopicID())),
            .personCommitments(PersonCommitmentsQuery(
                personID: PersonID(),
                itemLimit: 5)),
            .decisionConflicts(DecisionConflictsQuery(
                topicID: TopicID(),
                itemLimit: 4)),
            .changeSince(ChangeSinceQuery(
                topicID: TopicID(),
                sinceMeetingID: MeetingID(),
                itemLimit: 6)),
            .decisionHistory(DecisionHistoryQuery(
                topicID: TopicID(),
                itemLimit: 7)),
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

        let searches = try await useCase.search("   ", source: .library)
        let citations = try await useCase.evidence("question", source: .library, limit: 0)
        XCTAssertTrue(searches.isEmpty)
        XCTAssertTrue(citations.isEmpty)
        let answer = try await useCase.answer("\n", source: .library)

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

private actor ScopedAskMeetingRetrievalFake: AskMeetingRetrieving {
    let searches: [AskSearchResult]
    let citations: [AskCitation]
    private(set) var sources: [AskSourceScope] = []
    private(set) var unscopedCallCount = 0

    init(
        searches: [AskSearchResult] = [],
        citations: [AskCitation]
    ) {
        self.searches = searches
        self.citations = citations
    }

    func search(query _: String, limit _: Int) -> [AskSearchResult] {
        unscopedCallCount += 1
        return []
    }

    func retrieve(question _: String, limit _: Int) -> [AskCitation] {
        unscopedCallCount += 1
        return []
    }

    func search(
        query _: String,
        source: AskSourceScope,
        limit _: Int,
        trace _: AskPipelineTrace
    ) -> [AskSearchResult] {
        sources.append(source)
        return searches
    }

    func retrieve(
        question _: String,
        source: AskSourceScope,
        limit _: Int,
        trace _: AskPipelineTrace,
        onEvidence: @escaping AskEvidenceReceiver
    ) async -> [AskCitation] {
        sources.append(source)
        await onEvidence(AskEvidenceUpdate(phase: .fused, citations: citations))
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

private actor AskAnswerUpdateRecorder {
    private(set) var values: [AskAnswerUpdate] = []

    func receive(_ update: AskAnswerUpdate) {
        values.append(update)
    }
}

private struct CharacterStreamingAskAnswerer: AskMeetingAnswering {
    let text: String

    func answer(
        question _: String,
        citations _: [AskCitation]
    ) -> String? {
        text
    }

    func answer(
        question _: String,
        citations _: [AskCitation],
        onAnswer: @escaping AskAnswerReceiver
    ) async -> String? {
        for index in 1...text.count {
            await onAnswer(AskAnswerUpdate(text: String(text.prefix(index))))
        }
        return text
    }
}

private struct CancellationIgnoringAskAnswerer: AskMeetingAnswering {
    func answer(
        question _: String,
        citations _: [AskCitation]
    ) -> String? {
        nil
    }

    func answer(
        question _: String,
        citations _: [AskCitation],
        onAnswer: @escaping AskAnswerReceiver
    ) async -> String? {
        await onAnswer(AskAnswerUpdate(text: "El presupuesto"))
        do {
            try await Task.sleep(for: .seconds(1))
        } catch {
            await onAnswer(AskAnswerUpdate(text: "late cancelled output"))
        }
        return "late cancelled output"
    }
}

private struct NonMonotonicAskAnswerer: AskMeetingAnswering {
    func answer(
        question _: String,
        citations _: [AskCitation]
    ) -> String? {
        nil
    }

    func answer(
        question _: String,
        citations _: [AskCitation],
        onAnswer: @escaping AskAnswerReceiver
    ) async -> String? {
        await onAnswer(AskAnswerUpdate(text: "El viernes."))
        await onAnswer(AskAnswerUpdate(text: "El jueves."))
        return "El jueves."
    }
}

private struct OversizedAskAnswerer: AskMeetingAnswering {
    private var oversized: String {
        String(
            repeating: "x",
            count: AskRequestLimits.maximumAnswerCharacters + 1)
    }

    func answer(
        question _: String,
        citations _: [AskCitation]
    ) -> String? {
        oversized
    }

    func answer(
        question _: String,
        citations _: [AskCitation],
        onAnswer: @escaping AskAnswerReceiver
    ) async -> String? {
        await onAnswer(AskAnswerUpdate(text: oversized))
        return oversized
    }
}

private struct MismatchedProgressiveAskRetrieval: AskMeetingRetrieving {
    let emitted: [AskCitation]
    let returned: [AskCitation]

    func search(query _: String, limit _: Int) -> [AskSearchResult] { [] }

    func retrieve(
        question _: String,
        limit _: Int
    ) -> [AskCitation] {
        returned
    }

    func retrieve(
        question _: String,
        limit _: Int,
        trace _: AskPipelineTrace,
        onEvidence: @escaping AskEvidenceReceiver
    ) async -> [AskCitation] {
        await onEvidence(AskEvidenceUpdate(phase: .fused, citations: emitted))
        return returned
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
    PersonCommitmentFactReading,
    DecisionConflictsReading,
    ChangeSinceReading,
    DecisionHistoryReading {
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

    func decisionConflicts(
        _ query: DecisionConflictsQuery
    ) -> MeetingMemoryGraphQueryResult {
        calls.append(.decisionConflicts(query))
        return .abstained(.projectionNotReady)
    }

    func changeSince(
        _ query: ChangeSinceQuery
    ) -> MeetingMemoryGraphQueryResult {
        calls.append(.changeSince(query))
        return .abstained(.projectionNotReady)
    }

    func decisionHistory(
        _ query: DecisionHistoryQuery
    ) -> MeetingMemoryGraphQueryResult {
        calls.append(.decisionHistory(query))
        return .abstained(.projectionNotReady)
    }
}

private enum AskWorkflowError: Error {
    case generation
    case graph
    case transcript
}
