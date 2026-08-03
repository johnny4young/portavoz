import ApplicationKit
import Foundation
import PortavozCore
import StorageKit
@testable import portavoz_app
import XCTest

final class CommitmentReminderNotificationSchedulerTests: XCTestCase {
    private let baseDate = Date(timeIntervalSinceReferenceDate: 2_000_000)

    func testReconciliationNeverRequestsAuthorizationAndFailsClosed() async {
        for (status, expectedError) in [
            (
                AppReminderAuthorization.notDetermined,
                AppReminderNotificationError.authorizationNotDetermined),
            (
                AppReminderAuthorization.denied,
                AppReminderNotificationError.authorizationDenied),
        ] {
            let center = RecordingCommitmentNotificationCenter(
                authorization: status)
            let scheduler = makeScheduler(center: center)

            do {
                _ = try await scheduler.upsertCommitmentReminder(schedule())
                XCTFail("reconciliation must not prompt or schedule without authorization")
            } catch {
                XCTAssertEqual(
                    error as? AppReminderNotificationError,
                    expectedError)
            }

            let authorizationRequests = await center.authorizationRequestCount()
            let requests = await center.addedRequests()
            XCTAssertEqual(authorizationRequests, 0)
            XCTAssertTrue(requests.isEmpty)
        }
    }

    func testExactPendingRequestIsIdempotent() async throws {
        let schedule = schedule()
        let identifier = AppReminderNotificationScheduler.identifier(
            for: schedule.commitmentID)
        let pending = record(
            schedule: schedule,
            identifier: identifier,
            deliveredAt: nil)
        let center = RecordingCommitmentNotificationCenter(
            authorization: .authorized,
            snapshot: AppReminderNotificationSnapshot(
                pending: pending,
                delivered: nil))
        let scheduler = makeScheduler(center: center)

        let outcome = try await scheduler.upsertCommitmentReminder(schedule)

        XCTAssertEqual(outcome, .scheduled)
        let requests = await center.addedRequests()
        let pendingRemovals = await center.removedPendingIdentifiers()
        let deliveredRemovals = await center.removedDeliveredIdentifiers()
        XCTAssertTrue(requests.isEmpty)
        XCTAssertTrue(pendingRemovals.isEmpty)
        XCTAssertTrue(deliveredRemovals.isEmpty)
    }

    func testExactDeliveredRequestBecomesPresentationWithoutRealert() async throws {
        let schedule = schedule()
        let identifier = AppReminderNotificationScheduler.identifier(
            for: schedule.commitmentID)
        let deliveredAt = baseDate.addingTimeInterval(130)
        let center = RecordingCommitmentNotificationCenter(
            authorization: .provisional,
            snapshot: AppReminderNotificationSnapshot(
                pending: record(
                    schedule: schedule,
                    identifier: identifier,
                    deliveredAt: nil),
                delivered: record(
                    schedule: schedule,
                    identifier: identifier,
                    deliveredAt: deliveredAt)))
        let scheduler = makeScheduler(center: center)

        let outcome = try await scheduler.upsertCommitmentReminder(schedule)

        XCTAssertEqual(
            outcome,
            .alreadyPresented(
                scheduledFor: schedule.scheduledFor,
                deliveredAt: deliveredAt))
        let requests = await center.addedRequests()
        let pendingRemovals = await center.removedPendingIdentifiers()
        let deliveredRemovals = await center.removedDeliveredIdentifiers()
        XCTAssertTrue(requests.isEmpty)
        XCTAssertEqual(pendingRemovals, [identifier])
        XCTAssertTrue(deliveredRemovals.isEmpty)
    }

    func testStaleDeliveredRequestIsRemovedBeforeGenericReplacement() async throws {
        let schedule = schedule()
        let identifier = AppReminderNotificationScheduler.identifier(
            for: schedule.commitmentID)
        let staleSchedule = CommitmentReminderDeliverySchedule(
            commitmentID: schedule.commitmentID,
            scheduledFor: schedule.scheduledFor.addingTimeInterval(-60),
            sourceDueAt: schedule.sourceDueAt)
        let center = RecordingCommitmentNotificationCenter(
            authorization: .ephemeral,
            snapshot: AppReminderNotificationSnapshot(
                pending: nil,
                delivered: record(
                    schedule: staleSchedule,
                    identifier: identifier,
                    deliveredAt: baseDate)))
        let scheduler = makeScheduler(center: center)

        let outcome = try await scheduler.upsertCommitmentReminder(schedule)

        XCTAssertEqual(outcome, .scheduled)
        let deliveredRemovals = await center.removedDeliveredIdentifiers()
        XCTAssertEqual(deliveredRemovals, [identifier])
        let added = await center.addedRequests()
        XCTAssertEqual(added.count, 1)
        XCTAssertEqual(added[0].record.commitmentID, schedule.commitmentID)
        XCTAssertEqual(added[0].record.sourceDueAt, schedule.sourceDueAt)
        XCTAssertEqual(added[0].title, "Private reminder")
        XCTAssertEqual(added[0].body, "Open Portavoz")
    }

    func testMetadataRoundTripRejectsACommitmentIdentifierMismatch() {
        let schedule = schedule()
        let expectedIdentifier = AppReminderNotificationScheduler.identifier(
            for: schedule.commitmentID)
        let expected = record(
            schedule: schedule,
            identifier: expectedIdentifier,
            deliveredAt: baseDate.addingTimeInterval(130))
        let userInfo = AppReminderNotificationMetadata.userInfo(for: expected)

        XCTAssertEqual(AppReminderNotificationMetadata.record(
            identifier: expectedIdentifier,
            userInfo: userInfo,
            deliveredAt: expected.deliveredAt), expected)
        XCTAssertNil(AppReminderNotificationMetadata.record(
            identifier: "portavoz.commitment-reminder.invalid",
            userInfo: userInfo,
            deliveredAt: expected.deliveredAt))
    }

