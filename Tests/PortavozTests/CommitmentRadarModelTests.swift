import ApplicationKit
import Foundation
import PortavozCore
import XCTest

@testable import portavoz_app

@MainActor
final class CommitmentRadarModelTests: XCTestCase {
    func testLoadPublishesConfirmedPageAndMapsIndependentFilters() async throws {
        let page = Self.page(title: "Send the rollout brief")
        let client = CommitmentRadarModelClientFake(responses: [
            .success(page),
            .success(CommitmentRadarPage(items: [], totalCount: 0)),
            .success(page),
            .success(page),
        ], mutationResponses: [])
        let model = CommitmentRadarModel(client: client)

        await model.send(.load)
        XCTAssertEqual(model.state.phase, .loaded)
        XCTAssertEqual(model.state.page, page)

        await model.send(.ownerChanged(.mine))
        XCTAssertEqual(model.state.phase, .empty)
        await model.send(.dueChanged(.overdue))
        await model.send(.activityChanged(.reopened))

        XCTAssertEqual(client.requests.count, 4)
        XCTAssertEqual(client.requests[0], LoadCommitmentRadarRequest())
        XCTAssertEqual(client.requests[1].owner, .mine)
        XCTAssertEqual(client.requests[2].due, .overdue)
        XCTAssertEqual(client.requests[3].activity, .activity(.reopened))
    }

    func testGroupingIsPresentationOnlyAndDoesNotReloadStorage() async {
        let client = CommitmentRadarModelClientFake(
            responses: [],
            mutationResponses: [])
        let model = CommitmentRadarModel(client: client)

        await model.send(.groupingChanged(.meeting))

        XCTAssertEqual(model.state.grouping, .meeting)
        XCTAssertTrue(client.requests.isEmpty)
        XCTAssertEqual(model.state.phase, .idle)
    }

    func testFailureClearsStalePageAndRetryCanRecover() async {
        let page = Self.page(title: "Recheck the launch checklist")
        let client = CommitmentRadarModelClientFake(responses: [
            .success(page),
            .failure(.unavailable),
            .success(page),
        ], mutationResponses: [])
        let model = CommitmentRadarModel(client: client)

        await model.send(.load)
        XCTAssertEqual(model.state.page, page)
        await model.send(.load)
        XCTAssertEqual(model.state.phase, .failed)
        XCTAssertNil(model.state.page)
        await model.send(.load)
        XCTAssertEqual(model.state.phase, .loaded)
        XCTAssertEqual(model.state.page, page)
    }

    func testCompleteMutatesDurableTruthAndReloadsWithoutDiscardingThePage() async {
        let open = Self.page(title: "Send the rollout brief")
        let completed = Self.page(
            title: "Send the rollout brief",
            status: .done,
            activity: .completed)
        let client = CommitmentRadarModelClientFake(
            responses: [.success(open), .success(completed)],
            mutationResponses: [.success(())])
        let model = CommitmentRadarModel(client: client)

        await model.send(.load)
        let commitmentID = open.items[0].id
        await model.send(.complete(commitmentID))

        XCTAssertEqual(client.mutations, [ManageCommitmentRadarRequest(
            commitmentID: commitmentID,
            mutation: .complete)])
        XCTAssertEqual(model.state.phase, .loaded)
        XCTAssertEqual(model.state.page, completed)
        XCTAssertNil(model.state.mutatingCommitmentID)
        XCTAssertFalse(model.state.mutationFailed)
    }

    func testMutationFailurePreservesVisiblePageAndCanBeDismissed() async {
        let page = Self.page(title: "Recheck the launch checklist")
        let client = CommitmentRadarModelClientFake(
            responses: [.success(page)],
            mutationResponses: [.failure(.unavailable)])
        let model = CommitmentRadarModel(client: client)

        await model.send(.load)
        await model.send(.reopen(page.items[0].id))

        XCTAssertEqual(model.state.page, page)
        XCTAssertEqual(model.state.phase, .loaded)
        XCTAssertTrue(model.state.mutationFailed)
        await model.send(.dismissMutationFailure)
        XCTAssertFalse(model.state.mutationFailed)
    }

    func testReviewModeLoadsItsOwnPageWithoutReplacingConfirmedState() async {
        let confirmed = Self.page(title: "Send the rollout brief")
        let review = Self.reviewPage(title: "Send the launch checklist")
        let client = CommitmentRadarModelClientFake(
            responses: [.success(confirmed)],
            mutationResponses: [],
            reviewResponses: [.success(review)],
            reviewMutationResponses: [])
        let model = CommitmentRadarModel(client: client)

        await model.send(.load)
        await model.send(.modeChanged(.review))

        XCTAssertEqual(model.state.mode, .review)
        XCTAssertEqual(model.state.phase, .loaded)
        XCTAssertEqual(model.state.page?.items.first?.commitment.title,
                       "Send the rollout brief")
        XCTAssertEqual(model.state.reviewPhase, .loaded)
        XCTAssertEqual(model.state.reviewPage?.items.map(\.id),
                       review.items.map(\.id))
        XCTAssertEqual(client.requests.count, 1)
        XCTAssertEqual(client.reviewRequests, [LoadCommitmentReviewQueueRequest()])
    }

