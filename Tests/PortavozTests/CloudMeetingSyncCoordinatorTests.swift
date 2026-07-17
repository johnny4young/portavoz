import CloudKit
import Foundation
import IntegrationsKit
import PortavozCore
import StorageKit
import XCTest

final class CloudMeetingSyncCoordinatorTests: XCTestCase {
    func testOutgoingGenerationStagesSendsAcknowledgesAndRestartsCleanly() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let meetingStore = try MeetingStore.inMemory()
        let meeting = Meeting(
            title: "Portable send",
            startedAt: Date(timeIntervalSince1970: 1_784_330_000))
        try await meetingStore.save(meeting)
        let transportStore = try await readyTransportStore(at: root)
        let coordinator = CloudMeetingSyncCoordinator(
            meetingStore: meetingStore,
            transportStore: transportStore,
            localDeviceID: localDeviceID)

        let recordIDs = try await coordinator.stagePendingChanges(
            at: meeting.startedAt)
        let recordID = try XCTUnwrap(recordIDs.first)
        let encodedCandidate = try await coordinator.encodedRecord(
            for: recordID,
            at: meeting.startedAt)
        let encoded = try XCTUnwrap(encodedCandidate)
        let outgoingEnvelope = try await transportStore.envelope(from: encoded.record)
        XCTAssertEqual(outgoingEnvelope.meetingID, meeting.id)

        let pendingBeforeCallback = try await meetingStore.pendingMeetingSyncChanges()
        let exactChange = try XCTUnwrap(pendingBeforeCallback.first)
        try await meetingStore.acknowledgeMeetingSync(exactChange)
        let recoveredRecordIDs = try await coordinator.stagePendingChanges(
            at: meeting.startedAt)
        XCTAssertEqual(
            recoveredRecordIDs,
            [recordID],
            "protected attempts must rebuild engine state after split persistence")

        try await coordinator.handleSavedRecord(encoded.record)

