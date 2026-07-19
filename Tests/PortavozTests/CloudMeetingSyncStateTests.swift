import CloudKit
import Foundation
@testable import IntegrationsKit
import PortavozCore
import StorageKit
import XCTest

final class CloudMeetingSyncStateTests: XCTestCase {
    func testConsentAndInitialSeedStayExplicitAndAccountScoped() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try CloudMeetingSyncStateStore(rootDirectory: root)
        let first = fingerprint("icloud-user-a")
        let second = fingerprint("icloud-user-b")
        let now = Date(timeIntervalSince1970: 1_784_320_000)

        var snapshot = await store.currentSnapshot()
        XCTAssertEqual(snapshot.initialSeedState, .blocked)
        try await store.updateAccount(status: .available, fingerprint: first)
        snapshot = await store.currentSnapshot()
        XCTAssertEqual(snapshot.initialSeedState, .blocked)
        try await store.grantConsent(forAccountFingerprint: first, at: now)
        snapshot = await store.currentSnapshot()
        XCTAssertEqual(snapshot.initialSeedState, .notRequested)

        try await store.requestInitialSeed(at: now)
        snapshot = await store.currentSnapshot()
        XCTAssertEqual(snapshot.initialSeedState, .requested)
        try await store.markInitialSeedComplete(at: now.addingTimeInterval(1))
        snapshot = await store.currentSnapshot()
        XCTAssertEqual(snapshot.initialSeedState, .complete)

