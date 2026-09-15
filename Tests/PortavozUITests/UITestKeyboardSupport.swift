import AppKit
import XCTest

extension XCUIApplication {
    /// XCTest may silently activate an application-targeted keyboard receiver.
    /// Refuse an observed ownership change instead of reclaiming another app's
    /// focus. A modal also needs its own explicit anchor, not a background
    /// control that happens to remain visible. These are point-in-time checks,
    /// not an atomic OS input guarantee.
    @MainActor
    func typeTextIfOwned(_ text: String, bundleIdentifier: String, modalAnchor: String? = nil) -> Bool {
        guard ownsModalContext(anchor: modalAnchor), ownsKeyboardFocus(bundleIdentifier: bundleIdentifier)
        else { return false }
        typeText(text)
        return true
    }

    @MainActor
    func typeKeyIfOwned(
        _ key: XCUIKeyboardKey,
        modifierFlags: XCUIElement.KeyModifierFlags,
        bundleIdentifier: String,
        modalAnchor: String? = nil
    ) -> Bool {
        guard ownsModalContext(anchor: modalAnchor), ownsKeyboardFocus(bundleIdentifier: bundleIdentifier)
        else { return false }
        typeKey(key, modifierFlags: modifierFlags)
        return true
    }

    @MainActor
    private func ownsModalContext(anchor: String?) -> Bool {
        let sheetCount = sheets.count
        let alertCount = alerts.count
        guard let anchor else { return sheetCount + alertCount == 0 }
        guard sheetCount + alertCount == 1 else { return false }
        let modal = sheetCount == 1 ? sheets : alerts
        return modal.matching(identifier: anchor).count == 1
            || modal.containing(.any, identifier: anchor).count == 1
    }

    @MainActor
    private func ownsKeyboardFocus(bundleIdentifier: String) -> Bool {
        let candidates = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
        guard state == .runningForeground, candidates.count == 1 else { return false }
        return NSWorkspace.shared.frontmostApplication?.processIdentifier == candidates[0].processIdentifier
    }
}
