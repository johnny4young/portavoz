import Foundation
import UserNotifications

/// "Did the call end?" while the recording window may be hidden. Posted only
/// when notifications are already allowed; it never asks mid-meeting, and
/// the in-app notice and countdown work either way.
enum AppCallEndedNotification {
    static let categoryIdentifier = "portavoz.call-ended"
    static let sessionKey = "portavoz.call-ended.session"
    static let stopActionIdentifier = "portavoz.call-ended.stop"
    static let keepActionIdentifier = "portavoz.call-ended.keep"
    @MainActor static let notifier = CallEndedNotifier(center: SystemCallEndedNotificationCenter())

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
    static func post(secondsUntilStop: Int, sessionID: UUID) {
        let minutes = max(1, Int((Double(secondsUntilStop) / 60).rounded(.up)))
        notifier.post(
            title: L10n.text("Did the call end?"),
            body: L10n.format("Both sides have been quiet. Portavoz stops recording in %lld min.", minutes),
            sessionID: sessionID)
    }

    @MainActor
    static func withdraw() {
        notifier.withdraw()
    }
}

/// The Notification Center calls the notifier makes, so tests can hold them.
@MainActor
protocol CallEndedNotificationCenter: AnyObject {
    func canPost() async -> Bool
    func add(identifier: String, title: String, body: String, sessionID: UUID) async
    func remove(identifiers: [String])
    func deliveredIdentifiers() async -> [String]
}

/// One question belongs to one recording and expires when withdrawn, so a
/// late publication or an action from a retired question never acts.
@MainActor
final class CallEndedNotifier {
    private struct Question: Equatable {
        let identifier: String
        let sessionID: UUID
    }

    private let center: any CallEndedNotificationCenter
    private var current: Question?

    init(center: any CallEndedNotificationCenter) {
        self.center = center
    }

    @discardableResult
    func post(title: String, body: String, sessionID: UUID) -> Task<Void, Never> {
        withdraw()
        let question = Question(
            identifier: "\(AppCallEndedNotification.categoryIdentifier).\(UUID().uuidString)",
            sessionID: sessionID)
        current = question
        return Task {
            guard await center.canPost(), current == question else { return }
            await center.add(identifier: question.identifier, title: title, body: body, sessionID: sessionID)
            if current != question { center.remove(identifiers: [question.identifier]) }
        }
    }

    func withdraw() {
        guard let question = current else { return }
        current = nil
        center.remove(identifiers: [question.identifier])
    }

    func accepts(identifier: String, sessionID: UUID) -> Bool {
        current == Question(identifier: identifier, sessionID: sessionID)
    }

    /// Clears questions left by a previous process, which no action can answer.
    func removeOrphans() async {
        let orphans = await center.deliveredIdentifiers().filter { $0 != current?.identifier }
        if !orphans.isEmpty { center.remove(identifiers: orphans) }
    }
}

@MainActor
final class SystemCallEndedNotificationCenter: CallEndedNotificationCenter {
    private var center: UNUserNotificationCenter { .current() }

    func canPost() async -> Bool {
        let status = await center.notificationSettings().authorizationStatus
        return status == .authorized || status == .provisional
    }

    func add(identifier: String, title: String, body: String, sessionID: UUID) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.categoryIdentifier = AppCallEndedNotification.categoryIdentifier
        content.sound = .default
        content.userInfo = [AppCallEndedNotification.sessionKey: sessionID.uuidString]
        try? await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
    }

    func remove(identifiers: [String]) {
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }

    func deliveredIdentifiers() async -> [String] {
        await center.deliveredNotifications()
            .filter { $0.request.content.categoryIdentifier == AppCallEndedNotification.categoryIdentifier }
            .map(\.request.identifier)
    }
}
