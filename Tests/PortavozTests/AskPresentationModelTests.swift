import ApplicationKit
import Foundation
import PortavozCore
import XCTest

@testable import portavoz_app

@MainActor
final class AskPresentationModelTests: XCTestCase {
    func testFullAskOwnsDraftAnswerAndEvidenceFallbackPresentation() async throws {
        let fixture = AskPresentationFixture()
        let client = ControlledAskModelClient()
        let model = AskModel(client: client)

        model.updateDraft("  presupuesto  ")
        model.submit()
        try await waitUntil { client.answerRequests == ["presupuesto"] }
        client.completeAnswer(
            "presupuesto",
            with: AskMeetingAnswer(
                question: "presupuesto",
                generatedText: nil,
                citations: [fixture.citation]))
        try await waitUntil { model.state.exchanges.count == 1 }

        XCTAssertEqual(model.state.draft, "")
        XCTAssertFalse(model.state.isAsking)
        XCTAssertEqual(model.state.exchanges.first?.question, "presupuesto")
        XCTAssertEqual(
            model.state.exchanges.first?.answer,
            L10n.text("Closest passages from your meetings:"))
        XCTAssertEqual(model.state.exchanges.first?.citations, [fixture.citation])
    }

    func testFullAskPublishesProgressiveEvidenceThenFencesFinalAnswer() async throws {
        let fixture = AskPresentationFixture()
        let client = ControlledAskModelClient()
        let model = AskModel(client: client)

        model.updateDraft("presupuesto")
        model.submit()
        XCTAssertEqual(model.state.pendingPhase, .findingEvidence)
        try await waitUntil { client.answerRequests == ["presupuesto"] }

        await client.publishEvidence(
            "presupuesto",
            update: AskEvidenceUpdate(
                phase: .lexical,
                citations: [fixture.citation]))
        try await waitUntil { model.state.pendingPhase == .refiningEvidence }
        XCTAssertEqual(model.state.pendingCitations, [fixture.citation])

        await client.publishEvidence(
            "presupuesto",
            update: AskEvidenceUpdate(
                phase: .fused,
                citations: [fixture.citation]))
        try await waitUntil { model.state.pendingPhase == .generatingAnswer }

        client.completeAnswer(
            "presupuesto",
            with: AskMeetingAnswer(
                question: "presupuesto",
                generatedText: "El viernes.",
                citations: [fixture.citation]))
        try await waitUntil { model.state.exchanges.count == 1 }

        XCTAssertFalse(model.state.isAsking)
        XCTAssertNil(model.state.pendingQuestion)
        XCTAssertNil(model.state.pendingPhase)
        XCTAssertEqual(model.state.pendingCitations, [])
        XCTAssertEqual(model.state.exchanges.first?.answer, "El viernes.")
    }

    func testFullAskCancellationRejectsLateProgressAndCompletion() async throws {
        let fixture = AskPresentationFixture()
        let client = ControlledAskModelClient()
        let model = AskModel(client: client)

        model.updateDraft("old")
        model.submit()
        try await waitUntil { client.answerRequests == ["old"] }
        await client.publishEvidence(
            "old",
            update: AskEvidenceUpdate(
                phase: .lexical,
                citations: [fixture.citation]))
        try await waitUntil { model.state.pendingPhase == .refiningEvidence }

        model.cancelPendingAnswer()
        await client.publishEvidence(
            "old",
            update: AskEvidenceUpdate(
                phase: .fused,
                citations: [fixture.citation]))
        client.completeAnswer(
            "old",
            with: AskMeetingAnswer(
                question: "old",
                generatedText: "stale",
                citations: [fixture.citation]))
        await Task.yield()

        XCTAssertFalse(model.state.isAsking)
        XCTAssertNil(model.state.pendingQuestion)
        XCTAssertNil(model.state.pendingPhase)
        XCTAssertTrue(model.state.pendingCitations.isEmpty)
        XCTAssertTrue(model.state.exchanges.isEmpty)
    }

