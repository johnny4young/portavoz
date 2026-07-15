import Foundation
import GRDB
import PortavozCore
import XCTest

@testable import StorageKit

final class ProcessingJobPersistenceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_783_699_200)

    private func meeting(
        id: MeetingID = MeetingID(),
        lifecycle: MeetingLifecycleState = .captured
    ) -> Meeting {
        Meeting(
            id: id,
            title: "Durable processing",
            startedAt: now.addingTimeInterval(-60),
            endedAt: now,
            audioDirectory: "Audio/\(id.rawValue.uuidString)",
            lifecycleState: lifecycle)
    }

    private func detail(
        _ meetingID: MeetingID,
        in store: MeetingStore
    ) async throws -> MeetingDetail {
        let loaded = try await store.detail(meetingID)
        return try XCTUnwrap(loaded)
    }

    func testEnqueueIsAtomicIdempotentAndAdvancesMeeting() async throws {
        let store = try MeetingStore.inMemory()
        let captured = meeting()
        try await store.save(captured)
        let requests = [
            ProcessingJobRequest(
                kind: .diarization, inputFingerprint: "audio-sha-1", priority: 20),
            ProcessingJobRequest(
                kind: .summary, inputFingerprint: "transcript-revision-0", priority: 10),
        ]

        let first = try await store.enqueueProcessingJobs(
            for: captured.id, requests: requests, at: now)
        let second = try await store.enqueueProcessingJobs(
            for: captured.id,
            requests: [
                ProcessingJobRequest(
                    kind: .diarization, inputFingerprint: "audio-sha-1", priority: -100),
                requests[1],
            ],
            at: now.addingTimeInterval(5))

        XCTAssertEqual(first.map(\.id), second.map(\.id))
        XCTAssertEqual(second.map(\.priority), [20, 10])
        XCTAssertTrue(first.allSatisfy { $0.state == .pending && $0.attempt == 0 })
        let jobs = try await store.processingJobs(for: captured.id)
        XCTAssertEqual(jobs.count, 2)
        let storedDetail = try await detail(captured.id, in: store)
        XCTAssertEqual(storedDetail.meeting.lifecycleState, .processing)
        XCTAssertNil(storedDetail.meeting.lastProcessingError)
    }

    func testEnqueueRejectsInvalidBatchBeforeWriting() async throws {
        let store = try MeetingStore.inMemory()
        let captured = meeting()
        try await store.save(captured)
        let duplicate = ProcessingJobRequest(
            kind: .summary, inputFingerprint: "transcript-revision-0")

        do {
            _ = try await store.enqueueProcessingJobs(
                for: captured.id,
                requests: [duplicate, duplicate],
                at: now)
            XCTFail("duplicate idempotency keys must be rejected")
        } catch {
            guard case StorageError.invalidProcessingJob = error else {
                return XCTFail("wrong error: \(error)")
            }
        }
        let capturedJobs = try await store.processingJobs(for: captured.id)
        XCTAssertTrue(capturedJobs.isEmpty)
        let capturedDetail = try await detail(captured.id, in: store)
        XCTAssertEqual(capturedDetail.meeting.lifecycleState, .captured)

        let recording = meeting(lifecycle: .recording)
        try await store.save(recording)
        do {
            _ = try await store.enqueueProcessingJobs(
                for: recording.id, requests: [duplicate], at: now)
            XCTFail("capture must be installed before enqueue")
        } catch {
            guard case StorageError.invalidProcessingJob = error else {
                return XCTFail("wrong error: \(error)")
            }
        }
        let recordingJobs = try await store.processingJobs(for: recording.id)
        XCTAssertTrue(recordingJobs.isEmpty)
    }

    func testLeaseClaimHeartbeatAndCompletionAreOwnerBound() async throws {
        let store = try MeetingStore.inMemory()
        let captured = meeting()
        try await store.save(captured)
        _ = try await store.enqueueProcessingJobs(
            for: captured.id,
            requests: [
                ProcessingJobRequest(
                    kind: .summary, inputFingerprint: "summary-0", priority: 10),
                ProcessingJobRequest(
                    kind: .index, inputFingerprint: "index-0", priority: 1),
            ],
            at: now)

        let firstClaimValue = try await store.claimNextProcessingJob(
            kinds: [.summary, .index], owner: "worker-a", leaseDuration: 30, at: now)
        let firstClaim = try XCTUnwrap(firstClaimValue)
        XCTAssertEqual(firstClaim.kind, .summary)
        XCTAssertEqual(firstClaim.state, .running)
        XCTAssertEqual(firstClaim.attempt, 1)

        do {
            _ = try await store.heartbeatProcessingJob(
                firstClaim.id,
                owner: "worker-b",
                progress: 0.4,
                leaseDuration: 30,
                at: now.addingTimeInterval(1))
            XCTFail("another worker cannot mutate the lease")
        } catch {
            guard case StorageError.processingJobLeaseLost(let id) = error else {
                return XCTFail("wrong error: \(error)")
            }
            XCTAssertEqual(id, firstClaim.id)
        }

        let heartbeat = try await store.heartbeatProcessingJob(
            firstClaim.id,
            owner: "worker-a",
            progress: 0.4,
            leaseDuration: 60,
            at: now.addingTimeInterval(1))
        XCTAssertEqual(heartbeat.progress, 0.4)
        XCTAssertEqual(heartbeat.leaseExpiresAt, now.addingTimeInterval(61))

        let secondClaimValue = try await store.claimNextProcessingJob(
            kinds: [.summary, .index], owner: "worker-b", leaseDuration: 30, at: now)
        let secondClaim = try XCTUnwrap(secondClaimValue)
        XCTAssertEqual(secondClaim.kind, .index)
        _ = try await store.completeProcessingJob(
            firstClaim.id, owner: "worker-a", at: now.addingTimeInterval(2))
        let processingDetail = try await detail(captured.id, in: store)
        XCTAssertEqual(processingDetail.meeting.lifecycleState, .processing)

        _ = try await store.completeProcessingJob(
            secondClaim.id, owner: "worker-b", at: now.addingTimeInterval(2))
        let readyDetail = try await detail(captured.id, in: store)
        XCTAssertEqual(readyDetail.meeting.lifecycleState, .ready)
        XCTAssertNil(readyDetail.meeting.lastProcessingError)
        let jobs = try await store.processingJobs(for: captured.id)
        XCTAssertTrue(jobs.allSatisfy { $0.state == .succeeded && $0.progress == 1 })
    }

    func testClaimHonorsWorkerKindsAndSkipsDeletedMeetings() async throws {
        let store = try MeetingStore.inMemory()
        let deleted = meeting()
        let live = meeting()
        try await store.save(deleted)
        try await store.save(live)
        _ = try await store.enqueueProcessingJobs(
            for: deleted.id,
            requests: [
                ProcessingJobRequest(
                    kind: .summary, inputFingerprint: "deleted-summary", priority: 100),
            ],
            at: now)
        _ = try await store.enqueueProcessingJobs(
            for: live.id,
            requests: [
                ProcessingJobRequest(
                    kind: .index, inputFingerprint: "live-index", priority: 1),
            ],
            at: now)
        try await store.delete(deleted.id)

        let unsupported = try await store.claimNextProcessingJob(
            kinds: [.summary], owner: "worker", leaseDuration: 10, at: now)
        XCTAssertNil(unsupported)
        let claim = try await store.claimNextProcessingJob(
            kinds: [.index], owner: "worker", leaseDuration: 10, at: now)
        XCTAssertEqual(claim?.meetingID, live.id)
        let hiddenJobs = try await store.processingJobs(for: deleted.id)
        XCTAssertTrue(hiddenJobs.isEmpty)
    }

    func testFailureRetriesThenExhaustsWithoutDuplicatingJob() async throws {
        let store = try MeetingStore.inMemory()
        let captured = meeting()
        try await store.save(captured)
        let request = ProcessingJobRequest(
            kind: .diarization,
            inputFingerprint: "audio-sha-1",
            maxAttempts: 2)
        let enqueued = try await store.enqueueProcessingJobs(
            for: captured.id, requests: [request], at: now)
        let jobID = try XCTUnwrap(enqueued.first?.id)

        let firstClaim = try await store.claimNextProcessingJob(
            kinds: [.diarization], owner: "worker", leaseDuration: 10, at: now)
        XCTAssertEqual(firstClaim?.id, jobID)
        let retryAt = now.addingTimeInterval(20)
        let pending = try await store.failProcessingJob(
            jobID,
            owner: "worker",
            failure: ProcessingJobFailure(code: "diarization.transient"),
            retryAt: retryAt,
            at: now.addingTimeInterval(1))
        XCTAssertEqual(pending.state, .pending)
        XCTAssertEqual(pending.attempt, 1)
        XCTAssertEqual(pending.notBefore, retryAt)
        let earlyClaim = try await store.claimNextProcessingJob(
            kinds: [.diarization], owner: "worker", leaseDuration: 10,
            at: retryAt.addingTimeInterval(-1))
        XCTAssertNil(earlyClaim)

        let secondClaim = try await store.claimNextProcessingJob(
            kinds: [.diarization], owner: "worker", leaseDuration: 10, at: retryAt)
        XCTAssertEqual(secondClaim?.attempt, 2)
        let failed = try await store.failProcessingJob(
            jobID,
            owner: "worker",
            failure: ProcessingJobFailure(
                code: "diarization.exhausted", message: "Model could not finish."),
            retryAt: retryAt.addingTimeInterval(20),
            at: retryAt.addingTimeInterval(1))
        XCTAssertEqual(failed.state, .failed)
        XCTAssertNil(failed.notBefore)

        let repeated = try await store.enqueueProcessingJobs(
            for: captured.id, requests: [request], at: retryAt.addingTimeInterval(2))
        XCTAssertEqual(repeated.map(\.id), [jobID])
        let attentionDetail = try await detail(captured.id, in: store)
        XCTAssertEqual(attentionDetail.meeting.lifecycleState, .needsAttention)
        XCTAssertEqual(attentionDetail.meeting.lastProcessingError, "diarization.exhausted")
    }

    func testExpiredLeaseRecoveryIsRepeatSafeAndExhaustsAttempts() async throws {
        let store = try MeetingStore.inMemory()
        let captured = meeting()
        try await store.save(captured)
        _ = try await store.enqueueProcessingJobs(
            for: captured.id,
            requests: [
                ProcessingJobRequest(
                    kind: .summary, inputFingerprint: "summary-0", maxAttempts: 2),
            ],
            at: now)
        let firstClaimValue = try await store.claimNextProcessingJob(
            kinds: [.summary], owner: "worker", leaseDuration: 10, at: now)
        let jobID = try XCTUnwrap(firstClaimValue?.id)

        let firstRecovery = try await store.recoverExpiredProcessingJobs(
            at: now.addingTimeInterval(11))
        XCTAssertEqual(firstRecovery.map(\.id), [jobID])
        XCTAssertEqual(firstRecovery.first?.state, .pending)
        XCTAssertEqual(firstRecovery.first?.errorCode, "processing.lease.expired")
        let repeatedRecovery = try await store.recoverExpiredProcessingJobs(
            at: now.addingTimeInterval(12))
        XCTAssertTrue(repeatedRecovery.isEmpty)

        let secondClaim = try await store.claimNextProcessingJob(
            kinds: [.summary], owner: "worker", leaseDuration: 10,
            at: now.addingTimeInterval(12))
        XCTAssertEqual(secondClaim?.attempt, 2)
        let exhausted = try await store.recoverExpiredProcessingJobs(
            at: now.addingTimeInterval(23))
        XCTAssertEqual(exhausted.first?.state, .failed)
        XCTAssertEqual(exhausted.first?.errorCode, "processing.lease.exhausted")
        let attentionDetail = try await detail(captured.id, in: store)
        XCTAssertEqual(attentionDetail.meeting.lifecycleState, .needsAttention)
        XCTAssertEqual(
            attentionDetail.meeting.lastProcessingError,
            "processing.lease.exhausted")
    }

    func testProcessingJobRecordRejectsCorruptIdentityStateAndLeaseContract() throws {
        let captured = meeting()
        let job = ProcessingJob(
            meetingID: captured.id,
            kind: .summary,
            inputFingerprint: "summary-0",
            createdAt: now)
        var record = ProcessingJobRecord(job)

        record.id = "not-a-uuid"
        XCTAssertThrowsError(try record.job) { error in
            guard case StorageError.invalidPersistedUUID(
                table: "processingJob", column: "id", value: "not-a-uuid") = error
            else { return XCTFail("wrong error: \(error)") }
        }
        record = ProcessingJobRecord(job)
        record.state = "unknown"
        XCTAssertThrowsError(try record.job) { error in
            guard case StorageError.invalidPersistedValue(
                table: "processingJob", column: "state", value: "unknown") = error
            else { return XCTFail("wrong error: \(error)") }
        }
        record = ProcessingJobRecord(job)
        record.state = ProcessingJobState.running.rawValue
        record.attempt = 1
        XCTAssertThrowsError(try record.job) { error in
            guard case StorageError.invalidPersistedValue(
                table: "processingJob", column: "stateContract", value: _) = error
            else { return XCTFail("wrong error: \(error)") }
        }
    }
}
