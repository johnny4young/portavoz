import AppKit

/// Keeps disposable UI-test windows on AppKit's zero screen so XCTest never
/// has to synthesize a hit point in a negative-coordinate display.
///
/// Production windows remain entirely under SwiftUI and the user's saved
/// placement because every entry point is gated by `-use-temp-store`.
@MainActor
enum UITestWindowPlacement {
    private static let notificationCenterAlertOverride =
        "PORTAVOZ_UI_TEST_ALLOW_NOTIFICATION_CENTER_ALERTS"

    static func positionMainWindow(_ window: NSWindow) {
        guard let visibleFrame = zeroScreenVisibleFrame else { return }

        let minimumWidth: CGFloat = 900
        let leftClearance = min(
            400,
            max(0, visibleFrame.width - minimumWidth))
        let frame = NSRect(
            x: visibleFrame.minX + leftClearance,
            y: visibleFrame.minY,
            width: visibleFrame.width - leftClearance,
            height: visibleFrame.height)
        applyAcceptedNotificationCenterIsolation(to: window)
        window.setFrame(frame, display: true, animate: false)
    }

    static func positionSettingsWindow(_ window: NSWindow) {
        guard let screen = zeroScreen else { return }

        let visibleFrame = screen.visibleFrame
        var frame = window.frame
        frame.origin = NSPoint(
            x: visibleFrame.midX - frame.width / 2,
            y: visibleFrame.midY - frame.height / 2)
        let constrainedFrame = window.constrainFrameRect(frame, to: screen)
        applyAcceptedNotificationCenterIsolation(to: window)
        window.setFrame(constrainedFrame, display: true, animate: false)
    }

    /// A persistent Notification Center alert is a modal-panel-level window.
    /// The explicit local D432 override accepts only that category, so keep
    /// disposable test windows at AppKit's standard status-bar level for that
    /// run. This changes no production window and never reads or mutates the
    /// alert; it only prevents the accepted overlay from occluding hit targets.
    private static func applyAcceptedNotificationCenterIsolation(
        to window: NSWindow
    ) {
        guard ProcessInfo.processInfo.environment[
            notificationCenterAlertOverride] == "true"
        else { return }
        window.level = .statusBar
    }

    private static var zeroScreenVisibleFrame: NSRect? {
        zeroScreen?.visibleFrame
    }

    /// The first screen is AppKit's documented "zero" screen. `main` instead
    /// follows the key window and can therefore inherit a negative coordinate.
    private static var zeroScreen: NSScreen? {
        guard ProcessInfo.processInfo.arguments.contains("-use-temp-store") else {
            return nil
        }
        return NSScreen.screens.first
    }
}
