import AppKit
import CoreSpotlight
import PortavozCore

/// AppKit delegate for the plumbing SwiftUI does not deliver reliably on
/// macOS: a Spotlight hit's user activity arrives HERE (field bug: the
/// view-level `onContinueUserActivity` never fired — the system only
/// activated the app). Navigation goes through `AppServices.pendingRoute`,
/// the same channel the pre-meeting banner uses from outside the window
/// hierarchy.
final class PortavozAppDelegate: NSObject, NSApplicationDelegate {
    /// Wired by `PortavozApp.init` — the delegate is instantiated by the
    /// adaptor before any scene exists.
    @MainActor static weak var services: AppServices?

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
}
