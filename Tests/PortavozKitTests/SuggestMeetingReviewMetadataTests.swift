import ApplicationKit
import Foundation
import PortavozCore
import XCTest

final class SuggestMeetingReviewMetadataTests: XCTestCase {
    func testCoordinatesEligibleSuggestionsAndOnlyUntitledChapters() async throws {
        let review = makeReview(
            title: "2026-07-18 09.00 Meeting",
            recipeID: Recipe.general.id,
            segmentStarts: [0, 310])
        let recorder = MeetingMetadataGeneratorRecorder()
        let generator = MeetingMetadataGeneratorFake(
            recorder: recorder,
            chapterTitle: "  Next Steps  ",
            meetingTitle: "  Q3 Plan  ",
            recipe: .standup)

        let result = try await SuggestMeetingReviewMetadata(generator: generator).execute(
            SuggestMeetingReviewMetadataRequest(
                review: review,
                titledChapterStarts: [0]))

        XCTAssertEqual(result.meetingTitle, "Q3 Plan")
        XCTAssertEqual(result.recipe?.id, Recipe.standup.id)
        XCTAssertEqual(result.chapterTitles, [310: "Next Steps"])
        let calls = await recorder.calls
        XCTAssertEqual(calls.count, 3)
        XCTAssertEqual(calls[0], .recipe)
        XCTAssertEqual(calls[1], .meetingTitle)
        guard case .chapter(let text) = calls[2] else {
            return XCTFail("only the untitled chapter should reach generation")
        }
        XCTAssertTrue(text.contains("segment 2"))
        XCTAssertFalse(text.contains("segment 1"))
    }

    func testUnavailableGeneratorDoesNotEnterAnyCapability() async throws {
        let recorder = MeetingMetadataGeneratorRecorder()
        let generator = MeetingMetadataGeneratorFake(
            isAvailable: false,
            recorder: recorder,
            chapterTitle: "Chapter",
            meetingTitle: "Meeting",
            recipe: .standup)

        let result = try await SuggestMeetingReviewMetadata(generator: generator).execute(
            SuggestMeetingReviewMetadataRequest(
                review: makeReview(
                    title: "2026-07-18 Meeting",
                    recipeID: Recipe.general.id,
                    segmentStarts: [0, 310])))

        XCTAssertNil(result.meetingTitle)
        XCTAssertNil(result.recipe)
        XCTAssertTrue(result.chapterTitles.isEmpty)
        let calls = await recorder.calls
        XCTAssertTrue(calls.isEmpty)
    }

    func testDomainEligibilitySkipsTitleAndRecipeWithoutCallingGenerator() async throws {
        let recorder = MeetingMetadataGeneratorRecorder()
        let generator = MeetingMetadataGeneratorFake(
            recorder: recorder,
            chapterTitle: "Unused",
            meetingTitle: "Unused",
            recipe: .standup)

        let result = try await SuggestMeetingReviewMetadata(generator: generator).execute(
            SuggestMeetingReviewMetadataRequest(
                review: makeReview(
                    title: "User title",
                    recipeID: Recipe.planning.id,
                    segmentStarts: [0])))

        XCTAssertNil(result.meetingTitle)
        XCTAssertNil(result.recipe)
        XCTAssertTrue(result.chapterTitles.isEmpty)
        let calls = await recorder.calls
        XCTAssertTrue(calls.isEmpty)
    }

    func testInvalidAndFailedOptionalOutputsDegradeIndependently() async throws {
        let recorder = MeetingMetadataGeneratorRecorder()
        let unknownRecipe = Recipe(
            id: "unknown",
            displayName: "Unknown",
            sections: ["Unknown"],
            instructions: "Unknown")
        let generator = MeetingMetadataGeneratorFake(
            recorder: recorder,
            chapterTitle: "Ignored",
            meetingTitle: "invalid\nmeeting title",
            recipe: unknownRecipe,
            failures: [.chapter])

        let result = try await SuggestMeetingReviewMetadata(generator: generator).execute(
            SuggestMeetingReviewMetadataRequest(
                review: makeReview(
                    title: "2026-07-18 Meeting",
                    recipeID: Recipe.general.id,
                    segmentStarts: [0, 310])))

        XCTAssertNil(result.meetingTitle)
        XCTAssertNil(result.recipe)
        XCTAssertTrue(result.chapterTitles.isEmpty)
        let calls = await recorder.calls
        XCTAssertEqual(calls.count, 4)
    }

