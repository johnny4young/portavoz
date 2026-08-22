import AppKit

/// Keeps disposable UI-test windows on AppKit's zero screen so XCTest never
/// has to synthesize a hit point in a negative-coordinate display.
///
/// Production windows remain entirely under SwiftUI and the user's saved
/// placement because every entry point is gated by `-use-temp-store`.
@MainActor
enum UITestWindowPlacement {
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
        window.setFrame(constrainedFrame, display: true, animate: false)
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
