import Foundation
import IntegrationsKit
import PortavozCore
import StorageKit
import XCTest

final class CloudMeetingSyncLifecycleTests: XCTestCase {
    func testLocalOnlyLaunchNeverTouchesPlatform() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }

        let status = await fixture.lifecycle.resumeIfConsented()
        let accountRequests = await fixture.platform.accountRequestCount()
        let driverRequests = await fixture.platform.driverRequestCount()

        XCTAssertEqual(status.phase, .localOnly)
        XCTAssertFalse(status.isEnabled)
        XCTAssertEqual(accountRequests, 0)
        XCTAssertEqual(driverRequests, 0)
    }

    func testExplicitEnableBindsConsentAndSynchronizesWithoutSeeding() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }

        let status = await fixture.lifecycle.enable()
        let snapshot = await fixture.transportStore.currentSnapshot()
        let accountRequests = await fixture.platform.accountRequestCount()
        let driverRequests = await fixture.platform.driverRequestCount()
        let synchronizations = await fixture.driver.synchronizeCount()

        XCTAssertEqual(status.phase, .synchronized)
        XCTAssertTrue(status.isEnabled)
        XCTAssertEqual(status.initialSeedState, .notRequested)
        XCTAssertEqual(snapshot.consentedAccountFingerprint, accountA)
        XCTAssertEqual(accountRequests, 1)
        XCTAssertEqual(driverRequests, 1)
        XCTAssertEqual(synchronizations, 1)
    }

    func testExistingLibrarySeedRemainsASeparateExplicitAction() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let meeting = Meeting(
            title: "Existing local meeting",
            startedAt: Date(timeIntervalSince1970: 1_784_340_000))
        try await fixture.meetingStore.save(meeting)
        for change in try await fixture.meetingStore.pendingMeetingSyncChanges() {
            try await fixture.meetingStore.acknowledgeMeetingSync(change)
        }

        let enabled = await fixture.lifecycle.enable()
        XCTAssertEqual(enabled.phase, .synchronized)
        XCTAssertEqual(enabled.initialSeedState, .notRequested)
        XCTAssertEqual(enabled.progress.pendingLocalChanges, 0)

        let seeded = await fixture.lifecycle.includeExistingLibrary(
            at: Date(timeIntervalSince1970: 1_784_340_100))
        XCTAssertEqual(seeded.phase, .pending)
        XCTAssertEqual(seeded.initialSeedState, .requested)
        XCTAssertEqual(seeded.progress.pendingLocalChanges, 1)
    }

    func testSignedOutAccountPausesAndPreservesConsentForResume() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        _ = await fixture.lifecycle.enable()
        await fixture.platform.setIdentity(
            CloudMeetingSyncAccountIdentity(status: .signedOut, fingerprint: nil))

        let status = await fixture.lifecycle.accountDidChange()
        let snapshot = await fixture.transportStore.currentSnapshot()
        let cancellations = await fixture.driver.cancelCount()

        XCTAssertEqual(status.phase, .paused)
        XCTAssertTrue(status.isEnabled)
        XCTAssertEqual(snapshot.consentedAccountFingerprint, accountA)
        XCTAssertEqual(cancellations, 1)
    }

    func testAccountSwitchClearsConsentAndRequiresAnotherExplicitEnable() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        _ = await fixture.lifecycle.enable()
        await fixture.platform.setIdentity(
            CloudMeetingSyncAccountIdentity(status: .available, fingerprint: accountB))

        let status = await fixture.lifecycle.accountDidChange()
        let snapshot = await fixture.transportStore.currentSnapshot()
        let cancellations = await fixture.driver.cancelCount()

        XCTAssertEqual(status.phase, .localOnly)
        XCTAssertFalse(status.isEnabled)
        XCTAssertEqual(snapshot.accountScopeFingerprint, accountB)
        XCTAssertNil(snapshot.consentedAccountFingerprint)
        XCTAssertEqual(cancellations, 1)
    }

    func testPausePreservesQueueWhileRemoveThisDeviceClearsOnlyTransport() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let localMeeting = Meeting(
            title: "Must remain on this Mac",
            startedAt: Date(timeIntervalSince1970: 1_784_339_900))
        try await fixture.meetingStore.save(localMeeting)
        _ = await fixture.lifecycle.enable()
        let envelope = deletionEnvelope()
        _ = try await fixture.transportStore.stage(
            envelope,
            at: Date(timeIntervalSince1970: 1_784_340_000))

        let paused = await fixture.lifecycle.pause()
        let pausedSnapshot = await fixture.transportStore.currentSnapshot()
        XCTAssertEqual(paused.phase, .localOnly)
        XCTAssertEqual(pausedSnapshot.attempts.map(\.meetingID), [envelope.meetingID])

        _ = await fixture.lifecycle.enable()
        let removed = await fixture.lifecycle.removeThisDevice()
        let removedSnapshot = await fixture.transportStore.currentSnapshot()
        let meetings = try await fixture.meetingStore.meetings()
        XCTAssertEqual(removed.phase, .localOnly)
        XCTAssertTrue(removedSnapshot.attempts.isEmpty)
        XCTAssertTrue(removedSnapshot.deferredReplays.isEmpty)
        XCTAssertNil(removedSnapshot.accountScopeFingerprint)
        XCTAssertEqual(meetings.map(\.id), [localMeeting.id])
    }

    func testExplicitRetryReadmitsBlockedExactAttempt() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        _ = await fixture.lifecycle.enable()
        let envelope = deletionEnvelope()
        let now = Date(timeIntervalSince1970: 1_784_340_000)
        _ = try await fixture.transportStore.stage(envelope, at: now)
        try await fixture.transportStore.markFailure(
            for: envelope,
            category: .terminal,
            serverRetryAfter: nil,
            at: now)

        let failed = await fixture.lifecycle.currentStatus()
        XCTAssertEqual(failed.phase, .failed)
        XCTAssertEqual(failed.progress.failedTransfers, 1)

        let retried = await fixture.lifecycle.retryNow(at: now.addingTimeInterval(1))
        let snapshot = await fixture.transportStore.currentSnapshot()
        XCTAssertEqual(retried.phase, .pending)
        XCTAssertEqual(snapshot.attempts.first?.phase, .ready)
        XCTAssertEqual(snapshot.attempts.first?.generation, envelope.generation)
    }

    func testCapabilityFailureIsTypedAndNeverConstructsTransport() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        await fixture.platform.setAccountError(.capabilityUnavailable)

        let status = await fixture.lifecycle.enable()
        let driverRequests = await fixture.platform.driverRequestCount()

        XCTAssertEqual(status.phase, .failed)
        XCTAssertEqual(status.failure, .capabilityUnavailable)
        XCTAssertEqual(driverRequests, 0)
    }

    func testAvailableAccountWithoutIdentityFailsClosed() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        await fixture.platform.setIdentity(
            CloudMeetingSyncAccountIdentity(status: .available, fingerprint: nil))

        let status = await fixture.lifecycle.enable()
        let driverRequests = await fixture.platform.driverRequestCount()

        XCTAssertEqual(status.phase, .failed)
        XCTAssertEqual(status.failure, .accountIdentityUnavailable)
        XCTAssertEqual(driverRequests, 0)
    }

    func testSyncJournalObservationTracksPendingAndAcknowledgedGenerations() async throws {
        let store = try MeetingStore.inMemory()
        var iterator = store.observeMeetingSyncJournalStatus().makeAsyncIterator()
        let initial = try await iterator.next()
        XCTAssertEqual(initial?.pendingCount, 0)

        let meeting = Meeting(
            title: "Observed journal",
            startedAt: Date(timeIntervalSince1970: 1_784_340_000))
        try await store.save(meeting)
        let pending = try await iterator.next()
        XCTAssertEqual(pending?.pendingCount, 1)

        let changes = try await store.pendingMeetingSyncChanges()
        let change = try XCTUnwrap(changes.first)
        try await store.acknowledgeMeetingSync(change)
        let acknowledged = try await iterator.next()
        XCTAssertEqual(acknowledged?.pendingCount, 0)
    }

    private var accountA: String {
        CloudMeetingSyncStateStore.accountFingerprint(forCloudRecordName: "icloud-user-a")
    }

    private var accountB: String {
        CloudMeetingSyncStateStore.accountFingerprint(forCloudRecordName: "icloud-user-b")
    }

    private func makeFixture() throws -> LifecycleFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("portavoz-cloud-lifecycle-tests")
            .appendingPathComponent(UUID().uuidString)
        let meetingStore = try MeetingStore.inMemory()
        let transportStore = try CloudMeetingSyncStateStore(rootDirectory: root)
        let driver = TestCloudMeetingSyncDriver()
        let platform = TestCloudMeetingSyncPlatform(
            identity: CloudMeetingSyncAccountIdentity(
                status: .available,
                fingerprint: accountA),
            driver: driver)
        let lifecycle = CloudMeetingSyncLifecycle(
            meetingStore: meetingStore,
            transportStore: transportStore,
            localDeviceID: UUID(
                uuidString: "50000000-0000-0000-0000-000000000001")!,
            platform: platform)
        return LifecycleFixture(
            root: root,
            meetingStore: meetingStore,
            transportStore: transportStore,
            driver: driver,
            platform: platform,
            lifecycle: lifecycle)
    }

    private func deletionEnvelope() -> MeetingSyncEnvelope {
        MeetingSyncEnvelope(
            meetingID: MeetingID(rawValue: UUID(
                uuidString: "50000000-0000-0000-0000-000000000099")!),
            sourceDeviceID: UUID(
                uuidString: "50000000-0000-0000-0000-000000000001")!,
            generation: 3,
            changedAt: Date(timeIntervalSince1970: 1_784_340_000),
            mutation: .delete)
    }
}