        try await store.updateAccount(status: .available, fingerprint: second)
        snapshot = await store.currentSnapshot()
        XCTAssertFalse(snapshot.isTransportReady)
        try await store.grantConsent(forAccountFingerprint: second, at: now)
        snapshot = await store.currentSnapshot()
        XCTAssertEqual(
            snapshot.initialSeedState,
            .notRequested,
            "a different iCloud account requires its own explicit initial seed")
    }

    func testExactAttemptSurvivesRestartAndLateSuccessCannotEraseNewerGeneration() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        var store = try await readyStore(at: root)
        let first = makeEnvelope(generation: 1, title: "Private first generation")
        let second = makeEnvelope(generation: 2, title: "Private second generation")
        let firstAttempt = try await store.stage(first, at: first.changedAt)
        let firstRecordCandidate = try await store.encodedRecord(
            for: CloudMeetingRecordCodec.recordID(for: first.meetingID),
            at: first.changedAt)
        let firstRecord = try XCTUnwrap(firstRecordCandidate)

        let stateData = try Data(contentsOf: root.appendingPathComponent("transport-state.json"))
        XCTAssertFalse(String(decoding: stateData, as: UTF8.self).contains(first.mutationTitle))
        let payloadURL = root
            .appendingPathComponent("payloads")
            .appendingPathComponent(firstAttempt.payloadFileName)
        let permissions = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: payloadURL.path)[.posixPermissions]
                as? NSNumber)
        XCTAssertEqual(permissions.intValue & 0o777, 0o600)

        store = try CloudMeetingSyncStateStore(rootDirectory: root)
        let restoredCandidate = try await store.encodedRecord(
            for: firstRecord.record.recordID,
            at: first.changedAt)
        let restored = try XCTUnwrap(restoredCandidate)
        let restoredEnvelope = try await store.envelope(from: restored.record)
        XCTAssertEqual(restoredEnvelope.generation, first.generation)

        _ = try await store.stage(second, at: second.changedAt)
        let remote = makeEnvelope(
            generation: 3,
            sourceDeviceID: UUID(
                uuidString: "30000000-0000-0000-0000-000000000099")!,
            title: "Deferred remote generation")
        let assetRoot = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: assetRoot) }
        let remoteRecord = try CloudMeetingRecordCodec().encode(
            remote,
            assetDirectory: assetRoot).record
        try await store.stageDeferredReplay(remote, from: remoteRecord)
        let completedOldSend = try await store.completeSend(
            of: first,
            savedRecord: firstRecord.record)
        XCTAssertFalse(completedOldSend)
        let snapshot = await store.currentSnapshot()
        XCTAssertEqual(snapshot.attempts.map(\.generation), [second.generation])
        XCTAssertEqual(
            snapshot.deferredReplays.map(\.generation),
            [remote.generation],
            "a stale save acknowledgment must not erase deferred remote work")
        let newestCandidate = try await store.encodedRecord(
            for: firstRecord.record.recordID,
            at: second.changedAt)
        let newest = try XCTUnwrap(newestCandidate)
        let newestEnvelope = try await store.envelope(from: newest.record)
        XCTAssertEqual(newestEnvelope.generation, 2)
    }

    func testAccountLossAndPartialFailurePreserveIndependentAttempts() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try await readyStore(at: root)
        let now = Date(timeIntervalSince1970: 1_784_320_000)
        let first = makeEnvelope(generation: 1, meetingOffset: 1)
        let second = makeEnvelope(generation: 1, meetingOffset: 2)
        _ = try await store.stage(first, at: now)
        _ = try await store.stage(second, at: now)
        let firstRecordCandidate = try await store.encodedRecord(
            for: CloudMeetingRecordCodec.recordID(for: first.meetingID),
            at: now)
        let firstRecord = try XCTUnwrap(firstRecordCandidate)

        try await store.markFailure(
            for: second,
            category: .transient,
            serverRetryAfter: 30,
            at: now)
        let completedFirst = try await store.completeSend(
            of: first,
            savedRecord: firstRecord.record)
        XCTAssertTrue(completedFirst)
        var snapshot = await store.currentSnapshot()
        XCTAssertEqual(snapshot.attempts.map(\.meetingID), [second.meetingID])
        XCTAssertEqual(snapshot.attempts.first?.attemptCount, 1)
        XCTAssertEqual(snapshot.attempts.first?.nextRetryAt, now.addingTimeInterval(30))
        let readyNow = await store.readyRecordIDs(at: now)
        let readyLater = await store.readyRecordIDs(at: now.addingTimeInterval(31))
        XCTAssertTrue(readyNow.isEmpty)
        XCTAssertEqual(readyLater.count, 1)

        try await store.updateAccount(status: .signedOut, fingerprint: nil)
        let readyWhileSignedOut = await store.readyRecordIDs(
            at: now.addingTimeInterval(31))
        XCTAssertTrue(readyWhileSignedOut.isEmpty)
        snapshot = await store.currentSnapshot()
        XCTAssertEqual(snapshot.attempts.count, 1, "account loss must not erase retry state")

        let restarted = try CloudMeetingSyncStateStore(rootDirectory: root)
        let restartedSnapshot = await restarted.currentSnapshot()
        XCTAssertEqual(restartedSnapshot.attempts, snapshot.attempts)
    }

    func testReplayCursorIsPerMeetingAndDetectsEqualGenerationCollision() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try await readyStore(at: root)
        let remoteDevice = UUID(uuidString: "30000000-0000-0000-0000-000000000099")!
        let first = makeEnvelope(
            generation: 4,
            meetingOffset: 1,
            sourceDeviceID: remoteDevice,
            title: "Remote first")
        let second = makeEnvelope(
            generation: 4,
            meetingOffset: 2,
            sourceDeviceID: remoteDevice,
            title: "Remote second")

        var decision = try await store.replayDecision(
            for: first, localDeviceID: localDeviceID)
        XCTAssertEqual(decision, .apply)
        try await store.markReplayApplied(first)
        decision = try await store.replayDecision(
            for: first, localDeviceID: localDeviceID)
        XCTAssertEqual(decision, .ignoreDuplicate)
        decision = try await store.replayDecision(
            for: second,
            localDeviceID: localDeviceID)
        XCTAssertEqual(
            decision,
            .apply,
            "generations are per meeting, not global per source device")
        decision = try await store.replayDecision(
            for: first,
            localDeviceID: remoteDevice)
        XCTAssertEqual(decision, .ignoreOwnDevice)

        let collision = makeEnvelope(
            generation: 4,
            meetingOffset: 1,
            sourceDeviceID: remoteDevice,
            title: "Different bytes at the same generation")
        await XCTAssertThrowsAsync {
            _ = try await store.replayDecision(
                for: collision,
                localDeviceID: self.localDeviceID)
        } verify: { error in
            XCTAssertEqual(error as? CloudMeetingTransportError, .generationCollision)
        }
    }

    func testDeferredReplayFencesStaleAndEqualGenerationBeforeCheckpoint() async throws {
        let root = temporaryDirectory()
        let assetRoot = temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: assetRoot)
        }
        let store = try await readyStore(at: root)
        let remoteDevice = UUID(uuidString: "30000000-0000-0000-0000-000000000099")!
        let newest = makeEnvelope(
            generation: 6,
            sourceDeviceID: remoteDevice,
            title: "Newest deferred remote")
        let record = try CloudMeetingRecordCodec().encode(
            newest,
            assetDirectory: assetRoot).record
        try await store.stageDeferredReplay(newest, from: record)

        let stale = makeEnvelope(
            generation: 5,
            sourceDeviceID: remoteDevice,
            title: "Stale remote")
        let staleDecision = try await store.replayDecision(
            for: stale,
            localDeviceID: localDeviceID)
        let duplicateDecision = try await store.replayDecision(
            for: newest,
            localDeviceID: localDeviceID)
        XCTAssertEqual(staleDecision, .ignoreStale)
        XCTAssertEqual(duplicateDecision, .ignoreDuplicate)

        let collision = makeEnvelope(
            generation: 6,
            sourceDeviceID: remoteDevice,
            title: "Conflicting bytes")
        await XCTAssertThrowsAsync {
            _ = try await store.replayDecision(
                for: collision,
                localDeviceID: self.localDeviceID)
        } verify: { error in
            XCTAssertEqual(error as? CloudMeetingTransportError, .generationCollision)
        }
    }

    func testAccountSwitchClearsOnlyAccountScopedTransportState() async throws {
        let root = temporaryDirectory()
        let assetRoot = temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: assetRoot)
        }
        let store = try await readyStore(at: root)
        let now = Date(timeIntervalSince1970: 1_784_320_000)
        let outgoing = makeEnvelope(generation: 1, meetingOffset: 1)
        _ = try await store.stage(outgoing, at: now)

        let remoteDevice = UUID(uuidString: "30000000-0000-0000-0000-000000000099")!
        let applied = makeEnvelope(
            generation: 1,
            meetingOffset: 2,
            sourceDeviceID: remoteDevice,
            title: "Applied remote")
        try await store.markReplayApplied(applied)
        let deferred = makeEnvelope(
            generation: 2,
            meetingOffset: 2,
            sourceDeviceID: remoteDevice,
            title: "Deferred remote")
        let remoteRecord = try CloudMeetingRecordCodec().encode(
            deferred,
            assetDirectory: assetRoot).record
        try await store.stageDeferredReplay(deferred, from: remoteRecord)
        try await store.requestInitialSeed(at: now)

        let secondAccount = fingerprint("icloud-user-b")
        try await store.updateAccount(status: .available, fingerprint: secondAccount)
        let snapshot = await store.currentSnapshot()

        XCTAssertEqual(snapshot.accountScopeFingerprint, secondAccount)
        XCTAssertFalse(snapshot.isTransportReady)
        XCTAssertNil(snapshot.consentedAccountFingerprint)
        XCTAssertNil(snapshot.consentGrantedAt)
        XCTAssertEqual(snapshot.initialSeedState, .blocked)
        XCTAssertEqual(snapshot.attempts.map(\.meetingID), [outgoing.meetingID])
        XCTAssertTrue(snapshot.deferredReplays.isEmpty)
        XCTAssertTrue(snapshot.replayCursors.isEmpty)
        XCTAssertTrue(snapshot.recordMetadata.isEmpty)
        XCTAssertNil(snapshot.engineStateData)
        let payloadNames = try FileManager.default.contentsOfDirectory(
            at: root.appendingPathComponent("payloads"),
            includingPropertiesForKeys: nil).map(\.lastPathComponent)
        XCTAssertEqual(payloadNames, snapshot.attempts.map(\.payloadFileName))
    }

    func testProtectedPayloadCorruptionFailsClosedOnRestart() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try await readyStore(at: root)
        let envelope = makeEnvelope(generation: 1)
        let attempt = try await store.stage(envelope, at: envelope.changedAt)
        let payloadURL = root
            .appendingPathComponent("payloads")
            .appendingPathComponent(attempt.payloadFileName)
        try Data("tampered".utf8).write(to: payloadURL, options: .atomic)

        XCTAssertThrowsError(try CloudMeetingSyncStateStore(rootDirectory: root)) { error in
            XCTAssertEqual(error as? CloudMeetingTransportError, .payloadCorrupted)
        }
    }

    func testSnapshotMutationRollsBackWhenAtomicPersistenceFails() async throws {
        let root = temporaryDirectory()
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: root.path)
            try? FileManager.default.removeItem(at: root)
        }
        let store = try await readyStore(at: root)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500],
            ofItemAtPath: root.path)

        await XCTAssertThrowsAsync {
            try await store.revokeConsent()
        } verify: { _ in }

        let snapshot = await store.currentSnapshot()
        XCTAssertTrue(snapshot.isTransportReady)
        XCTAssertNotNil(snapshot.consentedAccountFingerprint)
    }

    func testProtectedPublicationReplacesStateWithoutExposingStagingFiles() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try await readyStore(at: root)
        let envelope = makeEnvelope(generation: 1)

        _ = try await store.stage(envelope, at: envelope.changedAt)
        try await store.revokeConsent()

        let stateURL = root.appendingPathComponent("transport-state.json")
        let snapshot = await store.currentSnapshot()
        let payloadFileName = try XCTUnwrap(snapshot.attempts.first?.payloadFileName)
        let payloadURL = root
            .appendingPathComponent("payloads")
            .appendingPathComponent(payloadFileName)
        try assertProtected(stateURL)
        try assertProtected(payloadURL)

        let rootNames = try FileManager.default.contentsOfDirectory(atPath: root.path)
        let payloadNames = try FileManager.default.contentsOfDirectory(
            atPath: root.appendingPathComponent("payloads").path)
        XCTAssertFalse((rootNames + payloadNames).contains {
            $0.hasSuffix(".staging") || $0.hasPrefix(".portavoz-metadata-probe.")
        })
    }

    func testRetryPolicyIsDeterministicAndBounded() {
        let policy = CloudSyncRetryPolicy(baseDelay: 5, maximumDelay: 60)
        XCTAssertEqual(policy.delay(afterAttempt: 1, serverRetryAfter: nil), 5)
        XCTAssertEqual(policy.delay(afterAttempt: 3, serverRetryAfter: nil), 20)
        XCTAssertEqual(policy.delay(afterAttempt: 2, serverRetryAfter: 45), 45)
        XCTAssertEqual(policy.delay(afterAttempt: 20, serverRetryAfter: nil), 60)
    }

    private let localDeviceID = UUID(
        uuidString: "30000000-0000-0000-0000-000000000001")!

    private func readyStore(at root: URL) async throws -> CloudMeetingSyncStateStore {
        let store = try CloudMeetingSyncStateStore(rootDirectory: root)
        let account = fingerprint("icloud-user-a")
        try await store.updateAccount(status: .available, fingerprint: account)
        try await store.grantConsent(
            forAccountFingerprint: account,
            at: Date(timeIntervalSince1970: 1_784_320_000))
        return store
    }

    private func fingerprint(_ recordName: String) -> String {
        CloudMeetingSyncStateStore.accountFingerprint(forCloudRecordName: recordName)
    }

    private func assertProtected(
        _ url: URL,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let capabilities = try CloudSyncProtectedFile.publicationCapabilities(
            in: url.deletingLastPathComponent())
        let permissions = try XCTUnwrap(
            attributes[.posixPermissions] as? NSNumber,
            file: file,
            line: line)
        let isExcludedFromBackup: Bool? = if capabilities.backupExclusion {
            try url.resourceValues(
                forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup
        } else {
            nil
        }
        XCTAssertEqual(permissions.intValue & 0o777, 0o600, file: file, line: line)
        XCTAssertTrue(
            !capabilities.completeProtection
                || attributes[.protectionKey] as? FileProtectionType == .complete,
            file: file,
            line: line)
        XCTAssertTrue(
            !capabilities.backupExclusion
                || isExcludedFromBackup == true,
            file: file,
            line: line)
    }

    private func makeEnvelope(
        generation: Int,
        meetingOffset: Int = 1,
        sourceDeviceID: UUID? = nil,
        title: String = "Private roadmap"
    ) -> MeetingSyncEnvelope {
        let meetingID = MeetingID(rawValue: UUID(
            uuidString: String(format:
                "30000000-0000-0000-0000-%012d", meetingOffset))!)
        let changedAt = Date(timeIntervalSince1970: 1_784_320_000 + Double(generation))
        let meeting = Meeting(id: meetingID, title: title, startedAt: changedAt, language: "es")
        return MeetingSyncEnvelope(
            meetingID: meetingID,
            sourceDeviceID: sourceDeviceID ?? localDeviceID,
            generation: generation,
            changedAt: changedAt,
            mutation: .upsert(MeetingSyncAggregate(
                meeting: MeetingSyncTimed(
                    value: meeting,
                    createdAt: changedAt,
                    updatedAt: changedAt),
                speakers: [],
                segments: [],
                summaries: [],
                contextItems: [],
                companionCards: [])))
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("portavoz-cloud-state-tests")
            .appendingPathComponent(UUID().uuidString)
    }
}

private extension MeetingSyncEnvelope {
    var mutationTitle: String {
        guard case .upsert(let aggregate) = mutation else { return "" }
        return aggregate.meeting.value.title
    }
}

private func XCTAssertThrowsAsync(
    _ expression: @escaping () async throws -> Void,
    verify: (Error) -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected error", file: file, line: line)
    } catch {
        verify(error)
    }
}