    func testMemoryPersonSearchPublishesOnlyLatestBoundedExactCandidates() async throws {
        let ask = ControlledAskModelClient()
        let memory = ControlledAskMemoryModelClient()
        let model = AskModel(
            client: ask,
            memoryClient: memory,
            memorySearchDelay: .zero)
        let memoryModel = try XCTUnwrap(model.memory)

        model.selectSurface(.personCommitments)
        try await waitUntil { memory.peopleRequests == [""] }
        XCTAssertEqual(memory.peopleLimits, [21])
        memoryModel.updatePersonQuery("Ana")
        try await waitUntil { memory.peopleRequests == ["", "Ana"] }
        XCTAssertEqual(memory.peopleLimits, [21, 21])

        let stale = Person(preferredName: "Stale person")
        memory.completePeople("", with: [stale])
        await Task.yield()
        XCTAssertEqual(memoryModel.state.peoplePhase, .loading)
        XCTAssertTrue(memoryModel.state.people.isEmpty)

        let candidates = (0..<21).map {
            Person(preferredName: "Ana \($0 + 1)")
        }
        memory.completePeople("Ana", with: candidates)
        try await waitUntil { memoryModel.state.peoplePhase == .ready }

        XCTAssertEqual(memoryModel.state.people.count, 20)
        XCTAssertEqual(
            memoryModel.state.people.map(\.id),
            candidates.prefix(20).map(\.id))
        XCTAssertTrue(memoryModel.state.peopleHasMore)

        memoryModel.selectPerson(candidates[3].id)
        XCTAssertEqual(memoryModel.state.selectedPerson?.id, candidates[3].id)
        XCTAssertEqual(memoryModel.state.personQuery, "Ana 4")
        XCTAssertTrue(memoryModel.state.people.isEmpty)
    }

    func testMemoryPersonSearchFailsClosedForAnOversizedCatalogResponse() async throws {
        let memory = ControlledAskMemoryModelClient()
        let model = AskMemoryModel(
            client: memory,
            searchDelay: .zero)

        model.activate()
        try await waitUntil { memory.peopleRequests == [""] }
        memory.completePeople(
            "",
            with: (0..<22).map { Person(preferredName: "Person \($0)") })
        try await waitUntil { model.state.peoplePhase == .unavailable }

        XCTAssertTrue(model.state.people.isEmpty)
        XCTAssertFalse(model.state.peopleHasMore)
    }

    func testMemoryPersonCommitmentsExposeOnlyExactTypedEvidence() async throws {
        let fixture = AskMemoryPresentationFixture()
        let ask = ControlledAskModelClient()
        let memory = ControlledAskMemoryModelClient()
        let model = AskModel(
            client: ask,
            memoryClient: memory,
            memorySearchDelay: .zero)
        let memoryModel = try XCTUnwrap(model.memory)

        model.selectSurface(.personCommitments)
        try await waitUntil { memory.peopleRequests == [""] }
        memory.completePeople("", with: [fixture.person])
        try await waitUntil { memoryModel.state.peoplePhase == .ready }
        memoryModel.selectPerson(fixture.person.id)
        memoryModel.loadSelectedPersonCommitments()
        try await waitUntil {
            memory.commitmentRequests == [fixture.person.id]
        }
        XCTAssertEqual(memory.commitmentLimits, [100])
        memory.completeCommitments(
            for: fixture.person.id,
            with: .facts(fixture.page()))
        try await waitUntil {
            if case .facts = memoryModel.state.outcome { return true }
            return false
        }

        guard case .facts(let values, let disclosure) = memoryModel.state.outcome
        else { return XCTFail("Expected exact person commitment facts") }
        let value = try XCTUnwrap(values.first)
        XCTAssertEqual(values.count, 1)
        XCTAssertEqual(value.id, fixture.commitmentID)
        XCTAssertEqual(value.personName, "Ana")
        XCTAssertEqual(value.title, "Prepare the rollout")
        XCTAssertEqual(value.citations, [fixture.citation])
        XCTAssertEqual(value.primaryCitation, fixture.citation)
        XCTAssertFalse(disclosure.hasMore)
        XCTAssertEqual(disclosure.omittedStaleCount, 0)
        XCTAssertEqual(disclosure.omittedUnavailableCount, 0)
    }

