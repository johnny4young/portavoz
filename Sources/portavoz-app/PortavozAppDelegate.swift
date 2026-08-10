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
    @MainActor private var stopRecordingIntentTask: Task<Void, Never>?

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
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(stopRecordingIntentRequested(_:)),
            name: PortavozAppIntentBridge.stopRecordingRequested,
            object: nil)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(navigationIntentRequested(_:)),
            name: PortavozAppIntentBridge.navigationRequested,
            object: nil)
        MainActor.assumeIsolated {
            routePendingStartRecordingIntent()
            routePendingStopRecordingIntent()
            routePendingNavigationIntent()
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

    @MainActor @objc
    private func stopRecordingIntentRequested(_ notification: Notification) {
        _ = notification
        routePendingStopRecordingIntent()
    }

    @MainActor @objc
    private func navigationIntentRequested(_ notification: Notification) {
        _ = notification
        routePendingNavigationIntent()
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

    @MainActor
    private func routePendingStopRecordingIntent() {
        // Preserve a cold-launch request until the complete service graph
        // exists. Once it does, consume exactly one disposition synchronously
        // so Shortcuts/Siri receive an honest result from perform().
        guard let services = Self.services else { return }
        let disposition = Self.stopRecordingIntentDisposition(
            for: services.recording.phase,
            stopTaskIsRunning: stopRecordingIntentTask != nil)
        guard PortavozAppIntentBridge.consumeStopRecordingRequest(
            as: disposition
        ) else { return }

        NSApp.activate(ignoringOtherApps: true)
        switch disposition {
        case .accepted:
            // Keep durable finalization and any typed recovery visible even if
            // the user invoked the action while browsing another meeting.
            services.pendingRoute = .recording(nil)
            stopRecordingIntentTask = Task { @MainActor [weak self] in
                await services.recording.stop(services: services)
                self?.stopRecordingIntentTask = nil
            }
        case .recordingIsPreparing, .alreadyStopping:
            services.pendingRoute = .recording(nil)
        case .recoveryRequired:
            services.pendingRoute = .recordingRecovery
        case .queued, .noActiveRecording:
            break
        }
    }

    @MainActor
    private func routePendingNavigationIntent() {
        guard let services = Self.services,
              let request = PortavozAppIntentBridge.consumeNavigationRequest()
        else { return }

        services.pendingRoute = Self.route(for: request)
        NSApp.activate(ignoringOtherApps: true)
    }

    @MainActor
    static func route(
        for request: PortavozAppIntentBridge.NavigationRequest
    ) -> Route {
        switch request {
        case .library:
            .library
        case .commitments:
            .commitments(nil)
        case .meeting(let value):
            UUID(uuidString: value).map { .meeting(MeetingID(rawValue: $0)) }
                ?? .library
        case .person(let value):
            UUID(uuidString: value).map {
                .commitments(.person(PersonID(rawValue: $0)))
            } ?? .commitments(nil)
        case .commitment(let value):
            UUID(uuidString: value).map {
                .commitments(.commitment(CommitmentID(rawValue: $0)))
            } ?? .commitments(nil)
        }
    }

    @MainActor
    static func stopRecordingIntentDisposition(
        for phase: RecordingPhase,
        stopTaskIsRunning: Bool
    ) -> PortavozAppIntentBridge.StopRecordingRequestDisposition {
        if stopTaskIsRunning { return .alreadyStopping }
        return switch phase {
        case .idle, .done:
            .noActiveRecording
        case .preparing:
            .recordingIsPreparing
        case .recording:
            .accepted
        case .processing:
            .alreadyStopping
        case .failed:
            .recoveryRequired
        }
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
        case .dismiss:
            let handledAt = Date()
            Task { @MainActor in
                await Self.dismissCommitmentReminder(
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
        services?.pendingRoute = .commitments(.commitment(record.commitmentID))
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
    static func dismissCommitmentReminder(
        _ record: AppReminderNotificationRecord,
        handledAt: Date
    ) async {
        await services?.commitmentReminders.dismiss(
            record,
            handledAt: handledAt)
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
