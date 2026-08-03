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
}

@MainActor
private final class CommitmentRadarModelClientFake: CommitmentRadarModelClient {
    enum Failure: Error {
        case unavailable
    }

    var responses: [Result<CommitmentRadarPage, Failure>]
    var mutationResponses: [Result<Void, Failure>]
    var requests: [LoadCommitmentRadarRequest] = []
    var mutations: [ManageCommitmentRadarRequest] = []

    init(
        responses: [Result<CommitmentRadarPage, Failure>],
        mutationResponses: [Result<Void, Failure>]
    ) {
        self.responses = responses
        self.mutationResponses = mutationResponses
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
}
