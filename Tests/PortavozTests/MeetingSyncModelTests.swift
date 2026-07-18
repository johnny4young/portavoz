import Foundation
import IntegrationsKit
import StorageKit
@testable import portavoz_app
import XCTest

@MainActor
final class MeetingSyncModelTests: XCTestCase {
    func testLocalOnlyStartDoesNotArmObserversOrPush() async {
        let client = TestMeetingSyncModelClient()
        let model = MeetingSyncModel(client: client)

        await model.start()

        XCTAssertEqual(model.status.phase, .localOnly)
        XCTAssertEqual(client.resumeCount, 1)
        XCTAssertEqual(client.journalObservationCount, 0)
        XCTAssertEqual(client.accountObservationCount, 0)
        XCTAssertTrue(client.remoteNotificationValues.isEmpty)
    }

    func testEnableArmsContentFreeWakeupsAfterConsent() async throws {
        let client = TestMeetingSyncModelClient()
        let model = MeetingSyncModel(client: client)
        await model.start()

        await model.send(.enable)
        try await waitUntil { client.journalObservationCount == 1 }

        XCTAssertEqual(model.status.phase, .synchronized)
        XCTAssertEqual(client.enableCount, 1)
        XCTAssertEqual(client.accountObservationCount, 1)
        XCTAssertEqual(client.remoteNotificationValues, [true])
    }

    func testJournalBurstDebouncesToOneManualCycle() async throws {
        let client = TestMeetingSyncModelClient()
        let model = MeetingSyncModel(
            client: client,
            journalDebounce: .milliseconds(20))
        await model.start()
        await model.send(.enable)
        try await waitUntil { client.journalContinuation != nil }

        client.yieldJournal() // Initial observation is deliberately ignored.
        client.yieldJournal()
        client.yieldJournal()
        try await waitUntil { client.synchronizeCount == 1 }

        XCTAssertEqual(client.synchronizeCount, 1)
    }

    func testAccountChangeUsesLifecycleAndDisarmsAfterConsentIsCleared() async throws {
        let client = TestMeetingSyncModelClient()
        let model = MeetingSyncModel(client: client)
        await model.start()
        await model.send(.enable)
        try await waitUntil { client.accountContinuation != nil }
        client.accountChangeResult = .localOnly

        client.yieldAccountChange()
        try await waitUntil { client.accountChangeCount == 1 }

        XCTAssertEqual(model.status.phase, .localOnly)
        XCTAssertEqual(client.remoteNotificationValues, [true, false])
    }

    func testPauseDisarmsObserversWithoutDeletingLocalPolicyState() async {
        let client = TestMeetingSyncModelClient()
        let model = MeetingSyncModel(client: client)
        await model.start()
        await model.send(.enable)

        await model.send(.pause)

        XCTAssertEqual(client.pauseCount, 1)
        XCTAssertEqual(model.status.phase, .localOnly)
        XCTAssertEqual(client.remoteNotificationValues, [true, false])
    }

    func testRemoteWakeRequestsTheSameManualCycle() async throws {
        let client = TestMeetingSyncModelClient()
        let model = MeetingSyncModel(client: client)
        await model.start()
        await model.send(.enable)

        model.remoteChangeReceived()
        try await waitUntil { client.synchronizeCount == 1 }

        XCTAssertEqual(client.synchronizeCount, 1)
    }

    func testUserActionQueuedWhileBusyIsNotReplacedBySynchronization() async throws {
        let client = TestMeetingSyncModelClient()
        client.suspendEnable = true
        let model = MeetingSyncModel(client: client)
        await model.start()

        let enable = Task { await model.send(.enable) }
        try await waitUntil { client.enableContinuation != nil }
        let pause = Task { await model.send(.pause) }
        await pause.value

        client.resumeEnable()
        await enable.value
        try await waitUntil { client.pauseCount == 1 }

        XCTAssertEqual(client.pauseCount, 1)
        XCTAssertEqual(client.synchronizeCount, 0)
        XCTAssertEqual(model.status.phase, .localOnly)
    }

