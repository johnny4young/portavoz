import ApplicationKit
import Foundation
import PortavozCore
import XCTest

@testable import portavoz_app

@MainActor
final class ReminderDraftModelTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testOpeningAnOfferChecksWithoutPromptingAndShowsExactDraft() async throws {
        let offer = try XCTUnwrap(ReminderDraftOffer(commitment: commitment()))
        let client = ReminderDraftModelClientFake(
            surface: surface(offer: offer),
            authorization: .notDetermined)
        let model = ReminderDraftModel(client: client)

        await model.load(commitments: [offer.commitment])
        await model.open(offer.commitment.id)

        XCTAssertEqual(client.authorizationChecks, 1)
        XCTAssertEqual(client.permissionRequests, 0)
        XCTAssertEqual(model.state.confirmation?.offer, offer)
        XCTAssertEqual(model.state.confirmation?.offer.draft, ReminderDraft(
            title: "Send the signed package",
            dueAt: now.addingTimeInterval(3_600),
            commitmentID: offer.commitment.id))
        XCTAssertEqual(model.state.confirmation?.authorization, .notDetermined)
        XCTAssertNil(model.state.confirmation?.target)
    }

    func testExplicitPermissionActionResolvesTheExactDefaultList() async throws {
        let offer = try XCTUnwrap(ReminderDraftOffer(commitment: commitment()))
        let target = try XCTUnwrap(AppReminderDraftTarget(
            identifier: "opaque-list-42",
            title: "Work"))
        let client = ReminderDraftModelClientFake(
            surface: surface(offer: offer),
            authorization: .notDetermined,
            requestedAuthorization: .fullAccess,
            defaultTarget: target)
        let model = ReminderDraftModel(client: client)
        await model.load(commitments: [offer.commitment])
        await model.open(offer.commitment.id)

        await model.requestAccess()

        XCTAssertEqual(client.permissionRequests, 1)
        XCTAssertEqual(client.defaultTargetRequests, 1)
        XCTAssertEqual(model.state.confirmation?.authorization, .fullAccess)
        XCTAssertEqual(model.state.confirmation?.target, target)
        XCTAssertEqual(model.state.confirmation?.phase, .ready)
        XCTAssertNil(model.state.confirmation?.failure)
    }

    func testAlreadyAuthorizedOpenNeverRequestsAndMissingDefaultListFailsClosed() async throws {
        let offer = try XCTUnwrap(ReminderDraftOffer(commitment: commitment()))
        let client = ReminderDraftModelClientFake(
            surface: surface(offer: offer),
            authorization: .fullAccess,
            defaultTarget: nil)
        let model = ReminderDraftModel(client: client)
        await model.load(commitments: [offer.commitment])

        await model.open(offer.commitment.id)

        XCTAssertEqual(client.permissionRequests, 0)
        XCTAssertEqual(client.defaultTargetRequests, 1)
        XCTAssertEqual(model.state.confirmation?.authorization, .fullAccess)
        XCTAssertNil(model.state.confirmation?.target)
        XCTAssertNotNil(model.state.confirmation?.failure)
    }

    func testDeniedPermissionNeverResolvesATargetOrEnablesConfirmation() async throws {
        let offer = try XCTUnwrap(ReminderDraftOffer(commitment: commitment()))
        let target = try XCTUnwrap(AppReminderDraftTarget(
            identifier: "opaque-list-42",
            title: "Work"))
        let client = ReminderDraftModelClientFake(
            surface: surface(offer: offer),
            authorization: .notDetermined,
            requestedAuthorization: .denied,
            defaultTarget: target)
        let model = ReminderDraftModel(client: client)
        await model.load(commitments: [offer.commitment])
        await model.open(offer.commitment.id)

        await model.requestAccess()

        XCTAssertEqual(client.permissionRequests, 1)
        XCTAssertEqual(client.defaultTargetRequests, 0)
        XCTAssertEqual(model.state.confirmation?.authorization, .denied)
        XCTAssertNil(model.state.confirmation?.target)
        XCTAssertEqual(model.state.confirmation?.phase, .ready)
    }

    func testExplicitRefreshRebindsAChangedDefaultListWithoutPrompting() async throws {
        let offer = try XCTUnwrap(ReminderDraftOffer(commitment: commitment()))
        let first = try XCTUnwrap(AppReminderDraftTarget(
            identifier: "opaque-list-42",
            title: "Work"))
        let renamed = try XCTUnwrap(AppReminderDraftTarget(
            identifier: "opaque-list-42",
            title: "Renamed work"))
        let client = ReminderDraftModelClientFake(
            surface: surface(offer: offer),
            authorization: .fullAccess,
            defaultTarget: first)
        let model = ReminderDraftModel(client: client)
        await model.load(commitments: [offer.commitment])
        await model.open(offer.commitment.id)
        client.defaultTarget = renamed

        await model.refreshAccess()

        XCTAssertEqual(client.authorizationChecks, 2)
        XCTAssertEqual(client.permissionRequests, 0)
        XCTAssertEqual(client.defaultTargetRequests, 2)
        XCTAssertEqual(model.state.confirmation?.target, renamed)
    }

    func testConfirmationPublishesDurableReceiptAndRetiresOffer() async throws {
        let offer = try XCTUnwrap(ReminderDraftOffer(commitment: commitment()))
        let target = try XCTUnwrap(AppReminderDraftTarget(
            identifier: "opaque-list-42",
            title: "Work"))
        let receipt = ReminderDraftReceipt(
            commitmentID: offer.commitment.id,
            proposalID: UUID(),
            state: .succeeded,
            attempt: 1,
            updatedAt: now)
        let settled = ReminderDraftSurfaceItem(
            commitmentID: offer.commitment.id,
            offer: nil,
            receipt: receipt)
        let client = ReminderDraftModelClientFake(
            surface: surface(offer: offer),
            authorization: .fullAccess,
            defaultTarget: target,
            executionResults: [.succeeded(settled)])
        let model = ReminderDraftModel(client: client)
        await model.load(commitments: [offer.commitment])
        await model.open(offer.commitment.id)
        let proposalID = try XCTUnwrap(model.state.confirmation?.proposalID)

        await model.confirm()

        XCTAssertNil(model.state.confirmation)
        XCTAssertNil(model.state.items[offer.commitment.id]?.offer)
        XCTAssertEqual(
            model.state.items[offer.commitment.id]?.receipt,
            receipt)
        XCTAssertEqual(client.executions.map(\.proposalID), [proposalID])
        XCTAssertEqual(client.executions.map(\.target), [target])
    }

    func testFailedExecutionKeepsTheSameProposalAndExactPreviewForRetry() async throws {
        let offer = try XCTUnwrap(ReminderDraftOffer(commitment: commitment()))
        let target = try XCTUnwrap(AppReminderDraftTarget(
            identifier: "opaque-list-42",
            title: "Work"))
        let client = ReminderDraftModelClientFake(
            surface: surface(offer: offer),
            authorization: .fullAccess,
            defaultTarget: target,
            executionResults: [
                .failed("The reminder was not created."),
                .succeeded(ReminderDraftSurfaceItem(
                    commitmentID: offer.commitment.id,
                    offer: nil,
                    receipt: ReminderDraftReceipt(
                        commitmentID: offer.commitment.id,
                        proposalID: UUID(),
                        state: .succeeded,
                        attempt: 2,
                        updatedAt: now)))
            ])
        let model = ReminderDraftModel(client: client)
        await model.load(commitments: [offer.commitment])
        await model.open(offer.commitment.id)
        let proposalID = try XCTUnwrap(model.state.confirmation?.proposalID)
        let draft = model.state.confirmation?.offer.draft

        await model.confirm()
        XCTAssertEqual(model.state.confirmation?.proposalID, proposalID)
        XCTAssertEqual(model.state.confirmation?.offer.draft, draft)
        XCTAssertEqual(
            model.state.confirmation?.failure,
            "The reminder was not created.")

        await model.confirm()
        XCTAssertEqual(
            client.executions.map(\.proposalID),
            [proposalID, proposalID])
        XCTAssertNil(model.state.confirmation)
    }

    func testThrownExecutionReportsAnUnverifiedOutcomeAndKeepsThePreview() async throws {
        let offer = try XCTUnwrap(ReminderDraftOffer(commitment: commitment()))
        let target = try XCTUnwrap(AppReminderDraftTarget(
            identifier: "opaque-list-42",
            title: "Work"))
        let client = ReminderDraftModelClientFake(
            surface: surface(offer: offer),
            authorization: .fullAccess,
            defaultTarget: target,
            executionError: ReminderDraftClientFailure())
        let model = ReminderDraftModel(client: client)
        await model.load(commitments: [offer.commitment])
        await model.open(offer.commitment.id)
        let proposalID = try XCTUnwrap(model.state.confirmation?.proposalID)

        await model.confirm()

        XCTAssertEqual(model.state.confirmation?.proposalID, proposalID)
        XCTAssertEqual(model.state.confirmation?.phase, .ready)
        XCTAssertEqual(
            model.state.confirmation?.failure,
            "Portavoz could not verify whether the reminder was created. Check Reminders before retrying.")
        XCTAssertEqual(model.state.items[offer.commitment.id]?.offer, offer)
    }

    func testMalformedSuccessLeavesExactConfirmationOpenAndFailsClosed() async throws {
        let offer = try XCTUnwrap(ReminderDraftOffer(commitment: commitment()))
        let target = try XCTUnwrap(AppReminderDraftTarget(
            identifier: "opaque-list-42",
            title: "Work"))
        let malformed = ReminderDraftSurfaceItem(
            commitmentID: offer.commitment.id,
            offer: offer,
            receipt: nil)
        let client = ReminderDraftModelClientFake(
            surface: surface(offer: offer),
            authorization: .fullAccess,
            defaultTarget: target,
            executionResults: [.succeeded(malformed)])
        let model = ReminderDraftModel(client: client)
        await model.load(commitments: [offer.commitment])
        await model.open(offer.commitment.id)
        let proposalID = try XCTUnwrap(model.state.confirmation?.proposalID)

        await model.confirm()

        XCTAssertEqual(model.state.confirmation?.proposalID, proposalID)
        XCTAssertEqual(model.state.confirmation?.phase, .ready)
        XCTAssertNotNil(model.state.confirmation?.failure)
        XCTAssertEqual(model.state.items[offer.commitment.id]?.offer, offer)
    }

    func testDismissalRemovesOnlyTheSelectedOffer() async throws {
        let first = try XCTUnwrap(ReminderDraftOffer(commitment: commitment()))
        let second = try XCTUnwrap(ReminderDraftOffer(commitment: Commitment(
            title: "Another commitment",
            status: .confirmed,
            assignee: .me,
            createdAt: now)))
        let client = ReminderDraftModelClientFake(
            surface: ReminderDraftSurface(items: [
                item(offer: first),
                item(offer: second)
            ]),
            authorization: .notDetermined)
        let model = ReminderDraftModel(client: client)
        await model.load(commitments: [first.commitment, second.commitment])

        await model.dismiss(first.commitment.id)

        XCTAssertEqual(client.dismissed, [first])
        XCTAssertNil(model.state.items[first.commitment.id]?.offer)
        XCTAssertNotNil(model.state.items[second.commitment.id]?.offer)
    }

    func testDuplicateSurfaceItemsFailClosedWithVisibleRecovery() async throws {
        let offer = try XCTUnwrap(ReminderDraftOffer(commitment: commitment()))
        let duplicate = item(offer: offer)
        let client = ReminderDraftModelClientFake(
            surface: ReminderDraftSurface(items: [duplicate, duplicate]),
            authorization: .notDetermined)
        let model = ReminderDraftModel(client: client)

        await model.load(commitments: [offer.commitment])

        XCTAssertEqual(model.state.loadPhase, .failed)
        XCTAssertTrue(model.state.items.isEmpty)
        XCTAssertNotNil(model.state.surfaceFailure)
    }

    func testTargetBoundsOpaqueIdentityAndDisplayName() async {
        XCTAssertNotNil(AppReminderDraftTarget(
            identifier: String(
                repeating: "x",
                count: AppReminderDraftTarget.maximumIdentifierLength),
            title: String(
                repeating: "W",
                count: AppReminderDraftTarget.maximumTitleLength)))
        XCTAssertNil(AppReminderDraftTarget(identifier: " ", title: "Work"))
        XCTAssertNil(AppReminderDraftTarget(
            identifier: String(
                repeating: "x",
                count: AppReminderDraftTarget.maximumIdentifierLength + 1),
            title: "Work"))
        XCTAssertNil(AppReminderDraftTarget(
            identifier: "list",
            title: String(
                repeating: "W",
                count: AppReminderDraftTarget.maximumTitleLength + 1)))
    }

    private func commitment() -> Commitment {
        Commitment(
            title: "Send the signed package",
            status: .confirmed,
            assignee: .me,
            dueAt: now.addingTimeInterval(3_600),
            createdAt: now)
    }

    private func surface(offer: ReminderDraftOffer) -> ReminderDraftSurface {
        ReminderDraftSurface(items: [item(offer: offer)])
    }

    private func item(offer: ReminderDraftOffer) -> ReminderDraftSurfaceItem {
        ReminderDraftSurfaceItem(
            commitmentID: offer.commitment.id,
            offer: offer,
            receipt: nil)
    }
}

