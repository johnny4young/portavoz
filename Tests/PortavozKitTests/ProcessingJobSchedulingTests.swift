import Foundation
import PortavozCore
import StorageKit
import Testing

struct ProcessingJobSchedulingTests {
    private var now: Date { Date(timeIntervalSince1970: 1_783_699_200) }

    @Test
    func scheduledRetryAtItsExactDeadlineWakesImmediately() async throws {
        let (store, meeting) = try await fixture()
        let deadline = now.addingTimeInterval(30)
        _ = try await enqueue(.summary, in: store, meeting: meeting, deadline: deadline)

        let wake = try await store.nextScheduledProcessingDate(kinds: [.summary], after: deadline)

        #expect(wake == deadline)
    }

    @Test
    func retryBecomingDueAfterTheLastEmptyClaimStillSchedulesAWake() async throws {
        let (store, meeting) = try await fixture()
        let deadline = now.addingTimeInterval(30)
        _ = try await enqueue(.summary, in: store, meeting: meeting, deadline: deadline)
        let lastClaim = try await store.claimNextProcessingJob(
            kinds: [.summary], owner: "worker-a", leaseDuration: 120,
            at: deadline.addingTimeInterval(-1))
        #expect(lastClaim == nil)
        let queryDate = deadline.addingTimeInterval(1)

        let wake = try await store.nextScheduledProcessingDate(kinds: [.summary], after: queryDate)

        #expect(wake == queryDate)
    }

    @Test
    func leaseAtItsExactExpirySchedulesImmediateRecovery() async throws {
        let (store, meeting) = try await fixture()
        let job = try await enqueue(.summary, in: store, meeting: meeting)
        _ = try await claim(in: store, owner: "worker-a", leaseDuration: 30, at: now)
        let deadline = now.addingTimeInterval(30)

        let wake = try await store.nextScheduledProcessingDate(kinds: [.summary], after: deadline)

        #expect(wake == deadline)
        let reclaimed = try await claim(in: store, owner: "worker-b", leaseDuration: 30, at: deadline)
        #expect(reclaimed.id == job.id)
        #expect(reclaimed.attempt == 2)
        #expect(reclaimed.leaseOwner == "worker-b")
    }

    @Test
    func leaseExpiringBetweenEmptyClaimAndSchedulingReadStillWakes() async throws {
        let (store, meeting) = try await fixture()
        _ = try await enqueue(.summary, in: store, meeting: meeting)
        _ = try await claim(in: store, owner: "worker-a", leaseDuration: 30, at: now)
        let lastClaim = try await store.claimNextProcessingJob(
            kinds: [.summary], owner: "worker-b", leaseDuration: 30,
            at: now.addingTimeInterval(29))
        #expect(lastClaim == nil)
        let queryDate = now.addingTimeInterval(31)

        let wake = try await store.nextScheduledProcessingDate(kinds: [.summary], after: queryDate)

        #expect(wake == queryDate)
    }

    @Test
    func finalAttemptLeaseStillWakesToPublishExhaustion() async throws {
        let (store, meeting) = try await fixture()
        _ = try await enqueue(.summary, in: store, meeting: meeting, maxAttempts: 1)
        _ = try await claim(in: store, owner: "worker-a", leaseDuration: 30, at: now)
        let queryDate = now.addingTimeInterval(31)

        let wake = try await store.nextScheduledProcessingDate(kinds: [.summary], after: queryDate)
        #expect(wake == queryDate)
        let nextClaim = try await store.claimNextProcessingJob(
            kinds: [.summary], owner: "worker-b", leaseDuration: 30, at: queryDate)

        #expect(nextClaim == nil)
        let jobs = try await store.processingJobs(for: meeting.id)
        let exhausted = try #require(jobs.first)
        #expect(exhausted.state == .failed)
        #expect(exhausted.errorCode == "processing.lease.exhausted")
        let storedDetail = try await store.detail(meeting.id)
        let detail = try #require(storedDetail)
        #expect(detail.meeting.lifecycleState == .needsAttention)
    }

    @Test
    func ownerHeartbeatReprogramsTheWakeWithoutAllowingEarlyReclaim() async throws {
        let (store, meeting) = try await fixture()
        let job = try await enqueue(.summary, in: store, meeting: meeting)
        _ = try await claim(in: store, owner: "worker-a", leaseDuration: 30, at: now)
        let originalWake = try await store.nextScheduledProcessingDate(kinds: [.summary], after: now)
        #expect(originalWake == now.addingTimeInterval(30))
        _ = try await store.heartbeatProcessingJob(
            job.id, owner: "worker-a", progress: 0.25, leaseDuration: 120,
            at: now.addingTimeInterval(10))

        let earlyClaim = try await store.claimNextProcessingJob(
            kinds: [.summary], owner: "worker-b", leaseDuration: 30,
            at: now.addingTimeInterval(31))
        let wake = try await store.nextScheduledProcessingDate(
            kinds: [.summary], after: now.addingTimeInterval(31))

        #expect(earlyClaim == nil)
        #expect(wake == now.addingTimeInterval(130))
    }

