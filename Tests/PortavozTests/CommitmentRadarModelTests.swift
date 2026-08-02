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
        ])
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
        let client = CommitmentRadarModelClientFake(responses: [])
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
        ])
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

    private static func page(title: String) -> CommitmentRadarPage {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let item = CommitmentRadarItem(
            commitment: Commitment(
                title: title,
                assignee: .me,
                createdAt: date),
            assigneeDisplayName: nil,
            activity: .new,
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
    var requests: [LoadCommitmentRadarRequest] = []

    init(responses: [Result<CommitmentRadarPage, Failure>]) {
        self.responses = responses
    }

    func loadCommitmentRadar(
        _ request: LoadCommitmentRadarRequest
    ) async throws -> CommitmentRadarPage {
        requests.append(request)
        return try responses.removeFirst().get()
    }
}