@MainActor
private final class ReminderDraftModelClientFake: ReminderDraftModelClient {
    var surface: ReminderDraftSurface
    var authorization: AppReminderDraftAuthorization
    let requestedAuthorization: AppReminderDraftAuthorization
    var defaultTarget: AppReminderDraftTarget?
    var executionResults: [ReminderDraftExecutionResult]
    let executionError: (any Error)?
    var authorizationChecks = 0
    var permissionRequests = 0
    var defaultTargetRequests = 0
    var executions: [ReminderDraftExecutionRequest] = []
    var dismissed: [ReminderDraftOffer] = []

    init(
        surface: ReminderDraftSurface,
        authorization: AppReminderDraftAuthorization,
        requestedAuthorization: AppReminderDraftAuthorization = .fullAccess,
        defaultTarget: AppReminderDraftTarget? = nil,
        executionResults: [ReminderDraftExecutionResult] = [],
        executionError: (any Error)? = nil
    ) {
        self.surface = surface
        self.authorization = authorization
        self.requestedAuthorization = requestedAuthorization
        self.defaultTarget = defaultTarget
        self.executionResults = executionResults
        self.executionError = executionError
    }

    func loadReminderDraftSurface(
        commitments _: [Commitment]
    ) -> ReminderDraftSurface {
        surface
    }

    func reminderDraftAuthorization() -> AppReminderDraftAuthorization {
        authorizationChecks += 1
        return authorization
    }

    func requestReminderDraftAccess() -> AppReminderDraftAuthorization {
        permissionRequests += 1
        authorization = requestedAuthorization
        return authorization
    }

    func defaultReminderDraftTarget() -> AppReminderDraftTarget? {
        defaultTargetRequests += 1
        return defaultTarget
    }

    func performReminderDraft(
        _ request: ReminderDraftExecutionRequest
    ) throws -> ReminderDraftExecutionResult {
        executions.append(request)
        if let executionError { throw executionError }
        return executionResults.removeFirst()
    }

    func dismissReminderDraftOffer(_ offer: ReminderDraftOffer) {
        dismissed.append(offer)
    }
}

private struct ReminderDraftClientFailure: Error {}
