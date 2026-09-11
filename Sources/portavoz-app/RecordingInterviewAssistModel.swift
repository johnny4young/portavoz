import ApplicationKit
import Foundation
import Observation
import PortavozCore

/// Recording-scoped, explicitly enabled interview help. Question detection is
/// pure and local; answer generation is pull-only and every async completion is
/// fenced to the exact question revision that launched it.
@MainActor
@Observable
final class RecordingInterviewAssistModel {
    enum AnswerState: Equatable {
        case generating
        case answered(InterviewGroundedAnswer)
        case insufficientEvidence
        case unavailable
        case failed
        case timedOut
    }

    private(set) var isEnabled = false
    private(set) var context: InterviewQuestionContext?
    private(set) var answerState: AnswerState?
    private var task: Task<Void, Never>?
    private var requestID: UUID?

    func setEnabled(
        _ enabled: Bool,
        captions: [TranscriptSegment]
    ) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        if enabled {
            observe(captions: captions)
        } else {
            clearSessionState()
        }
    }

    func observe(captions: [TranscriptSegment]) {
        guard isEnabled else { return }
        let next = InterviewQuestionPolicy.context(in: captions)
        guard next != context else { return }
        task?.cancel()
        task = nil
        requestID = nil
        context = next
        answerState = nil
    }

    func requestAnswer(
        using useCase: AssistInterviewQuestion,
        isRecording: @escaping @MainActor () -> Bool
    ) {
        guard isEnabled,
              isRecording(),
              answerState != .generating,
              let context
        else { return }
        guard !context.evidence.isEmpty else {
            answerState = .insufficientEvidence
            return
        }

        let id = UUID()
        requestID = id
        answerState = .generating
        task = Task { @MainActor [weak self] in
            let response: InterviewAssistanceResponse
            do {
                response = try await useCase.execute(context)
            } catch is CancellationError {
                return
            } catch {
                response = .failed
            }
            guard let self,
                  !Task.isCancelled,
                  self.requestID == id,
                  self.isEnabled,
                  isRecording(),
                  self.context?.question == context.question
            else { return }
            self.answerState = Self.state(from: response)
            self.task = nil
            self.requestID = nil
        }
    }

    func dismissAnswer() {
        task?.cancel()
        task = nil
        requestID = nil
        answerState = nil
    }

    func reset() {
        isEnabled = false
        clearSessionState()
    }

    private func clearSessionState() {
        task?.cancel()
        task = nil
        requestID = nil
        context = nil
        answerState = nil
    }

    private static func state(
        from response: InterviewAssistanceResponse
    ) -> AnswerState {
        switch response {
        case .answered(let answer): .answered(answer)
        case .insufficientEvidence: .insufficientEvidence
        case .unavailable: .unavailable
        case .failed: .failed
        case .timedOut: .timedOut
        }
    }
}
