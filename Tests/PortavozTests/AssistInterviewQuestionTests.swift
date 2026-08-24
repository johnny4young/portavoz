import ApplicationKit
import Foundation
import IntelligenceKit
import PortavozCore
import XCTest

final class InterviewQuestionPolicyTests: XCTestCase {
    func testSelectsLatestFinalRemoteQuestionAndOnlyEarlierClosedEvidence() throws {
        let meetingID = MeetingID()
        let oldEvidence = row(
            meetingID: meetingID,
            channel: .microphone,
            text: "I paged the owner immediately.",
            start: 10)
        let openEvidence = row(
            meetingID: meetingID,
            channel: .microphone,
            text: "This row is not closed evidence.",
            start: 20,
            isFinal: false)
        let foreignEvidence = row(
            meetingID: MeetingID(),
            channel: .microphone,
            text: "This caption belongs to another recording.",
            start: 25)
        let ignoredMicQuestion = row(
            meetingID: meetingID,
            channel: .microphone,
            text: "What should I ask the candidate next?",
            start: 30)
        let firstQuestion = row(
            meetingID: meetingID,
            channel: .system,
            text: "What would you do during the outage?",
            start: 40)
        let laterEvidence = row(
            meetingID: meetingID,
            channel: .system,
            text: "We need a more specific answer.",
            start: 50)
        let latestQuestion = row(
            meetingID: meetingID,
            channel: .room,
            text: "How quickly would you page the database owner?",
            start: 60)
        let partialLaterQuestion = row(
            meetingID: meetingID,
            channel: .system,
            text: "And how would you verify the database",
            start: 70,
            isFinal: false)

        let context = try XCTUnwrap(InterviewQuestionPolicy.context(in: [
            oldEvidence,
            openEvidence,
            foreignEvidence,
            ignoredMicQuestion,
            firstQuestion,
            laterEvidence,
            latestQuestion,
            partialLaterQuestion,
        ]))

        XCTAssertEqual(context.question.segmentID, latestQuestion.id)
        XCTAssertEqual(context.question.text, latestQuestion.text)
        XCTAssertEqual(
            context.evidence.map(\.id),
            [oldEvidence.id, ignoredMicQuestion.id, firstQuestion.id, laterEvidence.id])
        XCTAssertFalse(context.evidence.contains { $0.id == openEvidence.id })
        XCTAssertFalse(context.evidence.contains { $0.id == foreignEvidence.id })
        XCTAssertFalse(context.evidence.contains { $0.id == latestQuestion.id })
        XCTAssertFalse(context.evidence.contains { $0.id == partialLaterQuestion.id })
    }

    func testEvidenceAndCandidateSearchStayBounded() throws {
        let meetingID = MeetingID()
        var captions = (0..<40).map { index in
            row(
                meetingID: meetingID,
                channel: .microphone,
                text: "Evidence row \(index)",
                start: TimeInterval(index))
        }
        let question = row(
            meetingID: meetingID,
            channel: .system,
            text: "What evidence supports the proposed response?",
            start: 50)
        captions.append(question)

        let context = try XCTUnwrap(
            InterviewQuestionPolicy.context(in: captions))
        XCTAssertEqual(
            context.evidence.count,
            InterviewQuestionPolicy.maximumEvidenceRows)
        XCTAssertEqual(context.evidence.first?.text, "Evidence row 32")
        XCTAssertEqual(context.evidence.last?.text, "Evidence row 39")
    }

    func testOldQuestionExpiresAndMicrophoneQuestionDoesNotBecomeCurrent() {
        let meetingID = MeetingID()
        let question = row(
            meetingID: meetingID,
            channel: .system,
            text: "What happened during the incident?",
            start: 0)
        let muchLater = row(
            meetingID: meetingID,
            channel: .microphone,
            text: "A much later answer continues after the question expired.",
            start: InterviewQuestionPolicy.currentQuestionLifetime + 20)
        XCTAssertNil(InterviewQuestionPolicy.context(in: [question, muchLater]))

        let microphoneOnly = row(
            meetingID: meetingID,
            channel: .microphone,
            text: "What should I ask next in this interview?",
            start: 1)
        XCTAssertNil(InterviewQuestionPolicy.context(in: [microphoneOnly]))

        let partialRemote = row(
            meetingID: meetingID,
            channel: .system,
            text: "What would you do while the database",
            start: 2,
            isFinal: false)
        XCTAssertNil(InterviewQuestionPolicy.context(in: [partialRemote]))
    }