    func testCancellationRemainsCancellationForTheFeatureOwnerToRetry() async {
        let generator = MeetingMetadataGeneratorFake(
            recorder: MeetingMetadataGeneratorRecorder(),
            recipe: .standup,
            cancellations: [.recipe])

        do {
            _ = try await SuggestMeetingReviewMetadata(generator: generator).execute(
                SuggestMeetingReviewMetadataRequest(
                    review: makeReview(
                        title: "2026-07-18 Meeting",
                        recipeID: Recipe.general.id,
                        segmentStarts: [0])))
            XCTFail("cancellation must not become an empty successful suggestion")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    private func makeReview(
        title: String,
        recipeID: String,
        segmentStarts: [TimeInterval]
    ) -> MeetingReviewReadModel {
        let meeting = Meeting(title: title, startedAt: Date(timeIntervalSince1970: 1_000))
        let speaker = Speaker(meetingID: meeting.id, label: "S1", displayName: "Ana")
        let segments = segmentStarts.enumerated().map { index, start in
            TranscriptSegment(
                meetingID: meeting.id,
                speakerID: speaker.id,
                channel: .system,
                text: "Substantial transcript segment \(index + 1) for metadata generation.",
                startTime: start,
                endTime: start + 2,
                isFinal: true)
        }
        return MeetingReviewReadModel(
            core: MeetingReviewCore(
                meeting: meeting,
                speakers: [speaker],
                segments: segments),
            summary: MeetingReviewSummary(
                draft: SummaryDraft(
                    meetingID: meeting.id,
                    recipeID: recipeID,
                    language: "en",
                    markdown: "## Summary\nA sufficiently detailed summary for a title.",
                    actionItems: []),
                version: 1),
            companionCards: [],
            privacyReceipt: nil,
            processingJobs: [])
    }
}

private enum MeetingMetadataGeneratorOperation: Hashable, Sendable {
    case recipe
    case meetingTitle
    case chapter
}

private enum MeetingMetadataGeneratorCall: Equatable, Sendable {
    case recipe
    case meetingTitle
    case chapter(String)
}

private enum MeetingMetadataGeneratorError: Error {
    case failed
}

private actor MeetingMetadataGeneratorRecorder {
    private(set) var calls: [MeetingMetadataGeneratorCall] = []

    func append(_ call: MeetingMetadataGeneratorCall) {
        calls.append(call)
    }
}

private struct MeetingMetadataGeneratorFake: MeetingReviewMetadataGenerating {
    let isAvailable: Bool
    let recorder: MeetingMetadataGeneratorRecorder
    let chapterTitleResult: String?
    let meetingTitleResult: String?
    let recipeResult: Recipe?
    let failures: Set<MeetingMetadataGeneratorOperation>
    let cancellations: Set<MeetingMetadataGeneratorOperation>

    init(
        isAvailable: Bool = true,
        recorder: MeetingMetadataGeneratorRecorder,
        chapterTitle: String? = nil,
        meetingTitle: String? = nil,
        recipe: Recipe? = nil,
        failures: Set<MeetingMetadataGeneratorOperation> = [],
        cancellations: Set<MeetingMetadataGeneratorOperation> = []
    ) {
        self.isAvailable = isAvailable
        self.recorder = recorder
        chapterTitleResult = chapterTitle
        meetingTitleResult = meetingTitle
        recipeResult = recipe
        self.failures = failures
        self.cancellations = cancellations
    }

    func chapterTitle(for text: String) async throws -> String? {
        await recorder.append(.chapter(text))
        try failIfNeeded(.chapter)
        return chapterTitleResult
    }

    func meetingTitle(
        summaryMarkdown: String,
        currentTitle: String
    ) async throws -> String? {
        await recorder.append(.meetingTitle)
        try failIfNeeded(.meetingTitle)
        return meetingTitleResult
    }

    func meetingRecipe(
        segments: [TranscriptSegment],
        speakerCount: Int
    ) async throws -> Recipe? {
        await recorder.append(.recipe)
        try failIfNeeded(.recipe)
        return recipeResult
    }

    private func failIfNeeded(_ operation: MeetingMetadataGeneratorOperation) throws {
        if cancellations.contains(operation) { throw CancellationError() }
        if failures.contains(operation) { throw MeetingMetadataGeneratorError.failed }
    }
}
