import ApplicationKit
import Foundation
import PortavozCore
import StorageKit

extension AppServices {
    static func makeCommitmentReminderModel(
        store: MeetingStore,
        usesTemporaryStore: Bool
    ) -> CommitmentReminderModel {
        let scheduler: AppReminderNotificationScheduler
        if usesTemporaryStore {
            scheduler = AppReminderNotificationScheduler(
                center: UITestReminderNotificationCenter())
        } else {
            scheduler = AppReminderNotificationScheduler()
        }
        return CommitmentReminderModel(
            client: AppCommitmentReminderClient(
                store: store,
                scheduler: scheduler))
    }

    func confirmMeetingDetailCommitment(
        _ request: ConfirmMeetingCommitmentRequest
    ) async throws -> Commitment {
        let commitment = try await makeCommitmentInboxManager().confirm(request)
        commitmentReminders.kick()
        return commitment
    }

    func makeCommitmentInboxManager() -> ManageMeetingCommitmentInbox {
        ManageMeetingCommitmentInbox(
            repository: AppMeetingCommitmentReviewRepository(store: store))
    }
}

private struct AppCommitmentReminderClient: CommitmentReminderModelClient {
    let store: MeetingStore
    let scheduler: AppReminderNotificationScheduler

    func commitmentReminderPermission() async -> CommitmentReminderPermission {
        switch await scheduler.authorizationStatus() {
        case .notDetermined:
            .notDetermined
        case .denied:
            .denied
        case .authorized, .provisional, .ephemeral:
            .enabled
        }
    }

    func requestCommitmentReminderPermission() async throws
        -> CommitmentReminderPermission {
        guard try await scheduler.requestAuthorization() else {
            return .denied
        }
        return await commitmentReminderPermission()
    }

    func reconcileCommitmentReminders() async throws
        -> ReconcileCommitmentRemindersReport {
        try await ReconcileCommitmentReminders(
            reader: store,
            writer: store,
            scheduler: scheduler
        ).execute(ReconcileCommitmentRemindersRequest())
    }

    func recordCommitmentReminderPresentation(
        _ request: ReminderPresentationRequest
    ) async throws -> ReminderPresentationOutcome {
        try await RecordCommitmentReminderPresentation(
            repository: store
        ).execute(request)
    }

    func snoozeCommitmentReminder(
        _ request: ReminderSnoozeRequest
    ) async throws -> ReminderSnoozeOutcome {
        try await SnoozeCommitmentReminder(
            repository: store
        ).execute(request)
    }
}

private struct AppMeetingCommitmentReviewRepository: MeetingCommitmentReviewRepository {
    let store: MeetingStore

    func confirmCommitment(
        _ confirmation: CommitmentConfirmation,
        at date: Date
    ) async throws -> CommitmentContinuityEnvelope {
        try await store.confirmCommitment(confirmation, at: date)
    }

    func linkCommitmentSource(
        _ confirmation: CommitmentLinkConfirmation,
        at date: Date
    ) async throws -> CommitmentContinuityEnvelope {
        try await store.linkCommitmentSource(confirmation, at: date)
    }

    func setCommitmentReviewDecision(
        _ disposition: CommitmentReviewDisposition?,
        for actionItemID: UUID,
        meetingID: MeetingID,
        revisitAt: Date?,
        at date: Date
    ) async throws {
        try await store.setCommitmentReviewDecision(
            disposition,
            for: actionItemID,
            meetingID: meetingID,
            revisitAt: revisitAt,
            at: date)
    }
}

/// System authorization is never touched by disposable XCUITest stores. This
/// in-memory center starts undetermined and grants only after the same explicit
/// model action used by production.
private actor UITestReminderNotificationCenter: AppReminderNotificationCenter {
    private var authorization = AppReminderAuthorization.notDetermined
    private var pending: [String: AppReminderNotificationRecord] = [:]

    func authorizationStatus() -> AppReminderAuthorization {
        authorization
    }

    func requestAuthorization() -> Bool {
        authorization = .authorized
        return true
    }

    func snapshot(identifier: String) -> AppReminderNotificationSnapshot {
        AppReminderNotificationSnapshot(
            pending: pending[identifier],
            delivered: nil)
    }

    func add(_ request: AppReminderNotificationRequest) {
        pending[request.record.identifier] = request.record
    }

    func removePending(identifier: String) {
        pending[identifier] = nil
    }

    func removeDelivered(identifier _: String) {}
}
