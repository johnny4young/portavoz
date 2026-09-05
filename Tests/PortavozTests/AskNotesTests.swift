import ApplicationKit
import Foundation
import PortavozCore
import XCTest

final class AskNotesTests: XCTestCase {
    func testPublicBilingualNoteCorpusAnswersAndAbstainsWithExactSources() async throws {
        let corpus = try loadCorpus()
        for language in ["en", "es"] {
            let source = try XCTUnwrap(corpus.sources.first {
                $0.id == "source-note-\(language)"
            })
            let answerScenario = try XCTUnwrap(corpus.scenarios.first {
                $0.id == "scenario-note-\(language)-answer"
            })
            let abstainScenario = try XCTUnwrap(corpus.scenarios.first {
                $0.id == "scenario-note-\(language)-abstain"
            })
            let citations = corpusCitations(source)
            let supported = AskNotes(
                retrieval: AskNoteRetrievalFake(citations: citations),
                answering: AskNoteAnsweringFake(text: language == "es"
                    ? "Las facturas siguen en la región actual hasta dos ensayos [1]."
                    : "Invoices stay in the current region until two rehearsals pass [1]."))

            let answer = try await supported.answer(answerScenario.question)

            XCTAssertEqual(answer.generationOutcome, .generated)
            XCTAssertEqual(answer.citations.map(\.text), [source.passages[0].text])
            XCTAssertFalse(answer.generatedText?.contains("[1]") == true)
            XCTAssertFalse(answer.generatedText?.contains(source.passages[1].text) == true)

            let abstention = AskNotes(
                retrieval: AskNoteRetrievalFake(citations: citations),
                answering: AskNoteAnsweringFake(text: language == "es"
                    ? "Ese cliente no aparece en las notas [1]."
                    : "That customer is not mentioned in the notes [1]."))
            let abstained = try await abstention.answer(abstainScenario.question)
            XCTAssertEqual(abstained.generationOutcome, .insufficientEvidence)
            XCTAssertNil(abstained.generatedText)
            XCTAssertEqual(abstained.citations, citations)
        }
    }

    func testGeneratedAnswerKeepsOnlyCitedRawNotesAndStripsMarkers() async throws {
        let fixture = AskNoteFixture()
        let retrieval = AskNoteRetrievalFake(citations: fixture.citations)
        let answering = AskNoteAnsweringFake(
            text: "Review the Q3 budget [2].")
        let updates = AskNoteEvidenceRecorder()
        let useCase = AskNotes(retrieval: retrieval, answering: answering)

        let answer = try await useCase.answer(
            "  What should I review?  ",
            onEvidence: { await updates.receive($0) })

        XCTAssertEqual(answer.question, "What should I review?")
        XCTAssertEqual(answer.generatedText, "Review the Q3 budget.")
        XCTAssertEqual(answer.citations, [fixture.citations[1]])
        XCTAssertEqual(answer.generationOutcome, .generated)
        let questions = await retrieval.questions
        let inputs = await answering.inputs
        let published = await updates.values
        XCTAssertEqual(questions, ["What should I review?"])
        XCTAssertEqual(inputs, [fixture.citations])
        XCTAssertEqual(
            published,
            [AskNoteEvidenceUpdate(phase: .fused, citations: fixture.citations)])
    }

    func testEmptyQuestionAndNoEvidenceAbstainBeforeGeneration() async throws {
        let retrieval = AskNoteRetrievalFake(citations: [])
        let answering = AskNoteAnsweringFake(text: "must not run [1].")
        let useCase = AskNotes(retrieval: retrieval, answering: answering)

        let empty = try await useCase.answer("  ")
        let missing = try await useCase.answer("unknown")

        XCTAssertEqual(empty.generationOutcome, .insufficientEvidence)
        XCTAssertTrue(empty.citations.isEmpty)
        XCTAssertEqual(missing.generationOutcome, .insufficientEvidence)
        XCTAssertTrue(missing.citations.isEmpty)
        let questions = await retrieval.questions
        let callCount = await answering.callCount
        XCTAssertEqual(questions, ["unknown"])
        XCTAssertEqual(callCount, 0)
    }

