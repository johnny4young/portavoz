import ApplicationKit
import Foundation
import Observation

enum CommitmentReminderPermission: Sendable, Equatable {
    case unknown
    case notDetermined
    case denied
    case enabled
}

@MainActor
protocol CommitmentReminderModelClient: Sendable {
    func commitmentReminderPermission() async -> CommitmentReminderPermission
    func requestCommitmentReminderPermission() async throws
        -> CommitmentReminderPermission
    func reconcileCommitmentReminders() async throws
        -> ReconcileCommitmentRemindersReport
    func recordCommitmentReminderPresentation(
        _ request: ReminderPresentationRequest
    ) async throws -> ReminderPresentationOutcome
    func snoozeCommitmentReminder(
        _ request: ReminderSnoozeRequest
    ) async throws -> ReminderSnoozeOutcome
    func dismissCommitmentReminder(
        _ request: ReminderDismissalRequest
    ) async throws -> ReminderDismissalOutcome
}

/// Process-owned reminder permission and reconciliation state. Launch and
/// durable mutations may request a reconciliation, but only an explicit user
/// action may request notification authorization.
@MainActor
@Observable
final class CommitmentReminderModel {
    enum Phase: Equatable {
        case idle
        case checkingPermission
        case requestingPermission
        case reconciling
        case failed
    }

    struct State: Equatable {
        fileprivate(set) var permission = CommitmentReminderPermission.unknown
        fileprivate(set) var phase = Phase.idle
    }

    enum Action {
        case start
        case enable
        case retry
        /// The user may have flipped notification permission in System
        /// Settings while the app was in the background; returning is the
        /// moment to notice — in both directions — without prompting.
        case applicationDidBecomeActive
    }

    private(set) var state = State()

    private let client: any CommitmentReminderModelClient
    private var reconciliationTask: Task<Void, Never>?
    private var rerunRequested = false
    private var started = false

    init(client: any CommitmentReminderModelClient) {
        self.client = client
    }

    func send(_ action: Action) async {
        switch action {
        case .start:
            guard !started else { return }
            started = true
            await refreshPermission()
        case .enable:
            await requestPermission()
        case .retry:
            await refreshPermission()
        case .applicationDidBecomeActive:
            // Never stomp an in-flight request or reconciliation pass; a
            // failed pass recovers here too, so returning to the app is
            // enough to heal both permission flips and transient failures.
            guard started, state.phase == .idle || state.phase == .failed
            else { return }
            await refreshPermission()
        }
    }

    /// Coalesces mutation bursts into at most one active pass and one rerun.
    /// No timer polls StorageKit while the app is idle.
    func kick() {
        guard state.permission == .enabled else { return }
        guard reconciliationTask == nil else {
            rerunRequested = true
            return
        }

        state.phase = .reconciling
        let client = client
        reconciliationTask = Task { @MainActor [weak self] in
            do {
                _ = try await client.reconcileCommitmentReminders()
                self?.finishedReconciliation(error: nil)
            } catch is CancellationError {
                self?.finishedReconciliation(error: nil)
            } catch {
                self?.finishedReconciliation(error: error)
            }
        }
    }

    func recordPresentation(
        _ record: AppReminderNotificationRecord
    ) async {
        guard let deliveredAt = record.deliveredAt else { return }
        do {
            _ = try await client.recordCommitmentReminderPresentation(
                ReminderPresentationRequest(
                    commitmentID: record.commitmentID,
                    scheduledFor: record.scheduledFor,
                    sourceDueAt: record.sourceDueAt,
                    deliveredAt: deliveredAt))
        } catch is CancellationError {
            return
        } catch {
            state.phase = .failed
        }
    }

    func snooze(
        _ record: AppReminderNotificationRecord,
        handledAt: Date,
        until snoozeUntil: Date
    ) async {
        guard let deliveredAt = record.deliveredAt else { return }
        do {
            let outcome = try await client.snoozeCommitmentReminder(
                ReminderSnoozeRequest(
                    commitmentID: record.commitmentID,
                    scheduledFor: record.scheduledFor,
                    sourceDueAt: record.sourceDueAt,
                    deliveredAt: deliveredAt,
                    handledAt: handledAt,
                    snoozeUntil: snoozeUntil))
            guard case .snoozed = outcome else { return }
            if state.permission == .unknown {
                await refreshPermission()
            } else {
                kick()
            }
        } catch is CancellationError {
            return
        } catch {
            state.phase = .failed
        }
    }

    func dismiss(
        _ record: AppReminderNotificationRecord,
        handledAt: Date
    ) async {
        guard let deliveredAt = record.deliveredAt else { return }
        do {
            _ = try await client.dismissCommitmentReminder(
                ReminderDismissalRequest(
                    commitmentID: record.commitmentID,
                    scheduledFor: record.scheduledFor,
                    sourceDueAt: record.sourceDueAt,
                    deliveredAt: deliveredAt,
                    handledAt: handledAt))
        } catch is CancellationError {
            return
        } catch {
            state.phase = .failed
        }
    }
}

private extension CommitmentReminderModel {
    func refreshPermission() async {
        state.phase = .checkingPermission
        let permission = await client.commitmentReminderPermission()
        guard !Task.isCancelled else { return }
        state.permission = permission
        state.phase = .idle
        if permission == .enabled {
            kick()
        }
    }

    func requestPermission() async {
        guard state.phase != .requestingPermission else { return }
        state.phase = .requestingPermission
        do {
            let permission = try await client.requestCommitmentReminderPermission()
            guard !Task.isCancelled else { return }
            state.permission = permission
            state.phase = .idle
            if permission == .enabled {
                kick()
            }
        } catch is CancellationError {
            state.phase = .idle
        } catch {
            state.phase = .failed
        }
    }

    func finishedReconciliation(error: (any Error)?) {
        reconciliationTask = nil
        guard error == nil else {
            rerunRequested = false
            state.phase = .failed
            return
        }
        if rerunRequested {
            rerunRequested = false
            kick()
        } else {
            state.phase = .idle
        }
    }
}
