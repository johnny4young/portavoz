import ApplicationKit
import Foundation
import PortavozCore
import XCTest

@testable import portavoz_app

final class MeetingDetailReviewAccumulatorTests: XCTestCase {
    func testIndependentSectionsDegradeRecoverAndRetainHealthyCoreOnRestart() {
        let fixture = MeetingDetailAccumulatorFixture()
        var accumulator = MeetingDetailReviewAccumulator()
        let firstID = accumulator.beginObservation()

        var transition = accumulator.apply(.core(fixture.core))
        XCTAssertTrue(accumulator.accepts(observationID: firstID))
        XCTAssertEqual(transition.phase, .loading)
        XCTAssertEqual(transition.readModel?.meeting.id, fixture.meeting.id)

        _ = accumulator.apply(.summary(fixture.summary))
        _ = accumulator.apply(.companionCards([]))
        _ = accumulator.apply(.failed(.privacy))
        _ = accumulator.apply(.processingJobs([]))
        _ = accumulator.apply(.notes(MeetingReviewNotes()))
        transition = accumulator.apply(.commitmentReviewStates([]))
        XCTAssertEqual(transition.phase, .degraded(failures: 1))
        XCTAssertNotNil(transition.readModel)

        transition = accumulator.apply(.privacyReceipt(nil))
        XCTAssertEqual(transition.phase, .loaded)

        let secondID = accumulator.beginObservation()
        XCTAssertNotEqual(secondID, firstID)
        XCTAssertFalse(accumulator.accepts(observationID: firstID))
        _ = accumulator.apply(.failed(.core))
        _ = accumulator.apply(.summary(nil))
        _ = accumulator.apply(.companionCards([]))
        _ = accumulator.apply(.privacyReceipt(nil))
        _ = accumulator.apply(.processingJobs([]))
        _ = accumulator.apply(.notes(MeetingReviewNotes()))
        transition = accumulator.apply(.commitmentReviewStates([]))
        XCTAssertEqual(transition.phase, .degraded(failures: 1))
        XCTAssertEqual(transition.readModel?.meeting.id, fixture.meeting.id)
    }

    func testMissingMeetingAndUnrecoverableReadStayDistinct() {
        var missing = MeetingDetailReviewAccumulator()
        _ = missing.beginObservation()
        _ = missing.apply(.core(nil))
        for update in nonCoreSuccessUpdates {
            _ = missing.apply(update)
        }
        XCTAssertEqual(missing.apply(.commitmentReviewStates([])).phase, .missing)

        var failed = MeetingDetailReviewAccumulator()
        _ = failed.beginObservation()
        let transitions = MeetingReviewSection.allCases.map {
            failed.apply(.failed($0))
        }
        XCTAssertEqual(transitions.last?.phase, .failed)
        XCTAssertNil(transitions.last?.readModel)
    }

    func testCoreChangesEmitExactSuggestionAndPlaybackInvalidations() {
        let fixture = MeetingDetailAccumulatorFixture()
        var accumulator = MeetingDetailReviewAccumulator()
        _ = accumulator.beginObservation()

        var transition = accumulator.apply(.core(fixture.core))
        XCTAssertTrue(transition.correctionRevisionChanged)
        XCTAssertFalse(transition.shouldInvalidatePlayback)

        transition = accumulator.apply(.core(fixture.core))
        XCTAssertFalse(transition.correctionRevisionChanged)
        XCTAssertFalse(transition.shouldInvalidatePlayback)

        transition = accumulator.apply(.core(fixture.core(audioDirectory: "Audio/two")))
        XCTAssertFalse(transition.correctionRevisionChanged)
        XCTAssertTrue(transition.shouldInvalidatePlayback)

        transition = accumulator.apply(.core(fixture.core(
            audioDirectory: "Audio/two",
            correctionRevision: .unavailable)))
        XCTAssertTrue(transition.correctionRevisionChanged)
        XCTAssertFalse(transition.shouldInvalidatePlayback)

        transition = accumulator.apply(.core(nil))
        XCTAssertNil(transition.readModel)
        XCTAssertTrue(transition.shouldInvalidatePlayback)
    }

    func testMetadataSuggestionStateOwnsOneShotEligibilityAndRevisionReset() {
        let fixture = MeetingDetailAccumulatorFixture()
        var state = MeetingDetailMetadataSuggestionState()
        let review = fixture.readModel(title: "2026-08-09 Meeting")

        let first = state.begin(review: review, titledChapterStarts: [])
        XCTAssertEqual(first?.suggestsMeetingTitle, true)
        XCTAssertEqual(first?.suggestsRecipe, true)
        XCTAssertEqual(first?.request.suggestMeetingTitle, true)
        XCTAssertEqual(first?.request.suggestRecipe, true)
        XCTAssertEqual(first.map(state.accepts), true)

        state.invalidate(correctionRevisionChanged: false)
        XCTAssertEqual(first.map(state.accepts), false)
        let sameRevisionRetry = state.begin(
            review: review,
            titledChapterStarts: [0])
        XCTAssertEqual(sameRevisionRetry?.suggestsMeetingTitle, true)
        XCTAssertEqual(sameRevisionRetry?.suggestsRecipe, true)

        if let sameRevisionRetry { state.complete(sameRevisionRetry) }
        XCTAssertNil(state.begin(review: review, titledChapterStarts: [0]))

        state.invalidate(correctionRevisionChanged: true)
        let retry = state.begin(review: review, titledChapterStarts: [0])
        XCTAssertEqual(retry?.suggestsMeetingTitle, true)
        XCTAssertEqual(retry?.suggestsRecipe, true)
    }

    private var nonCoreSuccessUpdates: [MeetingReviewUpdate] {
        [
            .summary(nil),
            .companionCards([]),
            .privacyReceipt(nil),
            .processingJobs([]),
            .notes(MeetingReviewNotes())
        ]
    }
}

private struct MeetingDetailAccumulatorFixture {
    let meeting = Meeting(
        title: "Planning",
        startedAt: Date(timeIntervalSince1970: 1_700_000_000),
        audioDirectory: "Audio/one")

    var segment: TranscriptSegment {
        TranscriptSegment(
            meetingID: meeting.id,
            channel: .system,
            text: "Plan the next step.",
            startTime: 0,
            endTime: 2,
            isFinal: true)
    }

    var core: MeetingReviewCore {
        core(audioDirectory: meeting.audioDirectory)
    }

    func core(
        audioDirectory: String?,
        correctionRevision: TranscriptCorrectionRevision = .accepted
    ) -> MeetingReviewCore {
        var meeting = meeting
        meeting.audioDirectory = audioDirectory
        return MeetingReviewCore(
            meeting: meeting,
            speakers: [],
            segments: [segment],
            correctionRevision: correctionRevision)
    }

    var summary: MeetingReviewSummary {
        MeetingReviewSummary(
            draft: SummaryDraft(
                meetingID: meeting.id,
                recipeID: Recipe.general.id,
                language: "en",
                markdown: "## Summary",
                actionItems: []),
            version: 1)
    }

    func readModel(title: String) -> MeetingReviewReadModel {
        var meeting = meeting
        meeting.title = title
        return MeetingReviewReadModel(
            core: MeetingReviewCore(
                meeting: meeting,
                speakers: [],
                segments: [segment]),
            summary: summary,
            companionCards: [],
            privacyReceipt: nil,
            processingJobs: [])
    }
}