        let pending = try await meetingStore.pendingMeetingSyncChanges()
        let sentSnapshot = await transportStore.currentSnapshot()
        XCTAssertTrue(pending.isEmpty)
        XCTAssertTrue(sentSnapshot.attempts.isEmpty)
        let restarted = try CloudMeetingSyncStateStore(rootDirectory: root)
        let snapshot = await restarted.currentSnapshot()
        XCTAssertTrue(snapshot.attempts.isEmpty)
        XCTAssertEqual(snapshot.recordMetadata.map(\.meetingID), [meeting.id])
    }

    func testLateSaveRequiresNewerGenerationReadmission() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let meetingStore = try MeetingStore.inMemory()
        var meeting = Meeting(
            title: "Generation one",
            startedAt: Date(timeIntervalSince1970: 1_784_330_000))
        try await meetingStore.save(meeting)
        let transportStore = try await readyTransportStore(at: root)
        let coordinator = CloudMeetingSyncCoordinator(
            meetingStore: meetingStore,
            transportStore: transportStore,
            localDeviceID: localDeviceID)

        let firstIDs = try await coordinator.stagePendingChanges(at: meeting.startedAt)
        let recordID = try XCTUnwrap(firstIDs.first)
        let firstEncoded = try await coordinator.encodedRecord(
            for: recordID,
            at: meeting.startedAt)
        let firstRecord = try XCTUnwrap(firstEncoded).record

        meeting.title = "Generation two"
        try await meetingStore.save(meeting)
        _ = try await coordinator.stagePendingChanges(
            at: meeting.startedAt.addingTimeInterval(1))

        let shouldReadmit = try await coordinator.handleSavedRecord(firstRecord)
        XCTAssertTrue(
            shouldReadmit,
            "CKSyncEngine must re-admit the record ID when N+1 survives N's callback")
        let latestEncoded = try await coordinator.encodedRecord(
            for: recordID,
            at: meeting.startedAt.addingTimeInterval(1))
        let latestRecord = try XCTUnwrap(latestEncoded).record
        let latestEnvelope = try await transportStore.envelope(from: latestRecord)
        XCTAssertGreaterThan(latestEnvelope.generation, 1)

        let remainsAfterLatest = try await coordinator.handleSavedRecord(latestRecord)
        XCTAssertFalse(remainsAfterLatest)
    }

    func testRemoteReplayDefersLiveConflictThenAcceptsPrivacyTombstone() async throws {
        let root = temporaryDirectory()
        let assetRoot = temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: assetRoot)
        }
        let source = try MeetingStore.inMemory()
        var meeting = Meeting(
            title: "Remote version one",
            startedAt: Date(timeIntervalSince1970: 1_784_330_000))
        try await source.save(meeting)
        let firstEnvelope = try await newestEnvelope(
            in: source,
            sourceDeviceID: remoteDeviceID)
        let codec = CloudMeetingRecordCodec()
        let firstRecord = try codec.encode(
            firstEnvelope,
            assetDirectory: assetRoot).record

        let destination = try MeetingStore.inMemory()
        let transportStore = try await readyTransportStore(at: root)
        let coordinator = CloudMeetingSyncCoordinator(
            meetingStore: destination,
            transportStore: transportStore,
            localDeviceID: localDeviceID)

        let firstResult = try await coordinator.handleFetchedRecord(firstRecord)
        let duplicateResult = try await coordinator.handleFetchedRecord(firstRecord)
        XCTAssertEqual(firstResult, .applied(.applied))
        XCTAssertEqual(duplicateResult, .ignoredDuplicate)

        let localDetail = try await destination.detail(meeting.id)
        var local = try XCTUnwrap(localDetail?.meeting)
        local.title = "Unsent local edit"
        try await destination.save(local)
        meeting.title = "Remote version two"
        try await source.save(meeting)
        let secondEnvelope = try await newestEnvelope(
            in: source,
            sourceDeviceID: remoteDeviceID)
        let secondRecord = try codec.encode(
            secondEnvelope,
            existingRecord: firstRecord,
            assetDirectory: assetRoot).record

        guard case .deferred(let localGeneration) = try await coordinator
            .handleFetchedRecord(secondRecord) else {
            return XCTFail("live remote work must defer behind an unsent local edit")
        }
        XCTAssertGreaterThan(localGeneration, 0)
        let deferredDetail = try await destination.detail(meeting.id)
        XCTAssertEqual(deferredDetail?.meeting.title, "Unsent local edit")
        let deferredSnapshot = await transportStore.currentSnapshot()
        XCTAssertEqual(
            deferredSnapshot.replayCursors.first?.generation,
            firstEnvelope.generation,
            "deferred work must not advance its replay cursor")
        XCTAssertEqual(deferredSnapshot.deferredReplays.map(\.generation), [
            secondEnvelope.generation,
        ])
        let restartedTransport = try CloudMeetingSyncStateStore(rootDirectory: root)
        let restoredDeferred = try await restartedTransport.deferredEnvelope(
            for: meeting.id)
        XCTAssertEqual(restoredDeferred?.generation, secondEnvelope.generation)
        try await coordinator.handleFetchedRecordDeletion(secondRecord.recordID)
        let afterPhysicalDeletion = await transportStore.currentSnapshot()
        XCTAssertTrue(afterPhysicalDeletion.recordMetadata.isEmpty)
        XCTAssertEqual(
            afterPhysicalDeletion.deferredReplays.map(\.generation),
            [secondEnvelope.generation],
            "an unauthenticated physical deletion must not erase fetched content")

        let tombstone = MeetingSyncEnvelope(
            meetingID: meeting.id,
            sourceDeviceID: remoteDeviceID,
            generation: secondEnvelope.generation + 1,
            changedAt: secondEnvelope.changedAt.addingTimeInterval(1),
            mutation: .delete)
        let tombstoneRecord = try codec.encode(
            tombstone,
            existingRecord: secondRecord,
            assetDirectory: assetRoot).record

        let tombstoneResult = try await coordinator.handleFetchedRecord(tombstoneRecord)
        XCTAssertEqual(
            tombstoneResult,
            .applied(.deletionWon(discardedLocalGeneration: localGeneration)))
        let deletedDetail = try await destination.detail(meeting.id)
        let remaining = try await destination.pendingMeetingSyncChanges()
        let tombstoneSnapshot = await transportStore.currentSnapshot()
        XCTAssertNil(deletedDetail)
        XCTAssertTrue(remaining.isEmpty)
        XCTAssertEqual(
            tombstoneSnapshot.replayCursors.first?.generation,
            tombstone.generation)
        XCTAssertTrue(tombstoneSnapshot.deferredReplays.isEmpty)
    }

    func testFailureClassifierSeparatesRetryConflictAndTerminalPaths() {
        let transient = NSError(
            domain: CKError.errorDomain,
            code: CKError.Code.networkFailure.rawValue,
            userInfo: [CKErrorRetryAfterKey: 17.0])
        let conflict = NSError(
            domain: CKError.errorDomain,
            code: CKError.Code.serverRecordChanged.rawValue)
        let terminal = NSError(
            domain: CKError.errorDomain,
            code: CKError.Code.permissionFailure.rawValue)

        XCTAssertEqual(
            CloudSyncFailureClassifier.classify(transient),
            CloudSyncClassifiedFailure(category: .transient, retryAfter: 17))
        XCTAssertEqual(
            CloudSyncFailureClassifier.classify(conflict).category,
            .serverConflict)
        XCTAssertEqual(
            CloudSyncFailureClassifier.classify(terminal).category,
            .terminal)
    }

    func testExplicitInitialSeedQueuesExistingMeetingAndCompletesAfterDrain() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let meetingStore = try MeetingStore.inMemory()
        let meeting = Meeting(
            title: "Existing before opt-in",
            startedAt: Date(timeIntervalSince1970: 1_784_330_000))
        try await meetingStore.save(meeting)
        for change in try await meetingStore.pendingMeetingSyncChanges() {
            try await meetingStore.acknowledgeMeetingSync(change)
        }
        let pendingBeforeOptIn = try await meetingStore.pendingMeetingSyncChanges()
        XCTAssertTrue(pendingBeforeOptIn.isEmpty)

        let transportStore = try await readyTransportStore(at: root)
        let coordinator = CloudMeetingSyncCoordinator(
            meetingStore: meetingStore,
            transportStore: transportStore,
            localDeviceID: localDeviceID)
        let delegate = CloudMeetingSyncEngineDelegate(
            coordinator: coordinator,
            transportStore: transportStore)
        let now = Date(timeIntervalSince1970: 1_784_330_100)

        let seededCount = try await delegate.requestInitialSeed(at: now)
        let requestedSnapshot = await transportStore.currentSnapshot()
        XCTAssertEqual(seededCount, 1)
        XCTAssertEqual(requestedSnapshot.initialSeedState, .requested)
        let stagedRecordIDs = try await coordinator.stagePendingChanges(at: now)
        let recordID = try XCTUnwrap(stagedRecordIDs.first)
        let encoded = try await coordinator.encodedRecord(for: recordID, at: now)
        let record = try XCTUnwrap(encoded).record
        try await coordinator.handleSavedRecord(record)

        let pendingAfterSend = try await meetingStore.pendingMeetingSyncChanges()
        let completeSnapshot = await transportStore.currentSnapshot()
        XCTAssertTrue(pendingAfterSend.isEmpty)
        XCTAssertEqual(completeSnapshot.initialSeedState, .complete)
    }

    func testServerTombstoneConflictSettlesWithoutRetryingDiscardedLocalWork() async throws {
        let root = temporaryDirectory()
        let assetRoot = temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: assetRoot)
        }
        let meetingStore = try MeetingStore.inMemory()
        let meeting = Meeting(
            title: "Local work loses to deletion",
            startedAt: Date(timeIntervalSince1970: 1_784_330_000))
        try await meetingStore.save(meeting)
        let transportStore = try await readyTransportStore(at: root)
        let coordinator = CloudMeetingSyncCoordinator(
            meetingStore: meetingStore,
            transportStore: transportStore,
            localDeviceID: localDeviceID)
        let now = meeting.startedAt
        let stagedRecordIDs = try await coordinator.stagePendingChanges(at: now)
        let recordID = try XCTUnwrap(stagedRecordIDs.first)
        let encoded = try await coordinator.encodedRecord(for: recordID, at: now)
        let outgoing = try XCTUnwrap(encoded).record
        let outgoingEnvelope = try await transportStore.envelope(from: outgoing)
        let tombstone = MeetingSyncEnvelope(
            meetingID: meeting.id,
            sourceDeviceID: remoteDeviceID,
            generation: outgoingEnvelope.generation + 1,
            changedAt: now.addingTimeInterval(1),
            mutation: .delete)
        let serverRecord = try CloudMeetingRecordCodec().encode(
            tombstone,
            existingRecord: outgoing,
            assetDirectory: assetRoot).record
        let conflict = NSError(
            domain: CKError.errorDomain,
            code: CKError.Code.serverRecordChanged.rawValue,
            userInfo: [CKRecordChangedErrorServerRecordKey: serverRecord])

        let resolution = try await coordinator.handleFailedRecord(
            outgoing,
            error: conflict,
            at: now)

        XCTAssertEqual(
            resolution,
            CloudSyncFailureResolution(category: .serverConflict, shouldRetry: false))
        let deletedDetail = try await meetingStore.detail(meeting.id)
        let pendingAfterConflict = try await meetingStore.pendingMeetingSyncChanges()
        let settledSnapshot = await transportStore.currentSnapshot()
        XCTAssertNil(deletedDetail)
        XCTAssertTrue(pendingAfterConflict.isEmpty)
        XCTAssertTrue(settledSnapshot.attempts.isEmpty)
    }

    private let localDeviceID = UUID(
        uuidString: "40000000-0000-0000-0000-000000000001")!
    private let remoteDeviceID = UUID(
        uuidString: "40000000-0000-0000-0000-000000000002")!

    private func readyTransportStore(
        at root: URL
    ) async throws -> CloudMeetingSyncStateStore {
        let store = try CloudMeetingSyncStateStore(rootDirectory: root)
        let fingerprint = CloudMeetingSyncStateStore.accountFingerprint(
            forCloudRecordName: "icloud-user-a")
        try await store.updateAccount(status: .available, fingerprint: fingerprint)
        try await store.grantConsent(
            forAccountFingerprint: fingerprint,
            at: Date(timeIntervalSince1970: 1_784_330_000))
        return store
    }

    private func newestEnvelope(
        in store: MeetingStore,
        sourceDeviceID: UUID
    ) async throws -> MeetingSyncEnvelope {
        let pending = try await store.pendingMeetingSyncChanges()
        return try await store.meetingSyncEnvelope(
            for: XCTUnwrap(pending.first),
            sourceDeviceID: sourceDeviceID)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("portavoz-cloud-coordinator-tests")
            .appendingPathComponent(UUID().uuidString)
    }
}