    func testProviderOutcomesPreserveExactEvidence() async throws {
        let fixture = AskNoteFixture()
        let unavailable = AskNotes(
            retrieval: AskNoteRetrievalFake(citations: fixture.citations),
            answering: AskNoteAnsweringFake(text: nil))
        let failed = AskNotes(
            retrieval: AskNoteRetrievalFake(citations: fixture.citations),
            answering: AskNoteAnsweringFake(error: AskNoteTestError.provider))
        let timedOut = AskNotes(
            retrieval: AskNoteRetrievalFake(citations: fixture.citations),
            answering: SleepingAskNoteAnswerer(),
            answerTimeout: .milliseconds(10))

        let unavailableAnswer = try await unavailable.answer("budget")
        let failedAnswer = try await failed.answer("budget")
        let timedOutAnswer = try await timedOut.answer("budget")

        XCTAssertEqual(unavailableAnswer.generationOutcome, .unavailable)
        XCTAssertEqual(failedAnswer.generationOutcome, .failed)
        XCTAssertEqual(timedOutAnswer.generationOutcome, .timedOut)
        XCTAssertEqual(unavailableAnswer.citations, fixture.citations)
        XCTAssertEqual(failedAnswer.citations, fixture.citations)
        XCTAssertEqual(timedOutAnswer.citations, fixture.citations)
    }

    func testCancellationEscapesInsteadOfBecomingProviderFailure() async throws {
        let fixture = AskNoteFixture()
        let answering = BlockingAskNoteAnswerer()
        let useCase = AskNotes(
            retrieval: AskNoteRetrievalFake(citations: fixture.citations),
            answering: answering)
        let task = Task { try await useCase.answer("budget") }
        await answering.waitUntilStarted()

        task.cancel()

        do {
            _ = try await task.value
            XCTFail("cancelled note generation must leave the workflow")
        } catch is CancellationError {
            // Expected: the presentation generation fence owns cancellation.
        }
    }

    func testMalformedGeneratedCitationsFailClosed() async throws {
        let fixture = AskNoteFixture()
        let invalidAnswers = [
            "Review the budget.",
            "Review the budget [3].",
            "Review [1] the budget [oops].",
            "Review the budget [1]. Then publish it.",
            "Review the budget [1",
        ]

        for raw in invalidAnswers {
            let useCase = AskNotes(
                retrieval: AskNoteRetrievalFake(citations: fixture.citations),
                answering: AskNoteAnsweringFake(text: raw))
            let answer = try await useCase.answer("budget")
            XCTAssertNil(answer.generatedText, "must reject: \(raw)")
            XCTAssertEqual(answer.generationOutcome, .insufficientEvidence)
            XCTAssertEqual(answer.citations, fixture.citations)
        }
    }

    func testOversizedQuestionAndLimitFailBeforeCapabilitiesRun() async throws {
        let retrieval = AskNoteRetrievalFake(citations: [])
        let answering = AskNoteAnsweringFake(text: nil)
        let useCase = AskNotes(retrieval: retrieval, answering: answering)
        let oversized = String(
            repeating: "q",
            count: AskRequestLimits.maximumQuestionCharacters + 1)

        do {
            _ = try await useCase.answer(oversized)
            XCTFail("oversized questions must be rejected")
        } catch AskRequestError.questionTooLong {}
        do {
            _ = try await useCase.answer(
                "budget",
                limit: AskNoteLimits.maximumResultCount + 1)
            XCTFail("oversized result limits must be rejected")
        } catch AskRequestError.resultLimitExceeded {}

        let questions = await retrieval.questions
        let callCount = await answering.callCount
        XCTAssertTrue(questions.isEmpty)
        XCTAssertEqual(callCount, 0)
    }

    func testProgressiveEvidencePublishesLexicalThenFusedBeforeGeneration() async throws {
        let fixture = AskNoteFixture()
        let retrieval = ProgressiveAskNoteRetrievalFake(
            lexical: [fixture.citations[0]],
            fused: fixture.citations)
        let answering = AskNoteAnsweringFake(text: "Review Q3 [2].")
        let recorder = AskNoteEvidenceRecorder()
        let useCase = AskNotes(retrieval: retrieval, answering: answering)

        let answer = try await useCase.answer(
            "budget",
            onEvidence: { await recorder.receive($0) })
        let updates = await recorder.values

        XCTAssertEqual(answer.generationOutcome, .generated)
        XCTAssertEqual(
            updates,
            [
                AskNoteEvidenceUpdate(
                    phase: .lexical,
                    citations: [fixture.citations[0]]),
                AskNoteEvidenceUpdate(
                    phase: .fused,
                    citations: fixture.citations),
            ])
    }