    func testMemoryPersonCommitmentsFailClosedForWrongPersonOrUnreadyGraph() async throws {
        let fixture = AskMemoryPresentationFixture()
        let ask = ControlledAskModelClient()
        let memory = ControlledAskMemoryModelClient()
        let model = AskModel(
            client: ask,
            memoryClient: memory,
            memorySearchDelay: .zero)
        let memoryModel = try XCTUnwrap(model.memory)

        model.selectSurface(.personCommitments)
        try await waitUntil { memory.peopleRequests == [""] }
        memory.completePeople("", with: [fixture.person])
        try await waitUntil { memoryModel.state.peoplePhase == .ready }
        memoryModel.selectPerson(fixture.person.id)
        memoryModel.loadSelectedPersonCommitments()
        try await waitUntil { memory.commitmentRequests.count == 1 }
        memory.completeCommitments(
            for: fixture.person.id,
            with: .facts(fixture.page(subjectID: PersonID())))
        try await waitUntil { memoryModel.state.outcome == .invalidEvidence }

        memoryModel.loadSelectedPersonCommitments()
        try await waitUntil { memory.commitmentRequests.count == 2 }
        memory.completeCommitments(
            for: fixture.person.id,
            with: .abstained(.projectionNotReady))
        try await waitUntil {
            memoryModel.state.outcome == .abstained(.projectionNotReady)
        }
    }

    func testMemoryPendingReadDoesNotRetainClosedWindowModel() async throws {
        let memory = ControlledAskMemoryModelClient()
        var model: AskMemoryModel? = AskMemoryModel(
            client: memory,
            searchDelay: .zero)
        weak let retainedModel = model

        model?.activate()
        try await waitUntil { memory.peopleRequests == [""] }
        model = nil

        XCTAssertNil(
            retainedModel,
            "an in-flight local read must not retain a closed Ask window")
        memory.completePeople("", with: [])
        await Task.yield()
    }

    func testPaletteResetPreventsClosedGenerationFromPublishingIntoReopen() async throws {
        let fixture = AskPresentationFixture()
        let client = ControlledAskModelClient()
        let model = CommandPaletteModel(client: client)

        model.updateQuery("old")
        try await waitUntil { client.searchRequests.contains("old") }
        model.reset()
        model.updateQuery("new")
        try await waitUntil { client.searchRequests.contains("new") }

        client.completeSearch("old", with: [fixture.oldHit])
        client.completeSearch("new", with: [fixture.newHit])
        try await waitUntil { model.state.hits == [fixture.newHit] }

        model.submit()
        try await waitUntil { client.answerRequests.contains("new") }
        model.reset()
        model.updateQuery("newer")
        try await waitUntil { client.searchRequests.contains("newer") }
        client.completeAnswer(
            "new",
            with: AskMeetingAnswer(
                question: "new",
                generatedText: "stale",
                citations: [fixture.citation]))
        client.completeSearch("newer", with: [fixture.newerHit])
        try await waitUntil { model.state.hits == [fixture.newerHit] }

        XCTAssertNil(model.state.answer)
        XCTAssertFalse(model.state.isAnswering)
        XCTAssertEqual(model.state.query, "newer")
    }

    /// SwiftUI can deliver a trailing text update after `onSubmit` — coalesced
    /// typing, an IME commit, a re-render with the same value. Treating that as
    /// a new query cancelled the answer already running for it, leaving the
    /// palette showing hits, no answer, and nothing to restart it.
    func testAnEchoedQueryDoesNotCancelTheAnswerRunningForIt() async throws {
        let fixture = AskPresentationFixture()
        let client = ControlledAskModelClient()
        let model = CommandPaletteModel(client: client)

        model.updateQuery("rollout")
        try await waitUntil { client.searchRequests.contains("rollout") }
        client.completeSearch("rollout", with: [fixture.newHit])
        model.submit()
        try await waitUntil { client.answerRequests.contains("rollout") }

        // The same text arrives again while the answer is in flight.
        model.updateQuery("rollout")

        client.completeAnswer(
            "rollout",
            with: AskMeetingAnswer(
                question: "rollout",
                generatedText: "El viernes.",
                citations: [fixture.citation]))
        try await waitUntil { model.state.answer != nil }
        XCTAssertEqual(model.state.answer?.text, "El viernes.")
        XCTAssertFalse(model.state.isAnswering)
    }

