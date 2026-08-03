import Foundation
import PortavozCore
import StorageKit

public protocol CommitmentReminderReconciliationReading: Sendable {
    func commitmentReminderReconciliationPage(
        _ query: CommitmentReminderReconciliationQuery
    ) async throws -> CommitmentReminderReconciliationPage
}

public protocol CommitmentReminderTransitionWriting: Sendable {
    func applyCommitmentReminderTransition(
        _ transition: CommitmentReminderTransition,
        to commitmentID: CommitmentID,
        eventID: CommitmentReminderEventID,
        at proposedDate: Date
    ) async throws -> CommitmentReminderState

    func replaceCommitmentReminderSchedule(
        scheduledFor: Date,
        sourceDueAt: Date,
        commitmentID: CommitmentID,
        cancellationEventID: CommitmentReminderEventID,
        scheduleEventID: CommitmentReminderEventID,
        at proposedDate: Date
    ) async throws -> CommitmentReminderState
}

extension MeetingStore: CommitmentReminderReconciliationReading {}
extension MeetingStore: CommitmentReminderTransitionWriting {}

/// Content-free scheduler input. The macOS adapter can use the stable
/// commitment identity to replace a pending request without exposing the
/// commitment title on the lock screen or across the application boundary.
public struct CommitmentReminderDeliverySchedule: Sendable, Equatable {
    public let commitmentID: CommitmentID
    public let scheduledFor: Date
    public let sourceDueAt: Date

    public init(
        commitmentID: CommitmentID,
        scheduledFor: Date,
        sourceDueAt: Date
    ) {
        self.commitmentID = commitmentID
        self.scheduledFor = scheduledFor
        self.sourceDueAt = sourceDueAt
    }
}

/// Idempotent local-delivery boundary. `upsert` replaces the stable request for
/// a commitment; `cancel` succeeds when no request exists.
public protocol CommitmentReminderDeliveryScheduling: Sendable {
    func upsertCommitmentReminder(
        _ schedule: CommitmentReminderDeliverySchedule
    ) async throws

    func cancelCommitmentReminder(
        for commitmentID: CommitmentID
    ) async throws
}

public struct ReconcileCommitmentRemindersRequest: Sendable, Equatable {
    public let itemLimit: Int
    public let minimumSchedulingDelay: TimeInterval

    public init(
        itemLimit: Int = 256,
        minimumSchedulingDelay: TimeInterval = 1
    ) {
        self.itemLimit = itemLimit
        self.minimumSchedulingDelay = minimumSchedulingDelay
    }
}

public struct ReconcileCommitmentRemindersReport: Sendable, Equatable {
    public let scheduledCount: Int
    public let replacedCount: Int
    public let reassertedCount: Int
    public let cancelledCount: Int
    public let unchangedCount: Int

    public init(
        scheduledCount: Int,
        replacedCount: Int,
        reassertedCount: Int,
        cancelledCount: Int,
        unchangedCount: Int
    ) {
        self.scheduledCount = scheduledCount
        self.replacedCount = replacedCount
        self.reassertedCount = reassertedCount
        self.cancelledCount = cancelledCount
        self.unchangedCount = unchangedCount
    }
}

public enum ReconcileCommitmentRemindersError: Error, Sendable, Equatable {
    case invalidClock
    case invalidMinimumSchedulingDelay
    case incompleteSnapshot(expected: Int, actual: Int)
    case duplicateCommitment(CommitmentID)
    case invalidReminderState(CommitmentID)
}

/// Converges durable reminder intent with one idempotent local scheduler.
/// Scheduler mutation happens first; persistence then records the matching
/// intent. Retrying after either side fails is safe because every delivery has
/// one stable commitment identity and stale replacements are atomic in storage.
public struct ReconcileCommitmentReminders: ApplicationUseCase {
    private let reader: any CommitmentReminderReconciliationReading
    private let writer: any CommitmentReminderTransitionWriting
    private let scheduler: any CommitmentReminderDeliveryScheduling
    private let now: @Sendable () -> Date

    public init(
        reader: any CommitmentReminderReconciliationReading,
        writer: any CommitmentReminderTransitionWriting,
        scheduler: any CommitmentReminderDeliveryScheduling,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.reader = reader
        self.writer = writer
        self.scheduler = scheduler
        self.now = now
    }

    public func execute(
        _ request: ReconcileCommitmentRemindersRequest
    ) async throws -> ReconcileCommitmentRemindersReport {
        guard request.minimumSchedulingDelay.isFinite,
              request.minimumSchedulingDelay > 0
        else {
            throw ReconcileCommitmentRemindersError.invalidMinimumSchedulingDelay
        }
        let timestamp = now()
        guard timestamp.timeIntervalSinceReferenceDate.isFinite else {
            throw ReconcileCommitmentRemindersError.invalidClock
        }
        let page = try await reader.commitmentReminderReconciliationPage(
            CommitmentReminderReconciliationQuery(itemLimit: request.itemLimit))
        guard page.totalCount == page.items.count else {
            throw ReconcileCommitmentRemindersError.incompleteSnapshot(
                expected: page.totalCount,
                actual: page.items.count)
        }
        guard Set(page.items.map(\.id)).count == page.items.count else {
            let duplicates = Dictionary(grouping: page.items, by: \.id)
                .first { $0.value.count > 1 }
            throw ReconcileCommitmentRemindersError.duplicateCommitment(
                duplicates?.key ?? page.items[0].id)
        }

        var report = MutableReminderReconciliationReport()
        for item in page.items {
            try await reconcile(
                item,
                now: timestamp,
                minimumDelay: request.minimumSchedulingDelay,
                report: &report)
        }
        return report.value
    }

