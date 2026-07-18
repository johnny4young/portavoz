import Foundation
import PortavozCore

/// Optional local-intelligence labels used while reviewing one meeting.
/// Every value is inert until the user accepts the corresponding UI action.
public struct MeetingReviewMetadataSuggestions: Sendable {
    public let chapterTitles: [TimeInterval: String]
    public let meetingTitle: String?
    public let recipe: Recipe?

    public init(
        chapterTitles: [TimeInterval: String] = [:],
        meetingTitle: String? = nil,
        recipe: Recipe? = nil
    ) {
        self.chapterTitles = chapterTitles
        self.meetingTitle = meetingTitle
        self.recipe = recipe
    }
}

/// Capability-neutral source for best-effort review labels. Concrete model
/// availability and generation stay in the executable adapter.
public protocol MeetingReviewMetadataGenerating: Sendable {
    var isAvailable: Bool { get }

    func chapterTitle(for text: String) async throws -> String?
    func meetingTitle(
        summaryMarkdown: String,
        currentTitle: String
    ) async throws -> String?
    func meetingRecipe(
        segments: [TranscriptSegment],
        speakerCount: Int
    ) async throws -> Recipe?
}

public struct SuggestMeetingReviewMetadataRequest: Sendable {
    public let review: MeetingReviewReadModel
    public let titledChapterStarts: Set<TimeInterval>
    public let suggestMeetingTitle: Bool
    public let suggestRecipe: Bool

    public init(
        review: MeetingReviewReadModel,
        titledChapterStarts: Set<TimeInterval> = [],
        suggestMeetingTitle: Bool = true,
        suggestRecipe: Bool = true
    ) {
        self.review = review
        self.titledChapterStarts = titledChapterStarts
        self.suggestMeetingTitle = suggestMeetingTitle
        self.suggestRecipe = suggestRecipe
    }
}

/// Coordinates suggestion admission and best-effort generation for Meeting
/// Detail. Capability failures preserve literal chapter excerpts and current
/// metadata; cancellation remains cancellation so a newer route revision can
/// retry instead of permanently consuming a one-shot suggestion.
public struct SuggestMeetingReviewMetadata: ApplicationUseCase {
    private let generator: any MeetingReviewMetadataGenerating

    public init(generator: any MeetingReviewMetadataGenerating) {
        self.generator = generator
    }

    public func execute(
        _ request: SuggestMeetingReviewMetadataRequest
    ) async throws -> MeetingReviewMetadataSuggestions {
        guard generator.isAvailable else {
            return MeetingReviewMetadataSuggestions()
        }
        try Task.checkCancellation()

        let detail = request.review
        let recipe = try await suggestedRecipe(for: request)
        let meetingTitle = try await suggestedMeetingTitle(for: request)
        let chapterTitles = try await suggestedChapterTitles(
            segments: detail.segments,
            excluding: request.titledChapterStarts)

        return MeetingReviewMetadataSuggestions(
            chapterTitles: chapterTitles,
            meetingTitle: meetingTitle,
            recipe: recipe)
    }
}

private extension SuggestMeetingReviewMetadata {
    func suggestedRecipe(
        for request: SuggestMeetingReviewMetadataRequest
    ) async throws -> Recipe? {
        let detail = request.review
        guard request.suggestRecipe,
              !detail.segments.isEmpty,
              detail.summary?.draft.recipeID == Recipe.general.id
        else { return nil }

        let generated = try await bestEffort {
            try await generator.meetingRecipe(
                segments: detail.segments,
                speakerCount: detail.speakers.count)
        }
        try Task.checkCancellation()
        guard let generated,
              generated.id != Recipe.general.id
        else { return nil }
        return Recipe.byID(generated.id)
    }

    func suggestedMeetingTitle(
        for request: SuggestMeetingReviewMetadataRequest
    ) async throws -> String? {
        let detail = request.review
        guard request.suggestMeetingTitle,
              detail.meeting.title.first?.isNumber == true,
              let summary = detail.summary
        else { return nil }

        let generated = try await bestEffort {
            try await generator.meetingTitle(
                summaryMarkdown: summary.draft.markdown,
                currentTitle: detail.meeting.title)
        }
        try Task.checkCancellation()
        guard let title = admittedLabel(generated, maximumLength: 60),
              title.caseInsensitiveCompare(detail.meeting.title) != .orderedSame
        else { return nil }
        return title
    }

    func suggestedChapterTitles(
        segments: [TranscriptSegment],
        excluding titledStarts: Set<TimeInterval>
    ) async throws -> [TimeInterval: String] {
        let chapters = ChapterExtractor.chapters(from: segments)
        var titles: [TimeInterval: String] = [:]

        for (index, chapter) in chapters.enumerated()
        where !titledStarts.contains(chapter.startTime) {
            try Task.checkCancellation()
            let end = index + 1 < chapters.count
                ? chapters[index + 1].startTime
                : .infinity
            let text = segments
                .filter {
                    $0.startTime >= chapter.startTime
                        && $0.startTime < end
                        && !$0.text.isEmpty
                }
                .sorted { $0.startTime < $1.startTime }
                .prefix(24)
                .map(\.text)
                .joined(separator: " ")
            let generated = try await bestEffort {
                try await generator.chapterTitle(for: text)
            }
            try Task.checkCancellation()
            if let title = admittedLabel(generated, maximumLength: 40) {
                titles[chapter.startTime] = title
            }
        }
        return titles
    }

    func bestEffort<Value: Sendable>(
        _ operation: @Sendable () async throws -> Value?
    ) async throws -> Value? {
        do {
            return try await operation()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return nil
        }
    }

    func admittedLabel(_ value: String?, maximumLength: Int) -> String? {
        guard let value else { return nil }
        let label = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty,
              label.count <= maximumLength,
              !label.contains("\n")
        else { return nil }
        return label
    }
}