    func testDelayedCallbackCannotReplaceTheChronologicallyCurrentQuestion() throws {
        let meetingID = MeetingID()
        let earlierEvidence = row(
            meetingID: meetingID,
            channel: .microphone,
            text: "The owner was paged quickly.",
            start: 10)
        let current = row(
            meetingID: meetingID,
            channel: .system,
            text: "How did you verify that the replica was healthy?",
            start: 80)
        let futureByTimestamp = row(
            meetingID: meetingID,
            channel: .microphone,
            text: "This answer happened after the current question.",
            start: 90)
        let delayedOlderQuestion = row(
            meetingID: meetingID,
            channel: .system,
            text: "What did you do first during the outage?",
            start: 5)

        let context = try XCTUnwrap(InterviewQuestionPolicy.context(in: [
            earlierEvidence,
            current,
            futureByTimestamp,
            delayedOlderQuestion,
        ]))
        XCTAssertEqual(context.question.segmentID, current.id)
        XCTAssertEqual(
            context.evidence.map(\.id),
            [delayedOlderQuestion.id, earlierEvidence.id])
        XCTAssertFalse(context.evidence.contains { $0.id == futureByTimestamp.id })
    }

    private func row(
        meetingID: MeetingID,
        channel: AudioChannel,
        text: String,
        start: TimeInterval,
        isFinal: Bool = true
    ) -> TranscriptSegment {
        TranscriptSegment(
            meetingID: meetingID,
            channel: channel,
            text: text,
            startTime: start,
            endTime: start + 2,
            isFinal: isFinal)
    }
}

final class AssistInterviewQuestionTests: XCTestCase {
    func testPublicBilingualInterviewCorpusAnswersAndAbstains() async throws {
        let corpus = try loadCorpus()
        for language in ["en", "es"] {
            let sourceID = "source-interview-\(language)"
            let answerScenarioID = "scenario-interview-\(language)-answer"
            let abstainScenarioID = "scenario-interview-\(language)-abstain"
            let source = try XCTUnwrap(corpus.sources.first { $0.id == sourceID })
            let answerScenario = try XCTUnwrap(
                corpus.scenarios.first { $0.id == answerScenarioID })
            let abstainScenario = try XCTUnwrap(
                corpus.scenarios.first { $0.id == abstainScenarioID })
            let context = fixtureContext(source: source, question: answerScenario.question)

            let supported = AssistInterviewQuestion(answering: FixedInterviewAnswerer(
                result: .answer(language == "es"
                    ? "Camila avisaría en cinco minutos y congelaría escrituras [1]."
                    : "Jordan would page the owner within five minutes and freeze writes [1].")))
            let supportedResult = try await supported.execute(context)
            guard case .answered(let answer) = supportedResult else {
                return XCTFail("expected a grounded \(language) answer, got \(supportedResult)")
            }
            XCTAssertEqual(answer.citations.map(\.number), [1])
            XCTAssertEqual(answer.citations.map(\.evidence.text), [source.passages[0].text])
            XCTAssertFalse(answer.text.contains("[1]"))

            let abstention = AssistInterviewQuestion(answering: FixedInterviewAnswerer(
                result: .answer(language == "es"
                    ? "No se menciona ese proveedor en el contexto."
                    : "The monitoring vendor is not mentioned in the context.")))
            let abstentionResult = try await abstention.execute(
                fixtureContext(source: source, question: abstainScenario.question))
            XCTAssertEqual(abstentionResult, .insufficientEvidence)
        }
    }

    func testRejectsMissingForgedAndPartiallyForgedCitations() async throws {
        let context = simpleContext()
        for raw in [
            "The owner was paged immediately.",
            "The owner was paged immediately [9].",
            "The owner was paged immediately [1], then alerts were disabled [9].",
            "The owner was paged immediately [1]. Alerts were disabled later.",
            "The owner was paged immediately [1]. A malformed source [2 follows.",
        ] {
            let useCase = AssistInterviewQuestion(
                answering: FixedInterviewAnswerer(result: .answer(raw)))
            let result = try await useCase.execute(context)
            XCTAssertEqual(
                result,
                .insufficientEvidence,
                "must fail closed for \(raw)")
        }
    }

