import ApplicationKit
import Foundation
import IntelligenceKit
import PortavozCore

extension AppServices {
    func meetingDetailMetadataSuggestions(
        _ request: SuggestMeetingReviewMetadataRequest
    ) async throws -> MeetingReviewMetadataSuggestions {
        try await SuggestMeetingReviewMetadata(
            generator: AppMeetingReviewMetadataGenerator(
                isAvailable: !ProcessInfo.processInfo.arguments.contains("-seed-scale")
                    && foundationModelsCapability.isAvailable)
        ).execute(request)
    }
}

/// Owns the concrete Foundation Models generators and the app's deterministic
/// scale-fixture exclusion. ApplicationKit receives only capability-neutral
/// optional values and independently admits them before presentation.
private struct AppMeetingReviewMetadataGenerator: MeetingReviewMetadataGenerating {
    let isAvailable: Bool

    func chapterTitle(for text: String) async throws -> String? {
        guard isAvailable else { return nil }
        guard #available(macOS 26.0, *) else { return nil }
        let result = await ChapterTitler.title(forChapterText: text)
        try Task.checkCancellation()
        return result
    }

    func meetingTitle(
        summaryMarkdown: String,
        currentTitle: String
    ) async throws -> String? {
        guard isAvailable else { return nil }
        guard #available(macOS 26.0, *) else { return nil }
        let result = await TitleSuggester.suggest(
            summaryMarkdown: summaryMarkdown,
            currentTitle: currentTitle)
        try Task.checkCancellation()
        return result
    }

    func meetingRecipe(
        segments: [TranscriptSegment],
        speakerCount: Int
    ) async throws -> Recipe? {
        guard isAvailable else { return nil }
        guard #available(macOS 26.0, *) else { return nil }
        let result = await MeetingTypeDetector.detect(
            segments: segments,
            speakerCount: speakerCount)
        try Task.checkCancellation()
        return result
    }
}
