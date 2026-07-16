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
        XCTAssertEqual(client.calls, [.observe(fixture.meeting.id)])
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

    func testMutationActionsOwnPersistenceEffectsAndSearchInvalidation() async {
        let fixture = MeetingDetailModelFixture()
        let client = MeetingDetailModelClientFake(updates: [])
        let model = MeetingDetailModel(meetingID: fixture.meeting.id, client: client)

        await model.send(.renameMeeting(fixture.meeting, title: "Weekly planning"))
        let nameEffect = await model.send(
            .acceptNameSuggestion(fixture.speaker, name: "Ana"))
        let voiceEffect = await model.send(
            .acceptVoiceSuggestion(fixture.speaker, name: "Bea"))
        let renameEffect = await model.send(
            .renameSpeaker(fixture.speaker, name: "Carla"))
        await model.send(.setActionItem(fixture.actionItem.id, done: true))
        await model.send(.removeCompanionCard(fixture.card.id))
        await model.send(.searchableContentChanged)
        let deleteEffect = await model.send(.deleteMeeting)

        XCTAssertEqual(client.calls, [
            .renameMeeting("Weekly planning"),
            .renameSpeaker("Ana"),
            .renameSpeaker("Bea"),
            .renameSpeaker("Carla"),
            .setActionItem(fixture.actionItem.id, true),
            .deleteCompanion(fixture.card.id),
            .deleteMeeting(fixture.meeting.id),
        ])
        XCTAssertEqual(client.searchReindexRequests, 7)
        XCTAssertEqual(effectSpeakerName(nameEffect), "Ana")
        XCTAssertEqual(effectSpeakerName(voiceEffect), "Bea")
        XCTAssertEqual(effectSpeakerName(renameEffect), "Carla")
        guard case .meetingDeleted(let id) = deleteEffect else {
            return XCTFail("delete must preserve the navigation effect")
        }
        XCTAssertEqual(id, fixture.meeting.id)
        XCTAssertNil(model.state.lastActionError)
    }

    func testMutationFailuresPreserveSilentAndVisiblePolicies() async {
        let fixture = MeetingDetailModelFixture()
        let client = MeetingDetailModelClientFake(updates: [])
        client.failures = Set(MeetingDetailModelFailure.allCases)
        let model = MeetingDetailModel(meetingID: fixture.meeting.id, client: client)

        await model.send(.renameMeeting(fixture.meeting, title: "Ignored failure"))
        let nameEffect = await model.send(
            .acceptNameSuggestion(fixture.speaker, name: "Ana"))
        let voiceEffect = await model.send(
            .acceptVoiceSuggestion(fixture.speaker, name: "Bea"))
        await model.send(.setActionItem(fixture.actionItem.id, done: true))
        let deleteEffect = await model.send(.deleteMeeting)

        XCTAssertEqual(effectSpeakerName(nameEffect), "Ana")
        XCTAssertEqual(effectSpeakerName(voiceEffect), "Bea")
        guard case .meetingDeleted = deleteEffect else {
            return XCTFail("best-effort delete must preserve its navigation effect")
        }
        XCTAssertNil(model.state.lastActionError)
        XCTAssertEqual(client.searchReindexRequests, 5)

        let renameEffect = await model.send(
            .renameSpeaker(fixture.speaker, name: "Carla"))
        XCTAssertNil(renameEffect)
        XCTAssertEqual(
            model.state.lastActionError,
            L10n.format(
                "Could not rename: %@",
                MeetingDetailModelFailure.renameSpeaker.localizedDescription))
        XCTAssertEqual(client.searchReindexRequests, 5)

        await model.send(.removeCompanionCard(fixture.card.id))
        XCTAssertEqual(
            model.state.lastActionError,
            L10n.text("Could not remove the card."))
        XCTAssertEqual(client.searchReindexRequests, 5)
    }

    private func effectSpeakerName(_ effect: MeetingDetailModel.Effect?) -> String? {
        switch effect {
        case .nameSuggestionAccepted(let speaker),
            .voiceSuggestionAccepted(let speaker),
            .speakerRenamed(let speaker):
            speaker.displayName
        default:
            nil
        }
    }
}

private struct MeetingDetailModelFixture {
    let meeting: Meeting
    let speaker: Speaker
    let segment: TranscriptSegment
    let card: CompanionCard
    let actionItem: ActionItem

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
        actionItem = ActionItem(text: "Publicar")
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
    var calls: [MeetingDetailModelCall] = []
    var failures: Set<MeetingDetailModelFailure> = []
    var searchReindexRequests = 0

    init(updates: [MeetingReviewUpdate]) {
        self.updates = updates
    }

    func observeMeetingReview(
        _ meetingID: MeetingID
    ) -> AsyncStream<MeetingReviewUpdate> {
        calls.append(.observe(meetingID))
        return AsyncStream { continuation in
            for update in updates { continuation.yield(update) }
            continuation.finish()
        }
    }

    func renameMeetingDetailMeeting(_ meeting: Meeting) throws {
        calls.append(.renameMeeting(meeting.title))
        try fail(.renameMeeting)
    }

    func renameMeetingDetailSpeaker(_ speaker: Speaker) throws {
        calls.append(.renameSpeaker(speaker.displayName))
        try fail(.renameSpeaker)
    }

    func setMeetingDetailActionItem(_ id: UUID, done: Bool) throws {
        calls.append(.setActionItem(id, done))
        try fail(.setActionItem)
    }

    func deleteMeetingDetailCompanionCard(_ id: UUID) throws {
        calls.append(.deleteCompanion(id))
        try fail(.deleteCompanion)
    }

    func deleteMeetingDetail(_ id: MeetingID) throws {
        calls.append(.deleteMeeting(id))
        try fail(.deleteMeeting)
    }

    func requestMeetingDetailSearchReindex() {
        searchReindexRequests += 1
    }

    private func fail(_ failure: MeetingDetailModelFailure) throws {
        if failures.contains(failure) { throw failure }
    }
}

private enum MeetingDetailModelFailure: String, CaseIterable, Error, LocalizedError {
    case renameMeeting
    case renameSpeaker
    case setActionItem
    case deleteCompanion
    case deleteMeeting

    var errorDescription: String? { "meeting-detail-model-\(rawValue)" }
}

private enum MeetingDetailModelCall: Equatable {
    case observe(MeetingID)
    case renameMeeting(String)
    case renameSpeaker(String?)
    case setActionItem(UUID, Bool)
    case deleteCompanion(UUID)
    case deleteMeeting(MeetingID)
}
