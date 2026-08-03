import AppKit
import CoreSpotlight
import PortavozCore
import UserNotifications

/// AppKit delegate for the plumbing SwiftUI does not deliver reliably on
/// macOS: a Spotlight hit's user activity arrives HERE (field bug: the
/// view-level `onContinueUserActivity` never fired — the system only
/// activated the app). Navigation goes through `AppServices.pendingRoute`,
/// the same channel the pre-meeting banner uses from outside the window
/// hierarchy.
final class PortavozAppDelegate:
    NSObject,
    NSApplicationDelegate,
    UNUserNotificationCenterDelegate {
    /// Wired by `PortavozApp.init` — the delegate is instantiated by the
    /// adaptor before any scene exists.
    @MainActor static weak var services: AppServices?

    func applicationWillFinishLaunching(_ notification: Notification) {
        _ = notification
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories([
            AppReminderNotificationMetadata.category
        ])
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = notification
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(startRecordingIntentRequested(_:)),
            name: PortavozAppIntentBridge.startRecordingRequested,
            object: nil)
        MainActor.assumeIsolated {
            routePendingStartRecordingIntent()
            routeSimulatedReminderIfRequested()
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// Returning from System Settings after granting Accessibility is the
    /// permission lifecycle signal macOS gives us. Retry a previously failed
    /// mouse event tap without prompting during ordinary launches.
    func applicationDidBecomeActive(_ notification: Notification) {
        _ = notification
        MainActor.assumeIsolated {
            guard let services = Self.services else { return }
            services.dictation.syncMousePTT(services: services)
        }
    }

    @MainActor @objc
    private func startRecordingIntentRequested(_ notification: Notification) {
        _ = notification
        routePendingStartRecordingIntent()
    }

    @MainActor
    private func routePendingStartRecordingIntent() {
        // Do not consume the one-shot request until its destination exists.
        // This also protects future lifecycle changes that might construct the
        // SwiftUI service graph after the AppKit delegate finishes launching.
        guard let services = Self.services,
              PortavozAppIntentBridge.consumeStartRecordingRequest() else {
            return
        }
        services.pendingRoute = .recording(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Double-clicking a `.portavoz` file: import it as a new meeting and
    /// navigate there (same pendingRoute channel as Spotlight hits).
    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated {
            guard let services = Self.services else { return }
            for url in urls where url.pathExtension.lowercased() == "portavoz" {
                Task { @MainActor in
                    if let id = try? await services.importBundle(from: url) {
                        services.pendingRoute = .meeting(id)
                    }
                }
            }
        }
    }

    func application(
        _ application: NSApplication,
        continue userActivity: NSUserActivity,
        restorationHandler: @escaping ([any NSUserActivityRestoring]) -> Void
    ) -> Bool {
        guard userActivity.activityType == CSSearchableItemActionType,
            let raw = userActivity.userInfo?[CSSearchableItemActivityIdentifier] as? String,
            let uuid = UUID(uuidString: raw)
        else { return false }
        MainActor.assumeIsolated {
            Self.services?.pendingRoute = .meeting(MeetingID(rawValue: uuid))
        }
        return true
    }

    /// CKSyncEngine's silent push contains no Portavoz payload. It only wakes
    /// the same serialized manual cycle used by journal and explicit actions.
    func application(
        _ application: NSApplication,
        didReceiveRemoteNotification userInfo: [String: Any]
    ) {
        _ = userInfo
        MainActor.assumeIsolated {
            Self.services?.meetingSync.remoteChangeReceived()
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (
            UNNotificationPresentationOptions
        ) -> Void
    ) {
        _ = center
        guard let record = reminderRecord(from: notification) else {
            completionHandler([.banner, .sound])
            return
        }
        completionHandler([.banner, .sound])
        Task { @MainActor in
            await Self.services?.commitmentReminders.recordPresentation(record)
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        _ = center
        guard let record = reminderRecord(from: response.notification) else {
            completionHandler()
            return
        }
        let action = AppReminderNotificationMetadata.responseAction(
            for: response.actionIdentifier)
        completionHandler()
        switch action {
        case .openRadar:
            Task { @MainActor in
                await Self.routeCommitmentReminder(record)
            }
        case .snooze:
            let handledAt = Date()
            Task { @MainActor in
                await Self.snoozeCommitmentReminder(
                    record,
                    handledAt: handledAt)
            }
        case .ignore:
            break
        }
    }
}

private extension PortavozAppDelegate {
    func reminderRecord(
        from notification: UNNotification
    ) -> AppReminderNotificationRecord? {
        let request = notification.request
        guard request.content.categoryIdentifier ==
                AppReminderNotificationMetadata.categoryIdentifier
        else { return nil }
        return AppReminderNotificationMetadata.record(
            identifier: request.identifier,
            userInfo: request.content.userInfo,
            deliveredAt: notification.date)
    }

    @MainActor
    static func routeCommitmentReminder(
        _ record: AppReminderNotificationRecord
    ) async {
        await services?.commitmentReminders.recordPresentation(record)
        services?.pendingRoute = .commitments
        NSApp.activate(ignoringOtherApps: true)
    }

    @MainActor
    static func snoozeCommitmentReminder(
        _ record: AppReminderNotificationRecord,
        handledAt: Date
    ) async {
        await services?.commitmentReminders.snooze(
            record,
            handledAt: handledAt,
            until: handledAt.addingTimeInterval(
                AppReminderNotificationMetadata.snoozeInterval))
    }

    @MainActor
    func routeSimulatedReminderIfRequested() {
        let process = ProcessInfo.processInfo
        guard process.arguments.contains("-use-temp-store"),
              process.arguments.contains("-simulate-reminder-open")
        else { return }
        let commitmentID = CommitmentID()
        let deliveredAt = Date()
        Task { @MainActor in
            await Self.routeCommitmentReminder(AppReminderNotificationRecord(
                identifier: AppReminderNotificationScheduler.identifier(
                    for: commitmentID),
                commitmentID: commitmentID,
                scheduledFor: deliveredAt,
                sourceDueAt: deliveredAt,
                deliveredAt: deliveredAt))
        }
    }
}