    @Test
    func staleOwnerCannotCancelOrSuspendAReclaimedLease() async throws {
        let (store, meeting) = try await fixture()
        let job = try await enqueue(.summary, in: store, meeting: meeting)
        _ = try await claim(in: store, owner: "worker-a", leaseDuration: 30, at: now)
        let takeoverDate = now.addingTimeInterval(30)
        let successor = try await claim(
            in: store, owner: "worker-b", leaseDuration: 120, at: takeoverDate)

        do {
            _ = try await store.cancelProcessingJob(
                job.id, owner: "worker-a", reason: .init(code: "processing.cancelled"), at: takeoverDate)
            Issue.record("An expired owner must not cancel its successor's lease")
        } catch StorageError.processingJobLeaseLost(let id) {
            #expect(id == job.id)
        }
        do {
            _ = try await store.suspendProcessingJob(job.id, owner: "worker-a", at: takeoverDate)
            Issue.record("An expired owner must not refund its successor's attempt")
        } catch StorageError.processingJobLeaseLost(let id) {
            #expect(id == job.id)
        }

        let jobs = try await store.processingJobs(for: meeting.id)
        #expect(jobs == [successor])
        #expect(successor.id == job.id)
        #expect(successor.attempt == 2)
        #expect(successor.leaseOwner == "worker-b")
        #expect(successor.leaseExpiresAt == takeoverDate.addingTimeInterval(120))
    }

    @Test
    func intentionalSuspensionHasNoImmediateTimerAndRefundsTheAttempt() async throws {
        let (store, meeting) = try await fixture()
        let job = try await enqueue(.summary, in: store, meeting: meeting, maxAttempts: 1)
        _ = try await claim(in: store, owner: "worker-a", leaseDuration: 30, at: now)
        let suspended = try await store.suspendProcessingJob(
            job.id, owner: "worker-a", at: now.addingTimeInterval(1))

        let wake = try await store.nextScheduledProcessingDate(
            kinds: [.summary], after: now.addingTimeInterval(2))

        #expect(wake == nil, "Intentional suspension must wait for a signal without an immediate timer")
        #expect(suspended.state == .pending)
        #expect(suspended.attempt == 0)
        #expect(suspended.progress == 0)
        #expect(suspended.notBefore == nil)
        #expect(suspended.leaseOwner == nil)
        #expect(suspended.leaseExpiresAt == nil)
        let recovered = try await store.recoverExpiredProcessingJobs(at: now.addingTimeInterval(100))
        #expect(recovered.isEmpty)
    }

    @Test
    func overdueWakeStillFiltersUnsupportedKindsAndDeletedMeetings() async throws {
        let (store, liveMeeting) = try await fixture()
        _ = try await enqueue(
            .diarization, in: store, meeting: liveMeeting, deadline: now.addingTimeInterval(10))
        let deletedMeeting = Meeting(
            title: "Deleted meeting", startedAt: now, lifecycleState: .captured)
        try await store.save(deletedMeeting)
        _ = try await enqueue(.summary, in: store, meeting: deletedMeeting)
        _ = try await claim(in: store, owner: "deleted-owner", leaseDuration: 10, at: now)
        try await store.delete(deletedMeeting.id)
        let queryDate = now.addingTimeInterval(20)

        let summaryWake = try await store.nextScheduledProcessingDate(kinds: [.summary], after: queryDate)
        let diarizationWake = try await store.nextScheduledProcessingDate(
            kinds: [.diarization], after: queryDate)

        #expect(summaryWake == nil)
        #expect(diarizationWake == queryDate)
    }

    private func fixture() async throws -> (MeetingStore, Meeting) {
        let store = try MeetingStore.inMemory()
        let meeting = Meeting(
            title: "Scheduled processing", startedAt: now.addingTimeInterval(-60),
            endedAt: now, lifecycleState: .captured)
        try await store.save(meeting)
        return (store, meeting)
    }

    private func enqueue(
        _ kind: ProcessingJobKind,
        in store: MeetingStore,
        meeting: Meeting,
        deadline: Date? = nil,
        maxAttempts: Int = 3
    ) async throws -> ProcessingJob {
        let jobs = try await store.enqueueProcessingJobs(
            for: meeting.id,
            requests: [.init(kind: kind, inputFingerprint: "\(kind.rawValue):scheduled",
                             maxAttempts: maxAttempts, notBefore: deadline)],
            at: now)
        return try #require(jobs.first)
    }

    private func claim(
        in store: MeetingStore,
        owner: String,
        leaseDuration: TimeInterval,
        at timestamp: Date
    ) async throws -> ProcessingJob {
        let claimed = try await store.claimNextProcessingJob(
            kinds: [.summary], owner: owner, leaseDuration: leaseDuration, at: timestamp)
        return try #require(claimed)
    }
}
