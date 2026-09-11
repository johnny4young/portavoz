import ApplicationKit
import Foundation
import PortavozCore

/// Owns one-shot eligibility and request identity for optional Meeting Detail
/// metadata suggestions. Generated values remain presentation state on the
/// route model; this type only decides when one request is still admissible.
struct MeetingDetailMetadataSuggestionState {
    struct Attempt {
        let id: UUID
        let request: SuggestMeetingReviewMetadataRequest
        let suggestsMeetingTitle: Bool
        let suggestsRecipe: Bool
    }

    private var didCompleteTitleSuggestion = false
    private var didCompleteRecipeSuggestion = false
    private var requestID = UUID()

    mutating func invalidate(correctionRevisionChanged: Bool) {
        requestID = UUID()
        guard correctionRevisionChanged else { return }
        didCompleteTitleSuggestion = false
        didCompleteRecipeSuggestion = false
    }

    mutating func begin(
        review: MeetingReviewReadModel,
        titledChapterStarts: Set<TimeInterval>
    ) -> Attempt? {
        let suggestsMeetingTitle = !didCompleteTitleSuggestion
            && review.summaryFreshness == .current
            && review.meeting.title.first?.isNumber == true
            && review.summary != nil
        let suggestsRecipe = !didCompleteRecipeSuggestion
            && review.summaryFreshness == .current
            && !review.segments.isEmpty
            && review.summary?.draft.recipeID == Recipe.general.id
        let generatedSegments = review.transcriptGenerationMaterial().segments
        let chapterStarts = Set(
            ChapterExtractor.chapters(from: generatedSegments).map(\.startTime))
        guard suggestsMeetingTitle
                || suggestsRecipe
                || !chapterStarts.isSubset(of: titledChapterStarts)
        else { return nil }

        let id = UUID()
        requestID = id
        return Attempt(
            id: id,
            request: SuggestMeetingReviewMetadataRequest(
                review: review,
                titledChapterStarts: titledChapterStarts,
                suggestMeetingTitle: suggestsMeetingTitle,
                suggestRecipe: suggestsRecipe),
            suggestsMeetingTitle: suggestsMeetingTitle,
            suggestsRecipe: suggestsRecipe)
    }

    func accepts(_ attempt: Attempt) -> Bool {
        requestID == attempt.id
    }

    mutating func complete(_ attempt: Attempt) {
        if attempt.suggestsMeetingTitle {
            didCompleteTitleSuggestion = true
        }
        if attempt.suggestsRecipe {
            didCompleteRecipeSuggestion = true
        }
    }
}