private struct LifecycleFixture {
    let root: URL
    let meetingStore: MeetingStore
    let transportStore: CloudMeetingSyncStateStore
    let driver: TestCloudMeetingSyncDriver
    let platform: TestCloudMeetingSyncPlatform
    let lifecycle: CloudMeetingSyncLifecycle

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}

private actor TestCloudMeetingSyncDriver: CloudMeetingSyncEngineDriving {
    private var synchronizations = 0
    private var cancellations = 0

    func synchronize() async throws {
        synchronizations += 1
    }

    func cancel() async {
        cancellations += 1
    }

    func synchronizeCount() -> Int { synchronizations }
    func cancelCount() -> Int { cancellations }
}

private actor TestCloudMeetingSyncPlatform: CloudMeetingSyncPlatform {
    private var identity: CloudMeetingSyncAccountIdentity
    private let driver: TestCloudMeetingSyncDriver
    private var accountError: CloudMeetingSyncPlatformError?
    private var accountRequests = 0
    private var driverRequests = 0

    init(
        identity: CloudMeetingSyncAccountIdentity,
        driver: TestCloudMeetingSyncDriver
    ) {
        self.identity = identity
        self.driver = driver
    }

    func accountIdentity() async throws -> CloudMeetingSyncAccountIdentity {
        accountRequests += 1
        if let accountError { throw accountError }
        return identity
    }

    func makeDriver(
        delegate: CloudMeetingSyncEngineDelegate
    ) async throws -> any CloudMeetingSyncEngineDriving {
        _ = delegate
        driverRequests += 1
        return driver
    }

    func setIdentity(_ identity: CloudMeetingSyncAccountIdentity) {
        self.identity = identity
    }

    func setAccountError(_ error: CloudMeetingSyncPlatformError?) {
        accountError = error
    }

    func accountRequestCount() -> Int { accountRequests }
    func driverRequestCount() -> Int { driverRequests }
}
