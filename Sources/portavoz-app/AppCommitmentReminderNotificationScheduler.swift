import ApplicationKit
import Foundation
import PortavozCore
import UserNotifications

enum AppReminderAuthorization: Sendable, Equatable {
    case notDetermined
    case denied
    case authorized
    case provisional
    case ephemeral
}

enum AppReminderNotificationError: Error, Sendable, Equatable {
    case authorizationNotDetermined
    case authorizationDenied
    case invalidSchedule
    case invalidDeliveredRequest
}

struct AppReminderNotificationRecord: Sendable, Equatable {
    let identifier: String
    let commitmentID: CommitmentID
    let scheduledFor: Date
    let sourceDueAt: Date
    let deliveredAt: Date?
}

struct AppReminderNotificationRequest: Sendable, Equatable {
    let record: AppReminderNotificationRecord
    let title: String
    let body: String
}

struct AppReminderNotificationSnapshot: Sendable, Equatable {
    let pending: AppReminderNotificationRecord?
    let delivered: AppReminderNotificationRecord?
}

enum AppReminderResponseAction: Sendable, Equatable {
    case openRadar
    case snooze
    case ignore
}

enum AppReminderNotificationMetadata {
    static let categoryIdentifier = "portavoz.commitment-reminder"
    static let snoozeActionIdentifier =
        "portavoz.commitment-reminder.snooze-15-minutes"
    static let snoozeInterval: TimeInterval = 15 * 60

    private enum Key {
        static let commitmentID = "portavoz.commitment-id"
        static let scheduledFor = "portavoz.scheduled-for"
        static let sourceDueAt = "portavoz.source-due-at"
    }

    static var category: UNNotificationCategory {
        let snoozeAction = UNNotificationAction(
            identifier: snoozeActionIdentifier,
            title: L10n.text("Remind me in 15 minutes"),
            options: [])
        return UNNotificationCategory(
            identifier: categoryIdentifier,
            actions: [snoozeAction],
            intentIdentifiers: [],
            options: [])
    }

    static func responseAction(
        for identifier: String
    ) -> AppReminderResponseAction {
        switch identifier {
        case UNNotificationDefaultActionIdentifier:
            .openRadar
        case snoozeActionIdentifier:
            .snooze
        default:
            .ignore
        }
    }

    static func userInfo(
        for record: AppReminderNotificationRecord
    ) -> [AnyHashable: Any] {
        [
            Key.commitmentID:
                record.commitmentID.rawValue.uuidString.lowercased(),
            Key.scheduledFor:
                record.scheduledFor.timeIntervalSinceReferenceDate,
            Key.sourceDueAt:
                record.sourceDueAt.timeIntervalSinceReferenceDate
        ]
    }

    static func record(
        identifier: String,
        userInfo: [AnyHashable: Any],
        deliveredAt: Date?
    ) -> AppReminderNotificationRecord? {
        guard let rawCommitmentID = userInfo[Key.commitmentID] as? String,
              let uuid = UUID(uuidString: rawCommitmentID),
              let scheduledFor = userInfo[Key.scheduledFor] as? Double,
              let sourceDueAt = userInfo[Key.sourceDueAt] as? Double
        else { return nil }
        let commitmentID = CommitmentID(rawValue: uuid)
        guard identifier == AppReminderNotificationScheduler.identifier(
            for: commitmentID)
        else { return nil }
        return AppReminderNotificationRecord(
            identifier: identifier,
            commitmentID: commitmentID,
            scheduledFor: Date(timeIntervalSinceReferenceDate: scheduledFor),
            sourceDueAt: Date(timeIntervalSinceReferenceDate: sourceDueAt),
            deliveredAt: deliveredAt)
    }
}

protocol AppReminderNotificationCenter: Sendable {
    func authorizationStatus() async -> AppReminderAuthorization
    func requestAuthorization() async throws -> Bool
    func snapshot(
        identifier: String
    ) async -> AppReminderNotificationSnapshot
    func add(_ request: AppReminderNotificationRequest) async throws
    func removePending(identifier: String) async
    func removeDelivered(identifier: String) async
}