    private func reconcile(
        _ item: CommitmentReminderReconciliationItem,
        now: Date,
        minimumDelay: TimeInterval,
        report: inout MutableReminderReconciliationReport
    ) async throws {
        let dueAt = try eligibleDueDate(item.commitment)
        guard let reminder = item.reminder else {
            guard let dueAt else {
                report.unchangedCount += 1
                return
            }
            try await schedule(
                commitmentID: item.id,
                dueAt: dueAt,
                now: now,
                minimumDelay: minimumDelay)
            report.scheduledCount += 1
            return
        }

        switch reminder.status {
        case .scheduled:
            guard let scheduledFor = reminder.scheduledFor,
                  let sourceDueAt = reminder.sourceDueAt
            else {
                throw ReconcileCommitmentRemindersError.invalidReminderState(item.id)
            }
            if sourceDueAt == dueAt {
                try await scheduler.upsertCommitmentReminder(
                    CommitmentReminderDeliverySchedule(
                        commitmentID: item.id,
                        scheduledFor: scheduledFor,
                        sourceDueAt: sourceDueAt))
                report.reassertedCount += 1
            } else if let dueAt {
                try await replace(
                    commitmentID: item.id,
                    dueAt: dueAt,
                    now: now,
                    minimumDelay: minimumDelay)
                report.replacedCount += 1
            } else {
                try await cancel(commitmentID: item.id, at: now)
                report.cancelledCount += 1
            }
        case .presented:
            guard reminder.sourceDueAt != nil else {
                throw ReconcileCommitmentRemindersError.invalidReminderState(item.id)
            }
            if reminder.sourceDueAt == dueAt {
                report.unchangedCount += 1
            } else if let dueAt {
                try await replace(
                    commitmentID: item.id,
                    dueAt: dueAt,
                    now: now,
                    minimumDelay: minimumDelay)
                report.replacedCount += 1
            } else {
                try await cancel(commitmentID: item.id, at: now)
                report.cancelledCount += 1
            }
        case .dismissed, .cancelled:
            // Terminal user intent is never silently rearmed.
            report.unchangedCount += 1
        }
    }

    private func eligibleDueDate(_ commitment: Commitment) throws -> Date? {
        guard commitment.deletedAt == nil,
              commitment.status == .confirmed,
              let dueAt = commitment.dueAt
        else { return nil }
        guard dueAt.timeIntervalSinceReferenceDate.isFinite else {
            throw ReconcileCommitmentRemindersError.invalidReminderState(commitment.id)
        }
        return dueAt
    }

    private func deliveryDate(
        dueAt: Date,
        now: Date,
        minimumDelay: TimeInterval
    ) throws -> Date {
        let earliest = now.addingTimeInterval(minimumDelay)
        guard earliest.timeIntervalSinceReferenceDate.isFinite else {
            throw ReconcileCommitmentRemindersError.invalidClock
        }
        return max(dueAt, earliest)
    }

    private func schedule(
        commitmentID: CommitmentID,
        dueAt: Date,
        now: Date,
        minimumDelay: TimeInterval
    ) async throws {
        let scheduledFor = try deliveryDate(
            dueAt: dueAt,
            now: now,
            minimumDelay: minimumDelay)
        try await scheduler.upsertCommitmentReminder(
            CommitmentReminderDeliverySchedule(
                commitmentID: commitmentID,
                scheduledFor: scheduledFor,
                sourceDueAt: dueAt))
        do {
            _ = try await writer.applyCommitmentReminderTransition(
                .schedule(scheduledFor: scheduledFor, sourceDueAt: dueAt),
                to: commitmentID,
                eventID: CommitmentReminderEventID(),
                at: now)
        } catch {
            try? await scheduler.cancelCommitmentReminder(for: commitmentID)
            throw error
        }
    }

    private func replace(
        commitmentID: CommitmentID,
        dueAt: Date,
        now: Date,
        minimumDelay: TimeInterval
    ) async throws {
        let scheduledFor = try deliveryDate(
            dueAt: dueAt,
            now: now,
            minimumDelay: minimumDelay)
        try await scheduler.upsertCommitmentReminder(
            CommitmentReminderDeliverySchedule(
                commitmentID: commitmentID,
                scheduledFor: scheduledFor,
                sourceDueAt: dueAt))
        _ = try await writer.replaceCommitmentReminderSchedule(
            scheduledFor: scheduledFor,
            sourceDueAt: dueAt,
            commitmentID: commitmentID,
            cancellationEventID: CommitmentReminderEventID(),
            scheduleEventID: CommitmentReminderEventID(),
            at: now)
    }

    private func cancel(
        commitmentID: CommitmentID,
        at timestamp: Date
    ) async throws {
        try await scheduler.cancelCommitmentReminder(for: commitmentID)
        _ = try await writer.applyCommitmentReminderTransition(
            .cancel,
            to: commitmentID,
            eventID: CommitmentReminderEventID(),
            at: timestamp)
    }
}

private struct MutableReminderReconciliationReport {
    var scheduledCount = 0
    var replacedCount = 0
    var reassertedCount = 0
    var cancelledCount = 0
    var unchangedCount = 0

    var value: ReconcileCommitmentRemindersReport {
        ReconcileCommitmentRemindersReport(
            scheduledCount: scheduledCount,
            replacedCount: replacedCount,
            reassertedCount: reassertedCount,
            cancelledCount: cancelledCount,
            unchangedCount: unchangedCount)
    }
}