    func testQueuedPauseDropsAnOlderAccountWake() async throws {
        let client = TestMeetingSyncModelClient()
        client.suspendSynchronization = true
        let model = MeetingSyncModel(client: client)
        await model.start()
        await model.send(.enable)
        try await waitUntil { client.accountContinuation != nil }

        let synchronization = Task { await model.send(.synchronize) }
        try await waitUntil { client.synchronizationContinuation != nil }
        client.yieldAccountChange()
        await Task.yield()
        let pause = Task { await model.send(.pause) }
        await pause.value

        client.resumeSynchronization()
        await synchronization.value
        try await waitUntil { client.pauseCount == 1 }
        try await Task.sleep(for: .milliseconds(20))

        XCTAssertEqual(client.accountChangeCount, 0)
        XCTAssertEqual(model.status.phase, .localOnly)
    }

    private func waitUntil(
        timeout: Duration = .seconds(1),
        _ predicate: @escaping @MainActor () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !predicate() {
            if clock.now >= deadline {
                XCTFail("condition did not become true before timeout")
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

@MainActor
private final class TestMeetingSyncModelClient: MeetingSyncModelClient {
    var resumeCount = 0
    var enableCount = 0
    var synchronizeCount = 0
    var accountChangeCount = 0
    var pauseCount = 0
    var journalObservationCount = 0
    var accountObservationCount = 0
    var remoteNotificationValues: [Bool] = []
    var suspendEnable = false
    var suspendSynchronization = false
    var enableContinuation: CheckedContinuation<Void, Never>?
    var synchronizationContinuation: CheckedContinuation<Void, Never>?
    var accountChangeResult = CloudMeetingSyncStatus.readyForTests
    var journalContinuation: AsyncThrowingStream<MeetingSyncJournalStatus, Error>.Continuation?
    var accountContinuation: AsyncStream<Void>.Continuation?
    private var status = CloudMeetingSyncStatus.localOnly

    func resumeIfConsented() async -> CloudMeetingSyncStatus {
        resumeCount += 1
        return status
    }

    func enable() async -> CloudMeetingSyncStatus {
        enableCount += 1
        if suspendEnable {
            await withCheckedContinuation { continuation in
                enableContinuation = continuation
            }
        }
        status = .readyForTests
        return status
    }

    func accountDidChange() async -> CloudMeetingSyncStatus {
        accountChangeCount += 1
        status = accountChangeResult
        return status
    }

    func synchronizeNow() async -> CloudMeetingSyncStatus {
        synchronizeCount += 1
        if suspendSynchronization {
            await withCheckedContinuation { continuation in
                synchronizationContinuation = continuation
            }
        }
        return status
    }

    func retryNow() async -> CloudMeetingSyncStatus { status }
    func includeExistingLibrary() async -> CloudMeetingSyncStatus { status }

    func pause() async -> CloudMeetingSyncStatus {
        pauseCount += 1
        status = .localOnly
        return status
    }

    func removeThisDevice() async -> CloudMeetingSyncStatus {
        status = .localOnly
        return status
    }

    func currentStatus() async -> CloudMeetingSyncStatus { status }

    func observeJournal() async -> AsyncThrowingStream<MeetingSyncJournalStatus, Error> {
        journalObservationCount += 1
        return AsyncThrowingStream { journalContinuation = $0 }
    }

    func observeAccountChanges() -> AsyncStream<Void> {
        accountObservationCount += 1
        return AsyncStream { accountContinuation = $0 }
    }

    func setRemoteNotificationsEnabled(_ enabled: Bool) {
        remoteNotificationValues.append(enabled)
    }

    func yieldJournal() {
        journalContinuation?.yield(
            MeetingSyncJournalStatus(pendingCount: 1, newestChangeAt: Date()))
    }

    func yieldAccountChange() {
        accountContinuation?.yield()
    }

    func resumeEnable() {
        suspendEnable = false
        let continuation = enableContinuation
        enableContinuation = nil
        continuation?.resume()
    }

    func resumeSynchronization() {
        suspendSynchronization = false
        let continuation = synchronizationContinuation
        synchronizationContinuation = nil
        continuation?.resume()
    }
}

private extension CloudMeetingSyncStatus {
    static var readyForTests: CloudMeetingSyncStatus {
        CloudMeetingSyncStatus(
            phase: .synchronized,
            accountStatus: .available,
            isEnabled: true,
            initialSeedState: .notRequested,
            progress: CloudMeetingSyncProgress(
                pendingLocalChanges: 0,
                queuedTransfers: 0,
                retryingTransfers: 0,
                failedTransfers: 0),
            nextRetryAt: nil,
            failure: nil)
    }
}