    /// `isAnswering` gates `submit`, so a palette that leaked it would refuse
    /// every further Enter. Characterization: this pins the property rather
    /// than a fix — the behaviour already held before the defer that now
    /// guarantees it.
    func testAnAnswerThatFailsStillLetsTheUserAskAgain() async throws {
        let fixture = AskPresentationFixture()
        let client = ControlledAskModelClient()
        let model = CommandPaletteModel(client: client)

        model.updateQuery("rollout")
        try await waitUntil { client.searchRequests.contains("rollout") }
        client.completeSearch("rollout", with: [fixture.newHit])
        model.submit()
        try await waitUntil { client.answerRequests.contains("rollout") }

        // The request fails outright rather than answering.
        client.failAnswer("rollout")
        try await waitUntil { !model.state.isAnswering }

        // Enter works again, on the same question.
        model.submit()
        try await waitUntil { client.answerRequests.filter { $0 == "rollout" }.count == 2 }
        client.completeAnswer(
            "rollout",
            with: AskMeetingAnswer(
                question: "rollout",
                generatedText: "El viernes.",
                citations: [fixture.citation]))
        try await waitUntil { model.state.answer?.text == "El viernes." }
    }

    func testPaletteMarkdownKeepsQuestionAnswerAndReceipts() async throws {
        let fixture = AskPresentationFixture()
        let client = ControlledAskModelClient()
        let model = CommandPaletteModel(client: client)

        model.updateQuery("rollout")
        try await waitUntil { client.searchRequests.contains("rollout") }
        client.completeSearch("rollout", with: [fixture.newHit])
        model.submit()
        try await waitUntil { client.answerRequests.contains("rollout") }
        client.completeAnswer(
            "rollout",
            with: AskMeetingAnswer(
                question: "rollout",
                generatedText: "El viernes.",
                citations: [fixture.citation]))
        try await waitUntil { model.state.answer != nil }

        XCTAssertEqual(
            model.markdownAnswer(),
            "> rollout\n\nEl viernes.\n\n- Test meeting · 00:03")
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        _ condition: @escaping @MainActor () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition() {
            guard clock.now < deadline else { throw AskPresentationTestError.timeout }
            await Task.yield()
        }
    }
}

private struct AskPresentationFixture {
    let meetingID = MeetingID()
    let oldHit: AskSearchResult
    let newHit: AskSearchResult
    let newerHit: AskSearchResult
    let citation: AskCitation

    init() {
        oldHit = AskSearchResult(
            meetingID: meetingID,
            meetingTitle: "Old",
            segmentID: UUID(),
            snippet: "old",
            timestamp: 1)
        newHit = AskSearchResult(
            meetingID: meetingID,
            meetingTitle: "New",
            segmentID: UUID(),
            snippet: "new",
            timestamp: 2)
        newerHit = AskSearchResult(
            meetingID: meetingID,
            meetingTitle: "Newer",
            segmentID: UUID(),
            snippet: "newer",
            timestamp: 4)
        citation = AskCitation(
            segmentID: UUID(),
            meetingID: meetingID,
            meetingTitle: "Test meeting",
            timestamp: 3,
            text: "El rollout queda para el viernes.")
    }
}

private struct AskMemoryPresentationFixture {
    let person = Person(preferredName: "Ana")
    let commitmentID = CommitmentID()
    let meetingID = MeetingID()
    let segmentID = UUID()

    var citation: AskCitation {
        AskCitation(
            segmentID: segmentID,
            meetingID: meetingID,
            meetingTitle: "Test meeting",
            timestamp: 3,
            transcriptRevision: 0,
            text: "Ana will prepare the rollout.")
    }

    func page(
        subjectID: PersonID? = nil
    ) -> MeetingMemoryGraphFactPage {
        MeetingMemoryGraphFactPage(
            facts: [MeetingMemoryGraphFact(
                id: .commitment(commitmentID),
                kind: .personCommittedTo,
                subject: .person(subjectID ?? person.id),
                object: .commitment(commitmentID),
                subjectText: "Ana",
                objectText: "Prepare the rollout",
                status: .active,
                occurredAt: Date(timeIntervalSince1970: 1_700_000_100),
                evidence: [MeetingMemoryGraphEvidence(
                    meetingID: meetingID,
                    meetingTitle: "Test meeting",
                    meetingStartedAt: Date(timeIntervalSince1970: 1_700_000_000),
                    transcriptRevision: 0,
                    segmentID: segmentID,
                    startTime: 3,
                    endTime: 6,
                    text: "Ana will prepare the rollout.",
                    language: "en")],
                primaryEvidenceSegmentID: segmentID)],
            hasMore: false,
            projectionGeneration: 1,
            omittedStaleCount: 0,
            omittedUnavailableCount: 0)
    }
}

