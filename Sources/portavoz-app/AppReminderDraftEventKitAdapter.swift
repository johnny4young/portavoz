import ApplicationKit
@preconcurrency import EventKit
import Foundation
import PortavozCore

enum AppReminderDraftError: Error, Equatable, CategorizedFailure {
    case authorizationDenied
    case targetUnavailable
    case staleTarget
    case saveFailed

    var category: FailureCategory {
        switch self {
        case .authorizationDenied, .targetUnavailable, .staleTarget:
            .recoverable
        case .saveFailed:
            .external
        }
    }
}

protocol AppReminderDraftPlatform: Sendable {
    func authorizationStatus() async -> AppReminderDraftAuthorization
    func requestFullAccess() async throws -> AppReminderDraftAuthorization
    func defaultTarget() async -> AppReminderDraftTarget?
    func target(identifier: String) async -> AppReminderDraftTarget?
    func deliver(
        _ draft: ReminderDraft,
        to target: AppReminderDraftTarget
    ) async throws
}

protocol AppReminderDraftEventStore: Sendable {
    func authorizationStatus() async -> AppReminderDraftAuthorization
    func requestFullAccess() async throws -> AppReminderDraftAuthorization
    func defaultTarget() async -> AppReminderDraftTarget?
    func target(identifier: String) async -> AppReminderDraftTarget?
    func save(
        _ draft: ReminderDraft,
        to target: AppReminderDraftTarget
    ) async throws
}

/// Validates permission and the exact previewed list immediately before the
/// system store saves. It never chooses a fallback destination.
actor AppReminderDraftEventKitAdapter: AppReminderDraftPlatform {
    private let store: any AppReminderDraftEventStore

    init(
        store: any AppReminderDraftEventStore = SystemReminderDraftEventStore()
    ) {
        self.store = store
    }

    func authorizationStatus() async -> AppReminderDraftAuthorization {
        await store.authorizationStatus()
    }

    func requestFullAccess() async throws -> AppReminderDraftAuthorization {
        try await store.requestFullAccess()
    }

    func defaultTarget() async -> AppReminderDraftTarget? {
        guard await store.authorizationStatus() == .fullAccess else { return nil }
        return await store.defaultTarget()
    }

    func target(identifier: String) async -> AppReminderDraftTarget? {
        guard await store.authorizationStatus() == .fullAccess else { return nil }
        return await store.target(identifier: identifier)
    }

    func deliver(
        _ draft: ReminderDraft,
        to target: AppReminderDraftTarget
    ) async throws {
        guard await store.authorizationStatus() == .fullAccess else {
            throw AppReminderDraftError.authorizationDenied
        }
        guard let current = await store.target(identifier: target.identifier)
        else { throw AppReminderDraftError.targetUnavailable }
        guard current == target else {
            throw AppReminderDraftError.staleTarget
        }
        do {
            try await store.save(draft, to: target)
        } catch let error as AppReminderDraftError {
            throw error
        } catch {
            throw AppReminderDraftError.saveFailed
        }
    }
}

/// The actor owns one EKEventStore for target resolution and save. EventKit
/// requires the reminder and its calendar to belong to that same store.
private actor SystemReminderDraftEventStore: AppReminderDraftEventStore {
    private let eventStore = EKEventStore()

    func authorizationStatus() -> AppReminderDraftAuthorization {
        let status = EKEventStore.authorizationStatus(for: .reminder)
        if status == .fullAccess { return .fullAccess }
        if status == .notDetermined { return .notDetermined }
        return .denied
    }

    func requestFullAccess() async throws -> AppReminderDraftAuthorization {
        _ = try await eventStore.requestFullAccessToReminders()
        return authorizationStatus()
    }

    func defaultTarget() -> AppReminderDraftTarget? {
        guard authorizationStatus() == .fullAccess,
              let calendar = eventStore.defaultCalendarForNewReminders(),
              calendar.allowedEntityTypes.contains(.reminder)
        else { return nil }
        return AppReminderDraftTarget(
            identifier: calendar.calendarIdentifier,
            title: calendar.title)
    }

    func target(identifier: String) -> AppReminderDraftTarget? {
        guard authorizationStatus() == .fullAccess,
              let calendar = eventStore.calendar(withIdentifier: identifier),
              calendar.allowedEntityTypes.contains(.reminder)
        else { return nil }
        return AppReminderDraftTarget(
            identifier: calendar.calendarIdentifier,
            title: calendar.title)
    }

    func save(
        _ draft: ReminderDraft,
        to target: AppReminderDraftTarget
    ) throws {
        guard authorizationStatus() == .fullAccess else {
            throw AppReminderDraftError.authorizationDenied
        }
        guard let calendar = eventStore.calendar(
            withIdentifier: target.identifier),
              calendar.allowedEntityTypes.contains(.reminder)
        else { throw AppReminderDraftError.targetUnavailable }
        guard calendar.calendarIdentifier == target.identifier,
              calendar.title == target.title
        else { throw AppReminderDraftError.staleTarget }

        let reminder = EKReminder(eventStore: eventStore)
        reminder.title = draft.title
        reminder.calendar = calendar
        if let dueAt = draft.dueAt {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = .current
            reminder.dueDateComponents = calendar.dateComponents(
                [.calendar, .timeZone, .year, .month, .day, .hour, .minute],
                from: dueAt)
        }
        try eventStore.save(reminder, commit: true)
    }
}
