import ApplicationKit
import Foundation
import GRDB
import PortavozCore
import StorageKit
import Testing

struct ProcessingWakeScheduleTests {
    private var now: Date { Date(timeIntervalSince1970: 1_783_699_200) }

    @Test
    func successfulDrainPreservesImmediateDeadline() {
        let wake = ProcessingWakeSchedule.nextDate(
            scheduled: now, afterDrainFailure: false, at: now)

        #expect(wake == now)
    }

    @Test
    func successfulDrainPreservesFutureDeadline() {
        let deadline = now.addingTimeInterval(30)
        let wake = ProcessingWakeSchedule.nextDate(
            scheduled: deadline, afterDrainFailure: false, at: now)

        #expect(wake == deadline)
    }

    @Test
    func failedDrainDelaysOverdueAndImmediateDeadlines() {
        let overdueWake = ProcessingWakeSchedule.nextDate(
            scheduled: now.addingTimeInterval(-30), afterDrainFailure: true, at: now)
        let immediateWake = ProcessingWakeSchedule.nextDate(
            scheduled: now, afterDrainFailure: true, at: now)

        #expect(overdueWake == now.addingTimeInterval(5))
        #expect(immediateWake == now.addingTimeInterval(5))
    }

    @Test
    func failedDrainDelaysSoonFutureDeadline() {
        let wake = ProcessingWakeSchedule.nextDate(
            scheduled: now.addingTimeInterval(2), afterDrainFailure: true, at: now)

        #expect(wake == now.addingTimeInterval(5))
    }

    @Test
    func failedDrainRetriesBeforeLaterFutureDeadline() {
        let wake = ProcessingWakeSchedule.nextDate(
            scheduled: now.addingTimeInterval(3_600), afterDrainFailure: true, at: now)

        #expect(wake == now.addingTimeInterval(5))
    }

    @Test
    func failedDrainWithoutDurableDeadlineRetriesAfterBackoff() {
        let wake = ProcessingWakeSchedule.nextDate(
            scheduled: nil, afterDrainFailure: true, at: now)

        #expect(wake == now.addingTimeInterval(5))
    }

    @Test
    func successfulDrainWithoutDurableDeadlineDoesNotCreateTimer() {
        let wake = ProcessingWakeSchedule.nextDate(
            scheduled: nil, afterDrainFailure: false, at: now)

        #expect(wake == nil)
    }

    @Test
    func busyClaimKeepsReadableDeadlineAndUsesFailureBackoff() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("library.sqlite")
        let store = try MeetingStore(databaseURL: databaseURL)
        let meeting = Meeting(title: "Scheduled work", startedAt: now, lifecycleState: .captured)
        try await store.save(meeting)
        let jobs = try await store.enqueueProcessingJobs(
            for: meeting.id,
            requests: [.init(kind: .summary, inputFingerprint: "summary:scheduled",
                             notBefore: now.addingTimeInterval(-1))],
            at: now)
        let job = try #require(jobs.first)
        let reader = try await heldReader(databaseURL: databaseURL)
        var readerHasTransaction = true
        defer {
            if readerHasTransaction {
                try? reader.unsafeRead { try $0.execute(sql: "ROLLBACK") }
            }
        }

        var failure: DatabaseError?
        do {
            _ = try await store.claimNextProcessingJob(
                kinds: [.summary], owner: "worker", leaseDuration: 30, at: now)
            Issue.record("The external read transaction must prevent the claim write from committing")
        } catch let error as DatabaseError {
            failure = error
        }
        let databaseError = try #require(failure)
        #expect(databaseError.resultCode == .SQLITE_BUSY || databaseError.extendedResultCode == .SQLITE_IOERR_LOCK)

        let deadline = try await store.nextScheduledProcessingDate(kinds: [.summary], after: now)
        #expect(deadline == now)
        let wake = ProcessingWakeSchedule.nextDate(scheduled: deadline, afterDrainFailure: true, at: now)
        #expect(wake == now.addingTimeInterval(5))
        let retained = try await store.processingJobs(for: meeting.id)
        #expect(retained == [job])

        try await reader.unsafeRead { try $0.execute(sql: "ROLLBACK") }
        readerHasTransaction = false
        let retry = try await store.claimNextProcessingJob(
            kinds: [.summary], owner: "worker", leaseDuration: 30, at: now.addingTimeInterval(5))
        let claimed = try #require(retry)
        #expect(claimed.id == job.id)
        #expect(claimed.attempt == 1)
        #expect(claimed.leaseOwner == "worker")
    }

    private func heldReader(databaseURL: URL) async throws -> DatabaseQueue {
        var configuration = Configuration()
        configuration.readonly = true
        configuration.allowsUnsafeTransactions = true
        let reader = try DatabaseQueue(path: databaseURL.path, configuration: configuration)
        try await reader.unsafeRead { database in
            try database.execute(sql: "BEGIN")
            _ = try Int.fetchOne(database, sql: "SELECT count(*) FROM processingJob")
        }
        return reader
    }
}
