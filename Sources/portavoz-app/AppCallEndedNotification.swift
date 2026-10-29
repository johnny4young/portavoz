import Foundation
import UserNotifications

/// "Did the call end?" while the recording window may be hidden. Posted only
/// when notifications are already allowed; it never asks mid-meeting, and
/// the in-app notice and countdown work either way.
enum AppCallEndedNotification {
    static let categoryIdentifier = "portavoz.call-ended"
    static let requestIdentifier = "portavoz.call-ended"
    static let stopActionIdentifier = "portavoz.call-ended.stop"
    static let keepActionIdentifier = "portavoz.call-ended.keep"

    enum Response {
        case stop
        case keepRecording
        case open
    }

    static var category: UNNotificationCategory {
        UNNotificationCategory(
            identifier: categoryIdentifier,
            actions: [
                UNNotificationAction(
                    identifier: stopActionIdentifier,
                    title: L10n.text("Stop recording"),
                    options: [.foreground]),
                UNNotificationAction(
                    identifier: keepActionIdentifier,
                    title: L10n.text("Keep recording"),
                    options: [])
            ],
            intentIdentifiers: [],
            options: [])
    }

    static func response(for actionIdentifier: String) -> Response? {
        switch actionIdentifier {
        case stopActionIdentifier: .stop
        case keepActionIdentifier: .keepRecording
        case UNNotificationDefaultActionIdentifier: .open
        default: nil
        }
    }

    static func post(secondsUntilStop: Int) {
        let center = UNUserNotificationCenter.current()
        let minutes = max(1, Int((Double(secondsUntilStop) / 60).rounded(.up)))
        let title = L10n.text("Did the call end?")
        let body = L10n.format("Both sides have been quiet. Portavoz stops recording in %lld min.", minutes)
        Task {
            let settings = await center.notificationSettings()
            guard settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional
            else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.categoryIdentifier = categoryIdentifier
            content.sound = .default
            try? await center.add(UNNotificationRequest(
                identifier: requestIdentifier, content: content, trigger: nil))
        }
    }

    static func withdraw() {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [requestIdentifier])
        center.removeDeliveredNotifications(withIdentifiers: [requestIdentifier])
    }
}