@MainActor
private final class ControlledAskModelClient: AskModelClient {
    private(set) var searchRequests: [String] = []
    private(set) var answerRequests: [String] = []
    private var searchContinuations: [String: CheckedContinuation<[AskSearchResult], Error>] = [:]
    private var answerContinuations: [String: CheckedContinuation<AskMeetingAnswer, Error>] = [:]
    private var evidenceReceivers: [String: AskEvidenceReceiver] = [:]

    func searchAskMeetings(
        _ query: String,
        limit _: Int
    ) async throws -> [AskSearchResult] {
        searchRequests.append(query)
        return try await withCheckedThrowingContinuation { continuation in
            searchContinuations[query] = continuation
        }
    }

    func answerAskMeetings(
        _ question: String,
        limit _: Int
    ) async throws -> AskMeetingAnswer {
        answerRequests.append(question)
        return try await withCheckedThrowingContinuation { continuation in
            answerContinuations[question] = continuation
        }
    }

    func answerAskMeetings(
        _ question: String,
        limit _: Int,
        onEvidence: @escaping AskEvidenceReceiver
    ) async throws -> AskMeetingAnswer {
        answerRequests.append(question)
        evidenceReceivers[question] = onEvidence
        return try await withCheckedThrowingContinuation { continuation in
            answerContinuations[question] = continuation
        }
    }

    func completeSearch(_ query: String, with hits: [AskSearchResult]) {
        searchContinuations.removeValue(forKey: query)?.resume(returning: hits)
    }

    func completeAnswer(_ question: String, with answer: AskMeetingAnswer) {
        evidenceReceivers.removeValue(forKey: question)
        answerContinuations.removeValue(forKey: question)?.resume(returning: answer)
    }

    func failAnswer(_ question: String) {
        evidenceReceivers.removeValue(forKey: question)
        answerContinuations.removeValue(forKey: question)?
            .resume(throwing: AskPresentationTestError.refused)
    }

    func publishEvidence(
        _ question: String,
        update: AskEvidenceUpdate
    ) async {
        await evidenceReceivers[question]?(update)
    }
}

@MainActor
private final class ControlledAskMemoryModelClient: AskMemoryModelClient {
    private(set) var peopleRequests: [String] = []
    private(set) var peopleLimits: [Int] = []
    private(set) var commitmentRequests: [PersonID] = []
    private(set) var commitmentLimits: [Int] = []
    private var peopleContinuations:
        [String: CheckedContinuation<[Person], Error>] = [:]
    private var commitmentContinuations:
        [PersonID: [CheckedContinuation<MeetingMemoryGraphQueryResult, Error>]] = [:]

    func searchAskMemoryPeople(
        _ query: String,
        limit: Int
    ) async throws -> [Person] {
        peopleRequests.append(query)
        peopleLimits.append(limit)
        return try await withCheckedThrowingContinuation { continuation in
            peopleContinuations[query] = continuation
        }
    }

    func loadAskMemoryPersonCommitments(
        personID: PersonID,
        limit: Int
    ) async throws -> MeetingMemoryGraphQueryResult {
        commitmentRequests.append(personID)
        commitmentLimits.append(limit)
        return try await withCheckedThrowingContinuation { continuation in
            commitmentContinuations[personID, default: []].append(continuation)
        }
    }

    func completePeople(_ query: String, with people: [Person]) {
        peopleContinuations.removeValue(forKey: query)?.resume(returning: people)
    }

    func completeCommitments(
        for personID: PersonID,
        with result: MeetingMemoryGraphQueryResult
    ) {
        guard var continuations = commitmentContinuations[personID],
              !continuations.isEmpty
        else { return }
        let continuation = continuations.removeFirst()
        commitmentContinuations[personID] = continuations
        continuation.resume(returning: result)
    }
}

private enum AskPresentationTestError: Error {
    case timeout
    case refused
}