    func testProgressiveFusedEvidenceMustMatchReturnedEvidence() async throws {
        let fixture = AskNoteFixture()
        let answering = AskNoteAnsweringFake(text: "must not run [1].")
        let useCase = AskNotes(
            retrieval: MismatchedAskNoteRetrieval(
                emitted: [fixture.citations[0]],
                returned: [fixture.citations[1]]),
            answering: answering)

        do {
            _ = try await useCase.answer("budget")
            XCTFail("mismatched progressive evidence must fail closed")
        } catch {
            let callCount = await answering.callCount
            XCTAssertEqual(callCount, 0)
        }
    }

    func testInjectedEvidenceMustBeRawLocalUniqueFiniteAndBounded() async throws {
        let fixture = AskNoteFixture()
        let valid = fixture.citations[0]
        let invalid: [[AskNoteCitation]] = [
            [AskNoteCitation(
                noteID: valid.noteID,
                meetingID: valid.meetingID,
                meetingTitle: valid.meetingTitle,
                author: .localUser,
                authoredAt: valid.authoredAt,
                timestamp: -.infinity,
                text: valid.text,
                provenance: .userContextItem)],
            [AskNoteCitation(
                noteID: valid.noteID,
                meetingID: valid.meetingID,
                meetingTitle: "  ",
                author: .localUser,
                authoredAt: valid.authoredAt,
                timestamp: valid.timestamp,
                text: valid.text,
                provenance: .userContextItem)],
            [valid, valid],
            [AskNoteCitation(
                noteID: valid.noteID,
                meetingID: valid.meetingID,
                meetingTitle: valid.meetingTitle,
                author: .localUser,
                authoredAt: valid.authoredAt,
                timestamp: valid.timestamp,
                text: String(
                    repeating: "x",
                    count: AskNoteLimits.maximumCitationCharacters + 1),
                provenance: .userContextItem)],
        ]

        for citations in invalid {
            let answering = AskNoteAnsweringFake(text: "must not run [1].")
            let useCase = AskNotes(
                retrieval: AskNoteRetrievalFake(citations: citations),
                answering: answering)
            do {
                _ = try await useCase.answer("budget")
                XCTFail("invalid injected evidence must fail closed")
            } catch {
                let callCount = await answering.callCount
                XCTAssertEqual(callCount, 0)
            }
        }
    }

    func testConcurrentCancellationStressPublishesNoAnswers() async throws {
        let fixture = AskNoteFixture()
        let answering = CancellationAwareAskNoteAnswerer()
        let useCase = AskNotes(
            retrieval: AskNoteRetrievalFake(citations: fixture.citations),
            answering: answering)

        let tasks = (0..<40).map { _ in
            Task { try await useCase.answer("budget") }
        }
        while await answering.callCount < tasks.count {
            await Task.yield()
        }
        tasks.forEach { $0.cancel() }

        for task in tasks {
            do {
                _ = try await task.value
                XCTFail("every stress request was cancelled")
            } catch is CancellationError {}
        }
        let completedCount = await answering.completedCount
        XCTAssertEqual(completedCount, 0)
    }

    private func corpusCitations(
        _ source: AskNoteCorpusSource
    ) -> [AskNoteCitation] {
        let meetingID = MeetingID()
        let authoredAt = ISO8601DateFormatter().date(from: source.occurredAt)
            ?? Date(timeIntervalSince1970: 0)
        return source.passages.enumerated().map { index, passage in
            AskNoteCitation(
                noteID: index == 0
                    ? UUID(uuidString: "10000000-0000-4000-a000-000000000001")!
                    : UUID(uuidString: "10000000-0000-4000-a000-000000000002")!,
                meetingID: meetingID,
                meetingTitle: source.title,
                author: .localUser,
                authoredAt: authoredAt.addingTimeInterval(TimeInterval(index)),
                timestamp: TimeInterval(index),
                text: passage.text,
                provenance: .userContextItem)
        }
    }

    private func loadCorpus() throws -> AskNoteCorpusFixture {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent(
            "Fixtures/ApuntadorValidation/public-bilingual-v1.json"))
        return try JSONDecoder().decode(AskNoteCorpusFixture.self, from: data)
    }
}

private struct AskNoteCorpusFixture: Decodable {
    let sources: [AskNoteCorpusSource]
    let scenarios: [AskNoteCorpusScenario]
}

