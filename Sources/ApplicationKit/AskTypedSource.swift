import Foundation
import IntelligenceKit

/// Request and answer admission shared by the typed local sources (notes and
/// dictations), whose evidence never mixes with transcript citations.
enum AskTypedSource {
    /// nil means there is nothing to search: an empty question or a zero limit.
    static func validatedQuestion(
        _ value: String,
        limit: Int,
        maximumLimit: Int
    ) throws -> String? {
        guard value.count <= AskRequestLimits.maximumQuestionCharacters,
              value.utf8.count <= AskRequestLimits.maximumQuestionUTF8Bytes
        else { throw AskRequestError.questionTooLong }
        guard limit > 0, limit <= maximumLimit else {
            if limit <= 0 { return nil }
            throw AskRequestError.resultLimitExceeded
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        try Task.checkCancellation()
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Bounded prose whose every marker names supplied evidence, with the
    /// cited evidence in marker order.
    static func admitAnswer<Citation>(
        _ raw: String,
        citations: [Citation]
    ) -> (text: String, citations: [Citation])? {
        guard raw.count <= AskRequestLimits.maximumAnswerCharacters,
              raw.utf8.count <= AskRequestLimits.maximumAnswerUTF8Bytes,
              let indexes = NumberedCitationAnswer.exactIndexes(
                in: raw,
                evidenceCount: citations.count),
              let text = CompanionAnswer.usable(raw)
        else { return nil }
        return (text, indexes.map { citations[$0] })
    }
}