    func testCancellationRemovesPendingAndDeliveredCopies() async {
        let center = RecordingCommitmentNotificationCenter(
            authorization: .authorized)
        let scheduler = makeScheduler(center: center)
        let commitmentID = CommitmentID()
        let identifier = AppReminderNotificationScheduler.identifier(
            for: commitmentID)

        await scheduler.cancelCommitmentReminder(for: commitmentID)

        let pendingRemovals = await center.removedPendingIdentifiers()
        let deliveredRemovals = await center.removedDeliveredIdentifiers()
        XCTAssertEqual(pendingRemovals, [identifier])
        XCTAssertEqual(deliveredRemovals, [identifier])
    }

    func testAuthorizationRequestExistsOnlyAsExplicitCapability() async throws {
        let center = RecordingCommitmentNotificationCenter(
            authorization: .notDetermined,
            authorizationResult: true)
        let scheduler = makeScheduler(center: center)

        let granted = try await scheduler.requestAuthorization()
        let authorizationRequests = await center.authorizationRequestCount()
        XCTAssertTrue(granted)
        XCTAssertEqual(authorizationRequests, 1)
    }

    func testAuthorizedSchedulerReconcilesSeededConfirmedDueWork() async throws {
        let store = try MeetingStore.inMemory()
        let now = Date()
        let future = try await store.confirmCommitment(
            CommitmentConfirmation(
                title: "Future work",
                assignee: .me,
                dueAt: now.addingTimeInterval(2 * 86_400),
                origin: .manual(meetingID: nil)),
            at: now.addingTimeInterval(-3_600))
        let overdue = try await store.confirmCommitment(
            CommitmentConfirmation(
                title: "Overdue work",
                assignee: .me,
                dueAt: now.addingTimeInterval(-86_400),
                origin: .manual(meetingID: nil)),
            at: now.addingTimeInterval(-10 * 86_400))
        let center = RecordingCommitmentNotificationCenter(
            authorization: .authorized)

        let report = try await ReconcileCommitmentReminders(
            reader: store,
            writer: store,
            scheduler: makeScheduler(center: center),
            now: { now }
        ).execute(ReconcileCommitmentRemindersRequest())

        XCTAssertEqual(report.scheduledCount, 2)
        let addedRequests = await center.addedRequests()
        XCTAssertEqual(addedRequests.count, 2)
        for commitmentID in [future.commitment.id, overdue.commitment.id] {
            let reminder = try await store.commitmentReminderState(
                for: commitmentID)
            XCTAssertEqual(reminder?.status, .scheduled)
        }
    }

    private func schedule() -> CommitmentReminderDeliverySchedule {
        CommitmentReminderDeliverySchedule(
            commitmentID: CommitmentID(
                rawValue: UUID(uuid: (
                    0x11, 0x11, 0x11, 0x11,
                    0x22, 0x22,
                    0x33, 0x33,
                    0x44, 0x44,
                    0x55, 0x55, 0x55, 0x55, 0x55, 0x55))),
            scheduledFor: baseDate.addingTimeInterval(120),
            sourceDueAt: baseDate.addingTimeInterval(120))
    }

    private func record(
        schedule: CommitmentReminderDeliverySchedule,
        identifier: String,
        deliveredAt: Date?
    ) -> AppReminderNotificationRecord {
        AppReminderNotificationRecord(
            identifier: identifier,
            commitmentID: schedule.commitmentID,
            scheduledFor: schedule.scheduledFor,
            sourceDueAt: schedule.sourceDueAt,
            deliveredAt: deliveredAt)
    }

    private func makeScheduler(
        center: RecordingCommitmentNotificationCenter
    ) -> AppReminderNotificationScheduler {
        AppReminderNotificationScheduler(
            center: center,
            notificationContent: {
                ("Private reminder", "Open Portavoz")
            })
    }
}

private actor RecordingCommitmentNotificationCenter: AppReminderNotificationCenter {
    private let authorization: AppReminderAuthorization
    private let authorizationResult: Bool
    private let storedSnapshot: AppReminderNotificationSnapshot
    private var authorizationRequests = 0
    private var requests: [AppReminderNotificationRequest] = []
    private var pendingRemovals: [String] = []
    private var deliveredRemovals: [String] = []

    init(
        authorization: AppReminderAuthorization,
        authorizationResult: Bool = false,
        snapshot: AppReminderNotificationSnapshot =
            AppReminderNotificationSnapshot(
                pending: nil,
                delivered: nil)
    ) {
        self.authorization = authorization
        self.authorizationResult = authorizationResult
        storedSnapshot = snapshot
    }

    func authorizationStatus() -> AppReminderAuthorization {
        authorization
    }

    func requestAuthorization() -> Bool {
        authorizationRequests += 1
        return authorizationResult
    }

    func snapshot(
        identifier _: String
    ) -> AppReminderNotificationSnapshot {
        storedSnapshot
    }

    func add(_ request: AppReminderNotificationRequest) {
        requests.append(request)
    }

    func removePending(identifier: String) {
        pendingRemovals.append(identifier)
    }

    func removeDelivered(identifier: String) {
        deliveredRemovals.append(identifier)
    }

    func authorizationRequestCount() -> Int { authorizationRequests }
    func addedRequests() -> [AppReminderNotificationRequest] { requests }
    func removedPendingIdentifiers() -> [String] { pendingRemovals }
    func removedDeliveredIdentifiers() -> [String] { deliveredRemovals }
}
