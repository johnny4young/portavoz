import ApplicationKit
import Foundation
import IntelligenceKit
import PortavozCore
@testable import portavoz_app
import XCTest

@MainActor
final class RecordingInterviewAssistModelTests: XCTestCase {
    func testQuestionRevisionCancelsAndRejectsLateAnswer() async throws {
        let answerer = SuspendedInterviewAnswerer()
        let useCase = AssistInterviewQuestion(
            answering: answerer,
            timeout: .seconds(2))
        let model = RecordingInterviewAssistModel()
        let first = captions(question: "What would you do first during the outage?")
        model.setEnabled(true, captions: first)
        model.requestAnswer(using: useCase, isRecording: { true })
        let firstRequestStarted = await eventually { await answerer.isWaiting }
        XCTAssertTrue(firstRequestStarted)

        let second = captions(
            question: "How would you verify that the replica is healthy?",
            questionStart: 60)
        model.observe(captions: second)
        XCTAssertEqual(model.context?.question.text, second.last?.text)
        XCTAssertNil(model.answerState)

        await answerer.resume(with: "Page the owner immediately [1].")
        let firstRequestFinished = await eventually { !(await answerer.isWaiting) }
        XCTAssertTrue(firstRequestFinished)
        await Task.yield()
        XCTAssertNil(
            model.answerState,
            "the prior question's completion must never publish on the new question")
    }

    func testDisableCancelsAndClearsTheCompleteSession() async throws {
        let answerer = SuspendedInterviewAnswerer()
        let model = RecordingInterviewAssistModel()
        model.setEnabled(
            true,
            captions: captions(question: "What did you do during the incident?"))
        model.requestAnswer(
            using: AssistInterviewQuestion(
                answering: answerer,
                timeout: .seconds(2)),
            isRecording: { true })
        let requestStarted = await eventually { await answerer.isWaiting }
        XCTAssertTrue(requestStarted)

        model.setEnabled(false, captions: [])
        XCTAssertFalse(model.isEnabled)
        XCTAssertNil(model.context)
        XCTAssertNil(model.answerState)
        await answerer.resume(with: "Late answer [1].")
        await Task.yield()
        XCTAssertNil(model.answerState)
    }

    func testUnavailableSelectedEngineIsVisibleAndRetryable() async throws {
        let model = RecordingInterviewAssistModel()
        model.setEnabled(
            true,
            captions: captions(question: "What did you do during the incident?"))
        model.requestAnswer(
            using: AssistInterviewQuestion(answering: NilInterviewAnswerer()),
            isRecording: { true })

        let unavailablePublished = await eventually {
            model.answerState == .unavailable
        }
        XCTAssertTrue(unavailablePublished)
        model.dismissAnswer()
        XCTAssertNil(model.answerState)
        XCTAssertNotNil(model.context, "dismissal keeps the exact current question")
    }

    private func captions(
        question: String,
        questionStart: TimeInterval = 40
    ) -> [TranscriptSegment] {
        let meetingID = MeetingID()
        return [
            TranscriptSegment(
                meetingID: meetingID,
                channel: .microphone,
                text: "I paged the database owner within five minutes.",
                startTime: 10,
                endTime: 12,
                isFinal: true),
            TranscriptSegment(
                meetingID: meetingID,
                channel: .system,
                text: question,
                startTime: questionStart,
                endTime: questionStart + 2,
                isFinal: true),
        ]
    }

    private func eventually(
        attempts: Int = 100,
        _ predicate: @escaping @MainActor () async -> Bool
    ) async -> Bool {
        for _ in 0..<attempts {
            if await predicate() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return await predicate()
    }
}

private actor SuspendedInterviewAnswerer: InterviewQuestionAnswering {
    private var continuation: CheckedContinuation<String?, Never>?
    private(set) var isWaiting = false

    func answer(
        question _: String,
        passages _: [RAGPassage]
    ) async throws -> String? {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            isWaiting = true
        }
    }

    func resume(with answer: String?) {
        isWaiting = false
        continuation?.resume(returning: answer)
        continuation = nil
    }
}

private struct NilInterviewAnswerer: InterviewQuestionAnswering {
    func answer(
        question _: String,
        passages _: [RAGPassage]
    ) async throws -> String? {
        nil
    }
}