/// macOS adapter for the content-free reminder-delivery port. It never asks
/// for permission while reconciling and never places commitment, person, or
/// meeting text in Notification Center.
actor AppReminderNotificationScheduler: CommitmentReminderDeliveryScheduling {
    private let center: any AppReminderNotificationCenter
    private let notificationContent: @Sendable () -> (title: String, body: String)

    init(
        center: any AppReminderNotificationCenter =
            SystemReminderNotificationCenter(),
        notificationContent: @escaping @Sendable () -> (
            title: String,
            body: String
        ) = {
            (
                L10n.text("Commitment reminder"),
                L10n.text("Open Portavoz to review a confirmed commitment."))
        }
    ) {
        self.center = center
        self.notificationContent = notificationContent
    }

    func authorizationStatus() async -> AppReminderAuthorization {
        await center.authorizationStatus()
    }

    /// Called only from an explicit future permission UI. Reconciliation uses
    /// `authorizationStatus` and fails closed instead of prompting.
    func requestAuthorization() async throws -> Bool {
        try await center.requestAuthorization()
    }

    func upsertCommitmentReminder(
        _ schedule: CommitmentReminderDeliverySchedule
    ) async throws -> CommitmentReminderDeliveryUpsertOutcome {
        try validate(schedule)
        switch await center.authorizationStatus() {
        case .authorized, .provisional, .ephemeral:
            break
        case .notDetermined:
            throw AppReminderNotificationError.authorizationNotDetermined
        case .denied:
            throw AppReminderNotificationError.authorizationDenied
        }

        let identifier = Self.identifier(for: schedule.commitmentID)
        let snapshot = await center.snapshot(identifier: identifier)
        if let delivered = snapshot.delivered,
           deliveredMatches(delivered, schedule: schedule, identifier: identifier) {
            guard let deliveredAt = delivered.deliveredAt,
                  delivered.scheduledFor.timeIntervalSinceReferenceDate.isFinite,
                  deliveredAt.timeIntervalSinceReferenceDate.isFinite,
                  delivered.scheduledFor <= deliveredAt
            else {
                throw AppReminderNotificationError.invalidDeliveredRequest
            }
            await center.removePending(identifier: identifier)
            return .alreadyPresented(
                scheduledFor: delivered.scheduledFor,
                deliveredAt: deliveredAt)
        }

        if snapshot.delivered != nil {
            await center.removeDelivered(identifier: identifier)
        }
        if let pending = snapshot.pending,
           pendingMatches(pending, schedule: schedule, identifier: identifier) {
            return .scheduled
        }

        let content = notificationContent()
        try await center.add(AppReminderNotificationRequest(
            record: AppReminderNotificationRecord(
                identifier: identifier,
                commitmentID: schedule.commitmentID,
                scheduledFor: schedule.scheduledFor,
                sourceDueAt: schedule.sourceDueAt,
                deliveredAt: nil),
            title: content.title,
            body: content.body))
        return .scheduled
    }

    func cancelCommitmentReminder(
        for commitmentID: CommitmentID
    ) async {
        let identifier = Self.identifier(for: commitmentID)
        await center.removePending(identifier: identifier)
        await center.removeDelivered(identifier: identifier)
    }

    static func identifier(for commitmentID: CommitmentID) -> String {
        "portavoz.commitment-reminder.\(commitmentID.rawValue.uuidString.lowercased())"
    }

    private func validate(
        _ schedule: CommitmentReminderDeliverySchedule
    ) throws {
        guard schedule.scheduledFor.timeIntervalSinceReferenceDate.isFinite,
              schedule.sourceDueAt.timeIntervalSinceReferenceDate.isFinite
        else {
            throw AppReminderNotificationError.invalidSchedule
        }
    }

    private func deliveredMatches(
        _ record: AppReminderNotificationRecord,
        schedule: CommitmentReminderDeliverySchedule,
        identifier: String
    ) -> Bool {
        record.identifier == identifier
            && record.commitmentID == schedule.commitmentID
            && record.scheduledFor == schedule.scheduledFor
            && record.sourceDueAt == schedule.sourceDueAt
    }

    private func pendingMatches(
        _ record: AppReminderNotificationRecord,
        schedule: CommitmentReminderDeliverySchedule,
        identifier: String
    ) -> Bool {
        record.identifier == identifier
            && record.commitmentID == schedule.commitmentID
            && record.scheduledFor == schedule.scheduledFor
            && record.sourceDueAt == schedule.sourceDueAt
            && record.deliveredAt == nil
    }
}

private actor SystemReminderNotificationCenter: AppReminderNotificationCenter {
    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    func authorizationStatus() async -> AppReminderAuthorization {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined:
            return .notDetermined
        case .denied:
            return .denied
        case .authorized:
            return .authorized
        case .provisional:
            return .provisional
        case .ephemeral:
            return .ephemeral
        @unknown default:
            return .denied
        }
    }

    func requestAuthorization() async throws -> Bool {
        try await center.requestAuthorization(options: [.alert, .sound])
    }

    func snapshot(
        identifier: String
    ) async -> AppReminderNotificationSnapshot {
        let pending = await center.pendingNotificationRequests()
            .first { $0.identifier == identifier }
            .flatMap { record(request: $0, deliveredAt: nil) }
        let delivered = await center.deliveredNotifications()
            .first { $0.request.identifier == identifier }
            .flatMap {
                record(
                    request: $0.request,
                    deliveredAt: $0.date)
            }
        return AppReminderNotificationSnapshot(
            pending: pending,
            delivered: delivered)
    }

    func add(
        _ request: AppReminderNotificationRequest
    ) async throws {
        let content = UNMutableNotificationContent()
        content.title = request.title
        content.body = request.body
        content.sound = .default
        content.categoryIdentifier =
            AppReminderNotificationMetadata.categoryIdentifier
        content.userInfo = AppReminderNotificationMetadata.userInfo(
            for: request.record)
        let delay = max(
            1,
            request.record.scheduledFor.timeIntervalSinceNow)
        let trigger = UNTimeIntervalNotificationTrigger(
            timeInterval: delay,
            repeats: false)
        try await center.add(UNNotificationRequest(
            identifier: request.record.identifier,
            content: content,
            trigger: trigger))
    }

    func removePending(identifier: String) {
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
    }

    func removeDelivered(identifier: String) {
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
    }

    private func record(
        request: UNNotificationRequest,
        deliveredAt: Date?
    ) -> AppReminderNotificationRecord? {
        AppReminderNotificationMetadata.record(
            identifier: request.identifier,
            userInfo: request.content.userInfo,
            deliveredAt: deliveredAt)
    }
}
