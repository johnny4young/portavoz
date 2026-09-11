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

/// Outcome from reconciling one stable local-delivery request. A platform
/// adapter must distinguish a pending request from one already delivered so a
/// relaunch never re-alerts the user under the same identifier.
public enum CommitmentReminderDeliveryUpsertOutcome: Sendable, Equatable {
    case scheduled
    case alreadyPresented(scheduledFor: Date, deliveredAt: Date)
}

/// Idempotent local-delivery boundary. `upsert` replaces the stable pending
/// request for a commitment or reports its exact delivered copy; `cancel`
/// succeeds when no pending or delivered request exists.
public protocol CommitmentReminderDeliveryScheduling: Sendable {
    func upsertCommitmentReminder(
        _ schedule: CommitmentReminderDeliverySchedule
    ) async throws -> CommitmentReminderDeliveryUpsertOutcome

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
    public let presentedCount: Int
    public let cancelledCount: Int
    public let unchangedCount: Int

    public init(
        scheduledCount: Int,
        replacedCount: Int,
        reassertedCount: Int,
        presentedCount: Int,
        cancelledCount: Int,
        unchangedCount: Int
    ) {
        self.scheduledCount = scheduledCount
        self.replacedCount = replacedCount
        self.reassertedCount = reassertedCount
        self.presentedCount = presentedCount
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
            try await reconcileMissingReminder(
                item,
                dueAt: dueAt,
                now: now,
                minimumDelay: minimumDelay,
                report: &report)
            return
        }

