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

    /// AppKit restores a collapsed sidebar on the next launch; a journey that
    /// hides it must not decide the layout of the ones that follow.
    static func forgetSplitViewFrames(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        defaults: UserDefaults = .standard
    ) {
        guard arguments.contains("-use-temp-store"), arguments.contains("-reset-sidebar") else { return }
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("NSSplitView Subview Frames ") {
            defaults.removeObject(forKey: key)
        }
    }

    /// `-seed-dark-appearance` and `-seed-light-appearance` pin the disposable app's appearance on any host.
    static func applyAppearanceOverride(arguments: [String] = ProcessInfo.processInfo.arguments) {
        guard arguments.contains("-use-temp-store") else { return }
        if arguments.contains("-seed-dark-appearance") {
            NSApp.appearance = NSAppearance(named: .darkAqua)
        } else if arguments.contains("-seed-light-appearance") {
            NSApp.appearance = NSAppearance(named: .aqua)
        }
    }

    static func positionMainWindow(_ window: NSWindow) {
        applyAppearanceOverride()
        guard let visibleFrame = zeroScreenVisibleFrame else { return }
        let arguments = ProcessInfo.processInfo.arguments
        let preferredHeight: CGFloat?
        if arguments.contains("-seed-minimum-transcript-window") {
            preferredHeight = 560
        } else if arguments.contains("-seed-compact-transcript-window") {
            preferredHeight = 620
        } else {
            preferredHeight = nil
        }
        let frame = mainWindowFrame(
            in: visibleFrame,
            preferredHeight: preferredHeight,
            width: arguments.contains("-seed-wide-window") ? .full
                : arguments.contains("-seed-narrow-window") ? .minimum : .standard)
        applyAcceptedNotificationCenterIsolation(to: window)
        window.setFrame(frame, display: true, animate: false)
    }

    /// `.full` gives up the left clearance so wide layouts can be seen;
    /// `.minimum` keeps the narrowest window so narrow layouts can.
    enum Width { case standard, full, minimum }

    static func mainWindowFrame(
        in visibleFrame: NSRect,
        preferredHeight: CGFloat?,
        width: Width = .standard
    ) -> NSRect {
        let spare = max(0, visibleFrame.width - 900)
        let leftClearance: CGFloat = switch width {
        case .standard: min(400, spare)
        case .full: 0
        case .minimum: spare
        }
        let height = min(visibleFrame.height, preferredHeight ?? visibleFrame.height)
        return NSRect(
            x: visibleFrame.minX + leftClearance,
            y: visibleFrame.maxY - height,
            width: visibleFrame.width - leftClearance,
            height: height)
    }

    static func positionSettingsWindow(_ window: NSWindow) {
        applyAppearanceOverride()
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