    func testUnavailableFailureTimeoutAndCancellationRemainTyped() async throws {
        let context = simpleContext()
        let unavailable = try await AssistInterviewQuestion(
            answering: FixedInterviewAnswerer(result: .unavailable))
            .execute(context)
        XCTAssertEqual(
            unavailable,
            .unavailable)
        let failed = try await AssistInterviewQuestion(
            answering: FixedInterviewAnswerer(result: .failure))
            .execute(context)
        XCTAssertEqual(
            failed,
            .failed)
        let timedOut = try await AssistInterviewQuestion(
            answering: FixedInterviewAnswerer(result: .delayedAnswer),
            timeout: .milliseconds(20))
            .execute(context)
        XCTAssertEqual(
            timedOut,
            .timedOut)

        let useCase = AssistInterviewQuestion(
            answering: FixedInterviewAnswerer(result: .delayedAnswer),
            timeout: .seconds(1))
        let task = Task { try await useCase.execute(context) }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("cancellation must not become an ordinary outcome")
        } catch is CancellationError {
            // Expected.
        }
    }

    func testInvalidContextNeverReachesTheProvider() async throws {
        let probe = InterviewAnswerProbe()
        let useCase = AssistInterviewQuestion(answering: probe)
        let base = simpleContext()
        let duplicate = InterviewQuestionContext(
            question: base.question,
            evidence: [base.evidence[0], base.evidence[0]])
        let overlapping = InterviewQuestionContext(
            question: base.question,
            evidence: [InterviewEvidence(
                id: UUID(),
                meetingID: base.question.meetingID,
                channel: .microphone,
                timestamp: 10,
                endedAt: base.question.askedAt + 1,
                text: "This turn overlaps the current question.")])
        let foreignMeeting = InterviewQuestionContext(
            question: base.question,
            evidence: [InterviewEvidence(
                id: UUID(),
                meetingID: MeetingID(),
                channel: .microphone,
                timestamp: 10,
                endedAt: 12,
                text: "This turn belongs to another recording.")])
        let unsorted = InterviewQuestionContext(
            question: base.question,
            evidence: [
                InterviewEvidence(
                    id: UUID(),
                    meetingID: base.question.meetingID,
                    channel: .microphone,
                    timestamp: 20,
                    endedAt: 22,
                    text: "This turn happened second."),
                InterviewEvidence(
                    id: UUID(),
                    meetingID: base.question.meetingID,
                    channel: .microphone,
                    timestamp: 10,
                    endedAt: 12,
                    text: "This turn happened first."),
            ])

        for invalid in [duplicate, overlapping, foreignMeeting, unsorted] {
            let response = try await useCase.execute(invalid)
            XCTAssertEqual(response, .insufficientEvidence)
        }
        let requestCount = await probe.requestCount
        XCTAssertEqual(requestCount, 0)
    }

    private func simpleContext() -> InterviewQuestionContext {
        let meetingID = MeetingID()
        let evidence = InterviewEvidence(
            id: UUID(),
            meetingID: meetingID,
            channel: .microphone,
            timestamp: 10,
            endedAt: 12,
            text: "I paged the database owner within five minutes.")
        return InterviewQuestionContext(
            question: InterviewQuestion(
                segmentID: UUID(),
                meetingID: meetingID,
                text: "What did you do first during the incident?",
                askedAt: 40),
            evidence: [evidence])
    }

    private func fixtureContext(
        source: CorpusSource,
        question: String
    ) -> InterviewQuestionContext {
        let meetingID = MeetingID()
        return InterviewQuestionContext(
            question: InterviewQuestion(
                segmentID: UUID(),
                meetingID: meetingID,
                text: question,
                askedAt: 90),
            evidence: source.passages.map { passage in
                InterviewEvidence(
                    id: UUID(uuidString: deterministicUUID(for: passage.id)) ?? UUID(),
                    meetingID: meetingID,
                    channel: .microphone,
                    timestamp: TimeInterval(passage.timestampMilliseconds ?? 0) / 1_000,
                    endedAt: TimeInterval(passage.timestampMilliseconds ?? 0) / 1_000 + 2,
                    text: passage.text)
            })
    }

    private func deterministicUUID(for value: String) -> String {
        let bytes = Array(value.utf8)
        let padded = (bytes + Array(repeating: 0, count: 16)).prefix(16)
        let hex = padded.map { String(format: "%02x", $0) }.joined()
        return "\(hex.prefix(8))-\(hex.dropFirst(8).prefix(4))-4\(hex.dropFirst(13).prefix(3))-a\(hex.dropFirst(17).prefix(3))-\(hex.dropFirst(20).prefix(12))"
    }

    private func loadCorpus() throws -> CorpusFixture {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent(
            "Fixtures/ApuntadorValidation/public-bilingual-v1.json"))
        return try JSONDecoder().decode(CorpusFixture.self, from: data)
    }
}

private struct CorpusFixture: Decodable {
    let sources: [CorpusSource]
    let scenarios: [CorpusScenario]
}

private struct CorpusSource: Decodable {
    let id: String
    let passages: [CorpusPassage]
}

private struct CorpusPassage: Decodable {
    let id: String
    let text: String
    let timestampMilliseconds: Int?
}

private struct CorpusScenario: Decodable {
    let id: String
    let question: String
}

private struct FixedInterviewAnswerer: InterviewQuestionAnswering {
    enum Result: Sendable {
        case answer(String)
        case unavailable
        case failure
        case delayedAnswer
    }

    enum Failure: Error { case injected }
    let result: Result

    func answer(
        question _: String,
        passages _: [RAGPassage]
    ) async throws -> String? {
        switch result {
        case .answer(let answer): return answer
        case .unavailable: return nil
        case .failure: throw Failure.injected
        case .delayedAnswer:
            try await Task.sleep(for: .seconds(5))
            return "Delayed answer [1]."
        }
    }
}

private actor InterviewAnswerProbe: InterviewQuestionAnswering {
    private(set) var requestCount = 0

    func answer(
        question _: String,
        passages _: [RAGPassage]
    ) async throws -> String? {
        requestCount += 1
        return "Answer [1]."
    }
}