        switch reminder.status {
        case .scheduled:
            try await reconcileScheduledReminder(
                item,
                reminder: reminder,
                dueAt: dueAt,
                now: now,
                minimumDelay: minimumDelay,
                report: &report)
        case .presented:
            try await reconcilePresentedReminder(
                item,
                reminder: reminder,
                dueAt: dueAt,
                now: now,
                minimumDelay: minimumDelay,
                report: &report)
        case .dismissed, .cancelled:
            // Terminal user intent is never silently rearmed.
            report.unchangedCount += 1
        }
    }

    private func reconcileMissingReminder(
        _ item: CommitmentReminderReconciliationItem,
        dueAt: Date?,
        now: Date,
        minimumDelay: TimeInterval,
        report: inout MutableReminderReconciliationReport
    ) async throws {
        guard let dueAt else {
            report.unchangedCount += 1
            return
        }
        let outcome = try await schedule(
            commitmentID: item.id,
            dueAt: dueAt,
            persistenceNotBefore: item.commitment.createdAt,
            now: now,
            minimumDelay: minimumDelay)
        report.record(outcome)
    }

    private func reconcileScheduledReminder(
        _ item: CommitmentReminderReconciliationItem,
        reminder: CommitmentReminderState,
        dueAt: Date?,
        now: Date,
        minimumDelay: TimeInterval,
        report: inout MutableReminderReconciliationReport
    ) async throws {
        guard let scheduledFor = reminder.scheduledFor,
              let sourceDueAt = reminder.sourceDueAt
        else {
            throw ReconcileCommitmentRemindersError.invalidReminderState(item.id)
        }
        guard sourceDueAt != dueAt else {
            let outcome = try await scheduler.upsertCommitmentReminder(
                CommitmentReminderDeliverySchedule(
                    commitmentID: item.id,
                    scheduledFor: scheduledFor,
                    sourceDueAt: sourceDueAt))
            try await recordReassertion(
                outcome,
                item: item,
                reminder: reminder,
                now: now,
                report: &report)
            return
        }
        try await replaceOrCancel(
            item,
            reminder: reminder,
            dueAt: dueAt,
            now: now,
            minimumDelay: minimumDelay,
            report: &report)
    }

    private func reconcilePresentedReminder(
        _ item: CommitmentReminderReconciliationItem,
        reminder: CommitmentReminderState,
        dueAt: Date?,
        now: Date,
        minimumDelay: TimeInterval,
        report: inout MutableReminderReconciliationReport
    ) async throws {
        guard reminder.sourceDueAt != nil else {
            throw ReconcileCommitmentRemindersError.invalidReminderState(item.id)
        }
        guard reminder.sourceDueAt != dueAt else {
            report.unchangedCount += 1
            return
        }
        try await replaceOrCancel(
            item,
            reminder: reminder,
            dueAt: dueAt,
            now: now,
            minimumDelay: minimumDelay,
            report: &report)
    }

    private func recordReassertion(
        _ outcome: CommitmentReminderDeliveryUpsertOutcome,
        item: CommitmentReminderReconciliationItem,
        reminder: CommitmentReminderState,
        now: Date,
        report: inout MutableReminderReconciliationReport
    ) async throws {
        switch outcome {
        case .scheduled:
            report.reassertedCount += 1
        case .alreadyPresented(_, let deliveredAt):
            try await present(
                commitmentID: item.id,
                deliveredAt: deliveredAt,
                notBefore: max(now, reminder.updatedAt))
            report.presentedCount += 1
        }
    }

    private func replaceOrCancel(
        _ item: CommitmentReminderReconciliationItem,
        reminder: CommitmentReminderState,
        dueAt: Date?,
        now: Date,
        minimumDelay: TimeInterval,
        report: inout MutableReminderReconciliationReport
    ) async throws {
        guard let dueAt else {
            try await cancel(commitmentID: item.id, at: now)
            report.cancelledCount += 1
            return
        }
        let outcome = try await replace(
            commitmentID: item.id,
            dueAt: dueAt,
            persistenceNotBefore: reminder.updatedAt,
            now: now,
            minimumDelay: minimumDelay)
        report.replacedCount += 1
        if outcome.isAlreadyPresented {
            report.presentedCount += 1
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
        persistenceNotBefore: Date,
        now: Date,
        minimumDelay: TimeInterval
    ) async throws -> CommitmentReminderDeliveryUpsertOutcome {
        let intendedSchedule = try deliveryDate(
            dueAt: dueAt,
            now: now,
            minimumDelay: minimumDelay)
        let outcome = try await scheduler.upsertCommitmentReminder(
            CommitmentReminderDeliverySchedule(
                commitmentID: commitmentID,
                scheduledFor: intendedSchedule,
                sourceDueAt: dueAt))
        let persistence = try persistenceTiming(
            intendedSchedule: intendedSchedule,
            outcome: outcome,
            notBefore: persistenceNotBefore,
            now: now,
            commitmentID: commitmentID)
        do {
            let state = try await writer.applyCommitmentReminderTransition(
                .schedule(
                    scheduledFor: persistence.scheduledFor,
                    sourceDueAt: dueAt),
                to: commitmentID,
                eventID: CommitmentReminderEventID(),
                at: persistence.eventAt)
            try await presentIfNeeded(
                outcome,
                commitmentID: commitmentID,
                notBefore: max(now, state.updatedAt))
            return outcome
        } catch {
            if outcome == .scheduled {
                try? await scheduler.cancelCommitmentReminder(for: commitmentID)
            }
            throw error
        }
    }

    private func replace(
        commitmentID: CommitmentID,
        dueAt: Date,
        persistenceNotBefore: Date,
        now: Date,
        minimumDelay: TimeInterval
    ) async throws -> CommitmentReminderDeliveryUpsertOutcome {
        let intendedSchedule = try deliveryDate(
            dueAt: dueAt,
            now: now,
            minimumDelay: minimumDelay)
        let outcome = try await scheduler.upsertCommitmentReminder(
            CommitmentReminderDeliverySchedule(
                commitmentID: commitmentID,
                scheduledFor: intendedSchedule,
                sourceDueAt: dueAt))
        let persistence = try persistenceTiming(
            intendedSchedule: intendedSchedule,
            outcome: outcome,
            notBefore: persistenceNotBefore,
            now: now,
            commitmentID: commitmentID)
        let state = try await writer.replaceCommitmentReminderSchedule(
            scheduledFor: persistence.scheduledFor,
            sourceDueAt: dueAt,
            commitmentID: commitmentID,
            cancellationEventID: CommitmentReminderEventID(),
            scheduleEventID: CommitmentReminderEventID(),
            at: persistence.eventAt)
        try await presentIfNeeded(
            outcome,
            commitmentID: commitmentID,
            notBefore: max(now, state.updatedAt))
        return outcome
    }

    private func persistenceTiming(
        intendedSchedule: Date,
        outcome: CommitmentReminderDeliveryUpsertOutcome,
        notBefore: Date,
        now: Date,
        commitmentID: CommitmentID
    ) throws -> (scheduledFor: Date, eventAt: Date) {
        guard case .alreadyPresented(let scheduledFor, let deliveredAt) = outcome else {
            return (intendedSchedule, now)
        }
        guard scheduledFor.timeIntervalSinceReferenceDate.isFinite,
              deliveredAt.timeIntervalSinceReferenceDate.isFinite,
              notBefore.timeIntervalSinceReferenceDate.isFinite,
              deliveredAt <= now,
              scheduledFor <= deliveredAt
        else {
            throw ReconcileCommitmentRemindersError.invalidReminderState(commitmentID)
        }
        let eventAt = max(
            notBefore,
            scheduledFor.addingTimeInterval(-0.001))
        guard scheduledFor > eventAt else {
            throw ReconcileCommitmentRemindersError.invalidReminderState(commitmentID)
        }
        return (scheduledFor, eventAt)
    }

    private func presentIfNeeded(
        _ outcome: CommitmentReminderDeliveryUpsertOutcome,
        commitmentID: CommitmentID,
        notBefore: Date
    ) async throws {
        guard case .alreadyPresented(_, let deliveredAt) = outcome else { return }
        try await present(
            commitmentID: commitmentID,
            deliveredAt: deliveredAt,
            notBefore: notBefore)
    }

    private func present(
        commitmentID: CommitmentID,
        deliveredAt: Date,
        notBefore: Date
    ) async throws {
        guard deliveredAt.timeIntervalSinceReferenceDate.isFinite else {
            throw ReconcileCommitmentRemindersError.invalidReminderState(commitmentID)
        }
        _ = try await writer.applyCommitmentReminderTransition(
            .present,
            to: commitmentID,
            eventID: CommitmentReminderEventID(),
            at: max(deliveredAt, notBefore))
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
    var presentedCount = 0
    var cancelledCount = 0
    var unchangedCount = 0

    mutating func record(
        _ outcome: CommitmentReminderDeliveryUpsertOutcome
    ) {
        switch outcome {
        case .scheduled:
            scheduledCount += 1
        case .alreadyPresented:
            presentedCount += 1
        }
    }

    var value: ReconcileCommitmentRemindersReport {
        ReconcileCommitmentRemindersReport(
            scheduledCount: scheduledCount,
            replacedCount: replacedCount,
            reassertedCount: reassertedCount,
            presentedCount: presentedCount,
            cancelledCount: cancelledCount,
            unchangedCount: unchangedCount)
    }
}

private extension CommitmentReminderDeliveryUpsertOutcome {
    var isAlreadyPresented: Bool {
        if case .alreadyPresented = self { return true }
        return false
    }
}
