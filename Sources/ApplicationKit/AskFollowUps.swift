import Foundation
import IntelligenceKit
import PortavozCore

/// Optional local generation of the next questions after an answer; empty
/// when no local model can suggest.
public protocol AskFollowUpSuggesting: Sendable {
    func followUps(
        question: String,
        answer: String,
        citations: [AskCitation]
    ) async throws -> [String]
}

/// Two or three short follow-up questions, or none. Any model failure or
/// timeout yields none; only cancellation propagates.
public struct SuggestAskFollowUps: Sendable {
    public static let maximumCount = 3
    static let minimumCount = 2
    static let maximumCharacters = 80

    private let suggesting: any AskFollowUpSuggesting
    private let timeout: Duration

    public init(suggesting: any AskFollowUpSuggesting, timeout: Duration = .seconds(8)) {
        self.suggesting = suggesting
        self.timeout = timeout > .zero ? timeout : .seconds(8)
    }

    public func callAsFunction(
        question rawQuestion: String,
        answer rawAnswer: String,
        citations: [AskCitation]
    ) async throws -> [String] {
        let question = rawQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        let answer = rawAnswer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !answer.isEmpty, !citations.isEmpty else { return [] }
        // Only the passages the answer cites: a shorter prompt and fewer prefill tokens.
        let cited = CompanionAnswer.citedPassageIndexes(answer, passageCount: citations.count)
        let passages = cited.isEmpty ? citations : cited.map { citations[$0] }
        let deadline = AskAnswerDeadline(after: timeout)
        do {
            let raw = try await withAskTimeout(
                deadline,
                onTimeout: {},
                operation: { [suggesting] in
                    try await suggesting.followUps(question: question, answer: answer, citations: passages)
                })
            return Self.admit(raw, question: question)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            return []
        }
    }

    /// Short single-line suggestions without list marks, `[n]` markers or
    /// links, each new and different from the question; fewer than two is none.
    static func admit(_ raw: [String], question: String) -> [String] {
        var seen: Set<String> = [fold(question)]
        var admitted: [String] = []
        for candidate in raw {
            let text = candidate
                .trimmingCharacters(in: .whitespaces)
                .replacing(#/^(?:[-*•]|\d{1,2}[.)])\s*/#, with: "")
                .replacing(#/\[\d+\]/#, with: "")
                .replacing(#/\s+/#, with: " ")
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”‘’«» "))
            guard !text.isEmpty,
                  text.count <= maximumCharacters,
                  !text.contains("://"),
                  seen.insert(fold(text)).inserted
            else { continue }
            admitted.append(text)
            if admitted.count == maximumCount { break }
        }
        return admitted.count >= minimumCount ? admitted : []
    }

    private static func fold(_ text: String) -> String {
        MeetingBriefLines.foldedKey(text).trimmingCharacters(in: .punctuationCharacters)
    }
}