    func testReviewDismissUsesExistingBoundaryAndReloadsOnlyReviewQueue() async throws {
        let review = Self.reviewPage(title: "Send the launch checklist")
        let client = CommitmentRadarModelClientFake(
            responses: [],
            mutationResponses: [],
            reviewResponses: [
                .success(review),
                .success(CommitmentReviewQueuePage(items: [], totalCount: 0)),
            ],
            reviewMutationResponses: [.success(())])
        let model = CommitmentRadarModel(client: client)
        let item = try XCTUnwrap(review.items.first)

        await model.send(.modeChanged(.review))
        await model.send(.dismissReview(
            meetingID: item.meetingID,
            actionItemID: item.id))

        XCTAssertEqual(client.reviewMutations, [.dismiss(
            meetingID: item.meetingID,
            actionItemID: item.id)])
        XCTAssertEqual(model.state.reviewPhase, .empty)
        XCTAssertEqual(model.state.reviewPage?.items.count, 0)
        XCTAssertNil(model.state.reviewingActionItemID)
        XCTAssertTrue(client.mutations.isEmpty)
    }

    func testReviewFailureDoesNotReplaceConfirmedFailureState() async throws {
        let review = Self.reviewPage(title: "Send the launch checklist")
        let client = CommitmentRadarModelClientFake(
            responses: [],
            mutationResponses: [],
            reviewResponses: [.success(review)],
            reviewMutationResponses: [.failure(.unavailable)])
        let model = CommitmentRadarModel(client: client)
        let item = try XCTUnwrap(review.items.first)

        await model.send(.modeChanged(.review))
        await model.send(.deferReview(
            meetingID: item.meetingID,
            actionItemID: item.id,
            revisitAt: Date(timeIntervalSince1970: 1_900_000_000)))

        XCTAssertTrue(model.state.reviewMutationFailed)
        XCTAssertFalse(model.state.mutationFailed)
        XCTAssertEqual(model.state.reviewPage?.items.map(\.id), [item.id])
        await model.send(.dismissReviewMutationFailure)
        XCTAssertFalse(model.state.reviewMutationFailed)
    }

    private static func page(
        title: String,
        status: CommitmentStatus = .confirmed,
        activity: CommitmentRadarActivity = .new
    ) -> CommitmentRadarPage {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let item = CommitmentRadarItem(
            commitment: Commitment(
                title: title,
                status: status,
                assignee: .me,
                createdAt: date),
            assigneeDisplayName: nil,
            activity: activity,
            sources: [],
            sourceCount: 0,
            history: [],
            historyCount: 0)
        return CommitmentRadarPage(items: [item], totalCount: 1)
    }

    private static func reviewPage(title: String) -> CommitmentReviewQueuePage {
        let meetingID = MeetingID()
        let speaker = Speaker(meetingID: meetingID, label: "S1")
        let segment = TranscriptSegment(
            meetingID: meetingID,
            speakerID: speaker.id,
            channel: .system,
            text: "I will send the launch checklist.",
            startTime: 3,
            endTime: 6,
            isFinal: true)
        let item = CommitmentReviewQueueItem(
            meetingID: meetingID,
            meetingTitle: "Launch review",
            meetingStartedAt: Date(timeIntervalSince1970: 1_800_000_000),
            meetingEndedAt: Date(timeIntervalSince1970: 1_800_000_600),
            actionItem: ActionItem(text: title, ownerSpeakerID: speaker.id),
            evidence: TranscriptEvidenceResolution(
                status: .current,
                segments: [segment]),
            evidenceCount: 1,
            suggestedOwner: nil,
            reason: .newAfterMeeting)
        return CommitmentReviewQueuePage(items: [item], totalCount: 1)
    }
}

@MainActor
private final class CommitmentRadarModelClientFake: CommitmentRadarModelClient {
    enum Failure: Error {
        case unavailable
    }

    var responses: [Result<CommitmentRadarPage, Failure>]
    var mutationResponses: [Result<Void, Failure>]
    var reviewResponses: [Result<CommitmentReviewQueuePage, Failure>]
    var reviewMutationResponses: [Result<Void, Failure>]
    var requests: [LoadCommitmentRadarRequest] = []
    var mutations: [ManageCommitmentRadarRequest] = []
    var reviewRequests: [LoadCommitmentReviewQueueRequest] = []
    var reviewMutations: [ReviewMeetingCommitmentRequest] = []

    init(
        responses: [Result<CommitmentRadarPage, Failure>],
        mutationResponses: [Result<Void, Failure>],
        reviewResponses: [Result<CommitmentReviewQueuePage, Failure>] = [],
        reviewMutationResponses: [Result<Void, Failure>] = []
    ) {
        self.responses = responses
        self.mutationResponses = mutationResponses
        self.reviewResponses = reviewResponses
        self.reviewMutationResponses = reviewMutationResponses
    }

    func loadCommitmentRadar(
        _ request: LoadCommitmentRadarRequest
    ) async throws -> CommitmentRadarPage {
        requests.append(request)
        return try responses.removeFirst().get()
    }

    func mutateCommitmentRadar(
        _ request: ManageCommitmentRadarRequest
    ) async throws {
        mutations.append(request)
        return try mutationResponses.removeFirst().get()
    }

    func loadCommitmentReviewQueue(
        _ request: LoadCommitmentReviewQueueRequest
    ) async throws -> CommitmentReviewQueuePage {
        reviewRequests.append(request)
        return try reviewResponses.removeFirst().get()
    }

    func reviewMeetingCommitment(
        _ request: ReviewMeetingCommitmentRequest
    ) async throws {
        reviewMutations.append(request)
        return try reviewMutationResponses.removeFirst().get()
    }
}
