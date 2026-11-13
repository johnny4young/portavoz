import ApplicationKit
import Foundation
import PortavozCore

/// Narrow, storage-independent contract shared by the full Ask surface and
/// the process-scoped command palette.
@MainActor
protocol AskModelClient: AnyObject {
    func searchAskMeetings(
        _ query: String,
        source: AskSourceScope,
        limit: Int
    ) async throws -> [AskSearchResult]
    func answerAskMeetings(
        _ question: String,
        source: AskSourceScope,
        limit: Int
    ) async throws -> AskMeetingAnswer
    func answerAskMeetings(
        _ question: String,
        source: AskSourceScope,
        limit: Int,
        onEvidence: @escaping AskEvidenceReceiver
    ) async throws -> AskMeetingAnswer
    func answerAskMeetings(
        _ question: String,
        source: AskSourceScope,
        limit: Int,
        onEvidence: @escaping AskEvidenceReceiver,
        onAnswer: @escaping AskAnswerReceiver
    ) async throws -> AskMeetingAnswer
    func loadAskSourceMeetings(limit: Int) async throws -> [AskSourceMeetingOption]
    func answerAskNotes(
        _ question: String,
        limit: Int,
        onEvidence: @escaping AskNoteEvidenceReceiver
    ) async throws -> AskNoteAnswer
    func answerAskWeb(
        _ request: AskWebRequest,
        onEvidence: @escaping AskWebEvidenceReceiver,
        onAnswer: @escaping AskAnswerReceiver
    ) async throws -> AskWebAnswer
}

extension AskModelClient {
    func answerAskNotes(
        _ question: String,
        limit _: Int,
        onEvidence _: @escaping AskNoteEvidenceReceiver
    ) async throws -> AskNoteAnswer {
        AskNoteAnswer(
            question: question,
            generatedText: nil,
            citations: [],
            generationOutcome: .unavailable)
    }

    func loadAskSourceMeetings(limit _: Int) async throws -> [AskSourceMeetingOption] {
        []
    }

    func answerAskWeb(
        _ request: AskWebRequest,
        onEvidence _: @escaping AskWebEvidenceReceiver,
        onAnswer _: @escaping AskAnswerReceiver
    ) async throws -> AskWebAnswer {
        throw AskSourcePolicyError.webUnavailable
    }

    func answerAskMeetings(
        _ question: String,
        source: AskSourceScope,
        limit: Int,
        onEvidence: @escaping AskEvidenceReceiver
    ) async throws -> AskMeetingAnswer {
        let answer = try await answerAskMeetings(
            question,
            source: source,
            limit: limit)
        await onEvidence(AskEvidenceUpdate(
            phase: .fused,
            citations: answer.citations))
        return answer
    }

    func answerAskMeetings(
        _ question: String,
        source: AskSourceScope,
        limit: Int,
        onEvidence: @escaping AskEvidenceReceiver,
        onAnswer: @escaping AskAnswerReceiver
    ) async throws -> AskMeetingAnswer {
        let answer = try await answerAskMeetings(
            question,
            source: source,
            limit: limit,
            onEvidence: onEvidence)
        if let text = answer.generatedText {
            await onAnswer(AskAnswerUpdate(text: text))
        }
        return answer
    }
}

struct AskSourceMeetingOption: Identifiable, Equatable, Sendable {
    let id: MeetingID
    let title: String
    let startedAt: Date
}
