import ApplicationKit
import Foundation
import IntelligenceKit

extension AppServices {
    static func makeInterviewAssist(
        arguments: [String],
        selectedAnswering: AppSelectedAskMeetingAnswering
    ) -> AssistInterviewQuestion {
        let isFixture = arguments.contains("-use-temp-store")
            && arguments.contains("-simulate-interview-assist")
        return AssistInterviewQuestion(
            answering: isFixture
                ? UITestInterviewQuestionAnswering()
                : selectedAnswering)
    }
}

/// Deterministic real-app adapter for the public/synthetic bilingual corpus.
/// It is reachable only with the disposable UI-test composition and exercises
/// the production use case, validation, model and SwiftUI state without
/// requiring private meetings or installed model assets.
private struct UITestInterviewQuestionAnswering: InterviewQuestionAnswering {
    enum FixtureError: Error { case unexpectedCorpus }

    func answer(
        question: String,
        passages: [RAGPassage]
    ) async throws -> String? {
        try await Task.sleep(for: .milliseconds(120))
        try Task.checkCancellation()
        if question.contains("Camila") {
            guard passages.contains(where: {
                $0.text.contains("Avisaría a la responsable de base de datos")
            }) else { throw FixtureError.unexpectedCorpus }
            return "Camila avisaría a la responsable de base de datos en cinco "
                + "minutos y congelaría escrituras antes de reconstruir réplicas [1]."
        }
        guard question.contains("Jordan"),
              passages.contains(where: {
                $0.text.contains("page the database owner within five minutes")
              })
        else { throw FixtureError.unexpectedCorpus }
        return "Jordan would page the database owner within five minutes and "
            + "freeze writes before rebuilding replicas [1]."
    }
}