private struct AskNoteCorpusSource: Decodable {
    let id: String
    let title: String
    let occurredAt: String
    let passages: [AskNoteCorpusPassage]
}

private struct AskNoteCorpusPassage: Decodable {
    let text: String
}

private struct AskNoteCorpusScenario: Decodable {
    let id: String
    let question: String
}

private struct AskNoteFixture {
    let meetingID = MeetingID()
    let citations: [AskNoteCitation]

    init() {
        let meetingID = meetingID
        citations = [
            AskNoteCitation(
                noteID: UUID(),
                meetingID: meetingID,
                meetingTitle: "Launch review",
                author: .localUser,
                authoredAt: Date(timeIntervalSince1970: 1_700_000_012),
                timestamp: 12,
                text: "Confirm the release owner.",
                provenance: .userContextItem),
            AskNoteCitation(
                noteID: UUID(),
                meetingID: meetingID,
                meetingTitle: "Launch review",
                author: .localUser,
                authoredAt: Date(timeIntervalSince1970: 1_700_000_025),
                timestamp: 25,
                text: "Review the Q3 budget before Friday.",
                provenance: .userContextItem),
        ]
    }
}

private enum AskNoteTestError: Error {
    case provider
}

private actor AskNoteRetrievalFake: AskNoteRetrieving {
    let citations: [AskNoteCitation]
    private(set) var questions: [String] = []

    init(citations: [AskNoteCitation]) {
        self.citations = citations
    }

    func retrieve(
        question: String,
        limit _: Int,
        onEvidence _: @escaping AskNoteEvidenceReceiver
    ) -> [AskNoteCitation] {
        questions.append(question)
        return citations
    }
}

private actor AskNoteAnsweringFake: AskNoteAnswering {
    let text: String?
    let error: Error?
    private(set) var inputs: [[AskNoteCitation]] = []

    var callCount: Int { inputs.count }

    init(text: String? = nil, error: Error? = nil) {
        self.text = text
        self.error = error
    }

    func answer(
        question _: String,
        citations: [AskNoteCitation]
    ) throws -> String? {
        inputs.append(citations)
        if let error { throw error }
        return text
    }
}

private actor AskNoteEvidenceRecorder {
    private(set) var values: [AskNoteEvidenceUpdate] = []

    func receive(_ update: AskNoteEvidenceUpdate) {
        values.append(update)
    }
}

private struct SleepingAskNoteAnswerer: AskNoteAnswering {
    func answer(
        question _: String,
        citations _: [AskNoteCitation]
    ) async throws -> String? {
        try await Task.sleep(for: .seconds(1))
        return "late [1]."
    }
}

private actor BlockingAskNoteAnswerer: AskNoteAnswering {
    private var started = false

    func answer(
        question _: String,
        citations _: [AskNoteCitation]
    ) async throws -> String? {
        started = true
        try await Task.sleep(for: .seconds(60))
        return "late [1]."
    }

    func waitUntilStarted() async {
        while !started { await Task.yield() }
    }
}

private struct ProgressiveAskNoteRetrievalFake: AskNoteRetrieving {
    let lexical: [AskNoteCitation]
    let fused: [AskNoteCitation]

    func retrieve(
        question _: String,
        limit _: Int,
        onEvidence: @escaping AskNoteEvidenceReceiver
    ) async -> [AskNoteCitation] {
        await onEvidence(AskNoteEvidenceUpdate(
            phase: .lexical,
            citations: lexical))
        await onEvidence(AskNoteEvidenceUpdate(
            phase: .fused,
            citations: fused))
        return fused
    }
}

private struct MismatchedAskNoteRetrieval: AskNoteRetrieving {
    let emitted: [AskNoteCitation]
    let returned: [AskNoteCitation]

    func retrieve(
        question _: String,
        limit _: Int,
        onEvidence: @escaping AskNoteEvidenceReceiver
    ) async -> [AskNoteCitation] {
        await onEvidence(AskNoteEvidenceUpdate(
            phase: .fused,
            citations: emitted))
        return returned
    }
}

private actor CancellationAwareAskNoteAnswerer: AskNoteAnswering {
    private(set) var callCount = 0
    private(set) var completedCount = 0

    func answer(
        question _: String,
        citations _: [AskNoteCitation]
    ) async throws -> String? {
        callCount += 1
        try await Task.sleep(for: .seconds(60))
        completedCount += 1
        return "late [1]."
    }
}
