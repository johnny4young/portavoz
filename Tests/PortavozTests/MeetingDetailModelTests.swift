import ApplicationKit
import Foundation
import PortavozCore
import XCTest

@testable import portavoz_app

@MainActor
final class MeetingDetailModelTests: XCTestCase {
    func testObservationPublishesOneCompleteReviewProjection() async throws {
        let fixture = MeetingDetailModelFixture()
        let client = MeetingDetailModelClientFake(updates: fixture.updates)
        let model = MeetingDetailModel(meetingID: fixture.meeting.id, client: client)

        await model.observe()

        XCTAssertEqual(model.state.phase, .loaded)
        XCTAssertEqual(model.state.readModel?.meeting.id, fixture.meeting.id)
        XCTAssertEqual(model.state.readModel?.speakers.map(\.id), [fixture.speaker.id])
        XCTAssertEqual(model.state.readModel?.segments.map(\.id), [fixture.segment.id])
        XCTAssertEqual(model.state.readModel?.summary?.version, 2)
        XCTAssertEqual(model.state.readModel?.companionCards.map(\.id), [fixture.card.id])
        XCTAssertEqual(client.calls, [fixture.meeting.id])
    }

    func testPartialFailurePreservesHealthySections() async {
        let fixture = MeetingDetailModelFixture()
        let client = MeetingDetailModelClientFake(updates: [
            .core(fixture.core),
            .failed(.summary),
            .companionCards([fixture.card]),
        ])
        let model = MeetingDetailModel(meetingID: fixture.meeting.id, client: client)

        await model.observe()

        XCTAssertEqual(model.state.phase, .degraded(failures: 1))
        XCTAssertEqual(model.state.readModel?.segments.map(\.id), [fixture.segment.id])
        XCTAssertNil(model.state.readModel?.summary)
        XCTAssertEqual(model.state.readModel?.companionCards.map(\.id), [fixture.card.id])
    }

    func testMissingMeetingIsDistinctFromReadFailure() async {
        let fixture = MeetingDetailModelFixture()
        let missingClient = MeetingDetailModelClientFake(updates: [
            .core(nil), .summary(nil), .companionCards([]),
        ])
        let missing = MeetingDetailModel(
            meetingID: fixture.meeting.id,
            client: missingClient)
        await missing.observe()

        let failedClient = MeetingDetailModelClientFake(
            updates: MeetingReviewSection.allCases.map(MeetingReviewUpdate.failed))
        let failed = MeetingDetailModel(
            meetingID: fixture.meeting.id,
            client: failedClient)
        await failed.observe()

        XCTAssertEqual(missing.state.phase, .missing)
        XCTAssertNil(missing.state.readModel)
        XCTAssertEqual(failed.state.phase, .failed)
        XCTAssertNil(failed.state.readModel)
    }

    func testLaterUpdateReplacesOnlyItsProjection() async {
        let fixture = MeetingDetailModelFixture()
        let replacement = MeetingReviewSummary(
            draft: SummaryDraft(
                meetingID: fixture.meeting.id,
                recipeID: Recipe.standup.id,
                language: "es",
                markdown: "## Nuevo",
                actionItems: []),
            version: 1)
        let client = MeetingDetailModelClientFake(updates: fixture.updates + [
            .summary(replacement),
        ])
        let model = MeetingDetailModel(meetingID: fixture.meeting.id, client: client)

        await model.observe()

        XCTAssertEqual(model.state.readModel?.summary?.draft.recipeID, Recipe.standup.id)
        XCTAssertEqual(model.state.readModel?.summary?.version, 1)
        XCTAssertEqual(model.state.readModel?.segments.map(\.id), [fixture.segment.id])
        XCTAssertEqual(model.state.readModel?.companionCards.map(\.id), [fixture.card.id])
        XCTAssertEqual(model.state.revision, 4)
    }
}

private struct MeetingDetailModelFixture {
    let meeting: Meeting
    let speaker: Speaker
    let segment: TranscriptSegment
    let card: CompanionCard

    init() {
        meeting = Meeting(title: "Planning", startedAt: Date())
        speaker = Speaker(meetingID: meeting.id, label: "S1", displayName: "Ana")
        segment = TranscriptSegment(
            meetingID: meeting.id,
            speakerID: speaker.id,
            channel: .system,
            text: "El viernes.",
            startTime: 0,
            endTime: 2,
            isFinal: true)
        card = CompanionCard(
            question: "¿Cuándo?",
            answer: "El viernes.",
            kind: .context,
            source: "meeting",
            askedAt: 1)
    }

    var core: MeetingReviewCore {
        MeetingReviewCore(
            meeting: meeting,
            speakers: [speaker],
            segments: [segment])
    }

    var summary: MeetingReviewSummary {
        MeetingReviewSummary(
            draft: SummaryDraft(
                meetingID: meeting.id,
                recipeID: Recipe.general.id,
                language: "es",
                markdown: "## Resumen",
                actionItems: []),
            version: 2)
    }

    var updates: [MeetingReviewUpdate] {
        [.core(core), .summary(summary), .companionCards([card])]
    }
}

@MainActor
private final class MeetingDetailModelClientFake: MeetingDetailModelClient {
    let updates: [MeetingReviewUpdate]
    var calls: [MeetingID] = []

    init(updates: [MeetingReviewUpdate]) {
        self.updates = updates
    }

    func observeMeetingReview(
        _ meetingID: MeetingID
    ) -> AsyncStream<MeetingReviewUpdate> {
        calls.append(meetingID)
        return AsyncStream { continuation in
            for update in updates { continuation.yield(update) }
            continuation.finish()
        }
    }
}
