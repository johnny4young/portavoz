import ApplicationKit
import Foundation
import PortavozCore
@testable import portavoz_app
import XCTest

@MainActor
final class CommitmentReminderModelTests: XCTestCase {
    func testLaunchChecksPermissionWithoutPromptingOrReconcilingWhenUndetermined() async {
        let client = RecordingReminderModelClient(permission: .notDetermined)
        let model = CommitmentReminderModel(client: client)

        await model.send(.start)

        XCTAssertEqual(model.state.permission, .notDetermined)
        XCTAssertEqual(model.state.phase, .idle)
        XCTAssertEqual(client.authorizationRequests, 0)
        XCTAssertEqual(client.reconciliationCount, 0)
    }

    func testExplicitEnableRequestsPermissionAndStartsReconciliation() async {
        let client = RecordingReminderModelClient(
            permission: .notDetermined,
            requestedPermission: .enabled)
        let model = CommitmentReminderModel(client: client)

        await model.send(.start)
        await model.send(.enable)
        await waitUntil { client.reconciliationCount == 1 }
        await waitUntil { model.state.phase == .idle }

        XCTAssertEqual(model.state.permission, .enabled)
        XCTAssertEqual(client.authorizationRequests, 1)
    }

    func testDeniedPermissionNeverStartsReconciliation() async {
        let client = RecordingReminderModelClient(
            permission: .notDetermined,
            requestedPermission: .denied)
        let model = CommitmentReminderModel(client: client)

        await model.send(.start)
        await model.send(.enable)

        XCTAssertEqual(model.state.permission, .denied)
        XCTAssertEqual(model.state.phase, .idle)
        XCTAssertEqual(client.authorizationRequests, 1)
        XCTAssertEqual(client.reconciliationCount, 0)
    }

    func testMutationBurstCoalescesToOneActivePassAndOneRerun() async {
        let client = RecordingReminderModelClient(
            permission: .enabled,
            suspendsFirstReconciliation: true)
        let model = CommitmentReminderModel(client: client)

        await model.send(.start)
        await waitUntil { client.reconciliationCount == 1 }
        model.kick()
        model.kick()
        model.kick()
        client.resumeFirstReconciliation()

        await waitUntil { client.reconciliationCount == 2 }
        await waitUntil { model.state.phase == .idle }
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(client.reconciliationCount, 2)
    }

    func testRetryRecoversFromAReconciliationFailure() async {
        let client = RecordingReminderModelClient(
            permission: .enabled,
            reconciliationFails: true)
        let model = CommitmentReminderModel(client: client)

        await model.send(.start)
        await waitUntil { model.state.phase == .failed }
        client.reconciliationFails = false
        await model.send(.retry)
        await waitUntil { client.reconciliationCount == 2 }
        await waitUntil { model.state.phase == .idle }

        XCTAssertEqual(model.state.permission, .enabled)
    }

    func testDeliveredNotificationRecordsPresentationWithoutPermissionChange() async {
        let client = RecordingReminderModelClient(permission: .enabled)
        let model = CommitmentReminderModel(client: client)
        let commitmentID = CommitmentID()
        let scheduledFor = Date(timeIntervalSinceReferenceDate: 1_000)

        await model.recordPresentation(AppReminderNotificationRecord(
            identifier: AppReminderNotificationScheduler.identifier(
                for: commitmentID),
            commitmentID: commitmentID,
            scheduledFor: scheduledFor,
            sourceDueAt: scheduledFor,
            deliveredAt: scheduledFor.addingTimeInterval(1)))

        XCTAssertEqual(client.presentationCount, 1)
        XCTAssertEqual(model.state.permission, .unknown)
        XCTAssertEqual(model.state.phase, .idle)
    }

    func testSnoozeRefreshesPermissionAndSignalsReconciliation() async {
        let client = RecordingReminderModelClient(permission: .enabled)
        let model = CommitmentReminderModel(client: client)
        let commitmentID = CommitmentID()
        let scheduledFor = Date(timeIntervalSinceReferenceDate: 1_000)
        let handledAt = scheduledFor.addingTimeInterval(2)

        await model.snooze(
            AppReminderNotificationRecord(
                identifier: AppReminderNotificationScheduler.identifier(
                    for: commitmentID),
                commitmentID: commitmentID,
                scheduledFor: scheduledFor,
                sourceDueAt: scheduledFor,
                deliveredAt: scheduledFor.addingTimeInterval(1)),
            handledAt: handledAt,
            until: handledAt.addingTimeInterval(900))
        await waitUntil { client.reconciliationCount == 1 }
        await waitUntil { model.state.phase == .idle }

        XCTAssertEqual(client.snoozeCount, 1)
        XCTAssertEqual(model.state.permission, .enabled)
        XCTAssertEqual(client.authorizationRequests, 0)
    }

    private func waitUntil(
        timeout: Duration = .seconds(1),
        condition: @escaping @MainActor () -> Bool
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition(), clock.now < deadline {
            await Task.yield()
        }
        XCTAssertTrue(condition(), "condition did not become true before timeout")
    }
}

@MainActor
private final class RecordingReminderModelClient: CommitmentReminderModelClient {
    var reconciliationFails: Bool
    private(set) var authorizationRequests = 0
    private(set) var reconciliationCount = 0
    private(set) var presentationCount = 0
    private(set) var snoozeCount = 0

    private var permission: CommitmentReminderPermission
    private let requestedPermission: CommitmentReminderPermission
    private let suspendsFirstReconciliation: Bool
    private var firstContinuation: CheckedContinuation<Void, Never>?

    init(
        permission: CommitmentReminderPermission,
        requestedPermission: CommitmentReminderPermission = .enabled,
        suspendsFirstReconciliation: Bool = false,
        reconciliationFails: Bool = false
    ) {
        self.permission = permission
        self.requestedPermission = requestedPermission
        self.suspendsFirstReconciliation = suspendsFirstReconciliation
        self.reconciliationFails = reconciliationFails
    }

    func commitmentReminderPermission() -> CommitmentReminderPermission {
        permission
    }

    func requestCommitmentReminderPermission() -> CommitmentReminderPermission {
        authorizationRequests += 1
        permission = requestedPermission
        return permission
    }

    func reconcileCommitmentReminders() async throws
        -> ReconcileCommitmentRemindersReport
    {
        reconciliationCount += 1
        if suspendsFirstReconciliation, reconciliationCount == 1 {
            await withCheckedContinuation { firstContinuation = $0 }
        }
        if reconciliationFails {
            throw ReminderModelTestError.reconciliationFailed
        }
        return ReconcileCommitmentRemindersReport(
            scheduledCount: 0,
            replacedCount: 0,
            reassertedCount: 0,
            presentedCount: 0,
            cancelledCount: 0,
            unchangedCount: 0)
    }

    func recordCommitmentReminderPresentation(
        _: ReminderPresentationRequest
    ) -> ReminderPresentationOutcome {
        presentationCount += 1
        return .recorded
    }

    func snoozeCommitmentReminder(
        _ request: ReminderSnoozeRequest
    ) -> ReminderSnoozeOutcome {
        snoozeCount += 1
        return .snoozed(until: request.snoozeUntil)
    }

    func resumeFirstReconciliation() {
        firstContinuation?.resume()
        firstContinuation = nil
    }
}

private enum ReminderModelTestError: Error {
    case reconciliationFailed
}
