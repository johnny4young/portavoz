import AppKit
import SwiftUI

/// Resolve the window containing this exact disposable view, not whichever
/// main-capable window happens to come first after an external URL opens one.
struct UITestMainWindowCapture: NSViewControllerRepresentable {
    func makeNSViewController(context: Context) -> UITestMainWindowCaptureController {
        UITestMainWindowCaptureController()
    }

    func updateNSViewController(_ controller: UITestMainWindowCaptureController, context: Context) {}
}

@MainActor
final class UITestMainWindowCaptureController: NSViewController {
    private let position: @MainActor (NSWindow) -> Void

    init(position: @escaping @MainActor (NSWindow) -> Void = UITestWindowPlacement.positionMainWindow) {
        self.position = position
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func loadView() { view = NSView(frame: .zero) }

    override func viewDidAppear() {
        super.viewDidAppear()
        // Match Settings: attachment precedes native frame restoration, which
        // can otherwise undo placement before an external route takes a snapshot.
        if let window = view.window { position(window) }
    }
}

/// Keeps disposable UI-test windows on AppKit's zero screen so XCTest never
/// has to synthesize a hit point in a negative-coordinate display.
///
/// Production windows remain entirely under SwiftUI and the user's saved
/// placement because every entry point is gated by `-use-temp-store`.
@MainActor
enum UITestWindowPlacement {
    private static let notificationCenterAlertOverride =
        "PORTAVOZ_UI_TEST_ALLOW_NOTIFICATION_CENTER_ALERTS"

    /// Keep utility panels above the elevated disposable main window. Normal
    /// app launches retain their original floating level, even if a stale test
    /// environment value is inherited without the disposable-store argument.
    static func floatingPanelLevel(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> NSWindow.Level {
        guard arguments.contains("-use-temp-store"),
              environment[notificationCenterAlertOverride] == "true"
        else { return .floating }
        return .statusBar
    }

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
