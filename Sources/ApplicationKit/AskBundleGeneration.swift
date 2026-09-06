import Foundation

/// Admission for the explicitly selected two-lane generator. Full retrieval
/// evidence remains owned by AskMeetings, independently of this optional work.
enum AskBundleGeneration {
    static func generate(
        question: String,
        answering: (any AskEvidenceBundleAnswering)?,
        evidence: AskSynthesisInput,
        deadline: AskAnswerDeadline
    ) async throws -> AskGenerationResult {
        guard evidence.isFactAwareGenerationReady else {
            return AskGenerationResult(text: nil, outcome: .insufficientEvidence)
        }
        guard let answering else {
            return AskGenerationResult(text: nil, outcome: .unavailable)
        }
        do {
            let text = try await withAskTimeout(
                deadline,
                onTimeout: {},
                operation: { try await answering.answer(question: question, evidence: evidence) })
            guard let text else {
                return AskGenerationResult(text: nil, outcome: .unavailable)
            }
            // Bound inspection as well as admission; never truncate an invalid
            // answer into apparently supported prose or discard its sources.
            let isValid = text.utf8.prefix(AskRequestLimits.maximumAnswerUTF8Bytes + 1).count
                <= AskRequestLimits.maximumAnswerUTF8Bytes
                && text.prefix(AskRequestLimits.maximumAnswerCharacters + 1).count
                <= AskRequestLimits.maximumAnswerCharacters
                && text.contains(where: { !$0.isWhitespace })
            try deadline.check()
            return AskGenerationResult(
                text: isValid ? text : nil,
                outcome: isValid ? .generated : .failed)
        } catch is CancellationError {
            throw CancellationError()
        } catch is AskTimeoutError {
            return AskGenerationResult(text: nil, outcome: .timedOut)
        } catch {
            return AskGenerationResult(text: nil, outcome: .failed)
        }
    }
}
