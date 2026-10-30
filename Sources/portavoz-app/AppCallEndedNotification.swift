import Foundation
import PortavozCore
import UserNotifications

/// "Did the call end?" while the recording window may be hidden. Posted only
/// when notifications are already allowed; it never asks mid-meeting, and
/// the in-app notice and countdown work either way.
enum AppCallEndedNotification {
    static let categoryIdentifier = "portavoz.call-ended"
    static let sessionKey = "portavoz.call-ended.session"
    @MainActor private static var fence = CallEndedNotificationFence()
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

    @MainActor
    static func accepts(identifier: String?, sessionID: UUID, isRecording: Bool) -> Bool {
        fence.accepts(identifier: identifier, sessionID: sessionID, isRecording: isRecording)
    }

    @MainActor
    static func post(secondsUntilStop: Int, sessionID: UUID) {
        withdraw()
        let ticket = fence.begin(sessionID: sessionID)
        let center = UNUserNotificationCenter.current()
        let minutes = max(1, Int((Double(secondsUntilStop) / 60).rounded(.up)))
        let title = L10n.text("Did the call end?")
        let body = L10n.format("Both sides have been quiet. Portavoz stops recording in %lld min.", minutes)
        Task {
            let settings = await center.notificationSettings()
            guard settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional
            else { return }
            guard fence.current == ticket else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.categoryIdentifier = categoryIdentifier
            content.sound = .default
            content.userInfo = [sessionKey: sessionID.uuidString]
            try? await center.add(UNNotificationRequest(
                identifier: ticket.identifier, content: content, trigger: nil))
            if fence.current != ticket { remove(ticket.identifier, from: center) }
        }
    }

    @MainActor
    static func withdraw() {
        if let ticket = fence.withdraw() {
            remove(ticket.identifier, from: UNUserNotificationCenter.current())
        }
    }

    private static func remove(_ identifier: String, from center: UNUserNotificationCenter) {
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
    }
}
