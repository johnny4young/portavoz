import AppKit
import XCTest

/// The outcome of one keyboard admission. Refusals name only a content-free
/// category, so a guard receipt distinguishes a lost receiver from a modal
/// mismatch without recording window text.
enum UITestKeyboardAdmission: Equatable, Sendable {
    case admitted
    case keyboardNotOwned
    case modalContextMismatch

    /// The stop category recorded when a journey's input is refused.
    var stopReason: String {
        switch self {
        case .admitted: "admitted"
        case .keyboardNotOwned: "keyboard-owner"
        case .modalContextMismatch: "modal-context"
        }
    }
}

/// The observable result of ending one text field's native editor.
enum UITestTextFieldEditingHandoff: Equatable, Sendable {
    /// The field owned the editor and released the native completion surface.
    case finished
    /// The field was not the active editor, so no key was sent.
    case notEditing
    case fieldUnavailable
    case keyboardRefused(UITestKeyboardAdmission)
    case valueChanged
    /// A surface still covers the field, so a later click would be interrupted.
    case surfaceRetained
    /// This toolchain no longer publishes the focus attribute; fail closed
    /// rather than sending a key that could move focus into the field.
    case focusUnobservable

    var succeeded: Bool { self == .finished || self == .notEditing }

    var diagnosis: String {
        switch self {
        case .finished: "finished"
        case .notEditing: "the field was not editing"
        case .fieldUnavailable: "the field never appeared"
        case .keyboardRefused(let admission): "keyboard admission refused (\(admission.stopReason))"
        case .valueChanged: "the handoff changed the field value"
        case .surfaceRetained: "a native surface still covers the field"
        case .focusUnobservable: "this toolchain no longer publishes keyboard focus"
        }
    }
}

extension XCUIElement {
    /// XCTest publishes no macOS focus attribute, so read the snapshot key the
    /// automation daemon already reports. A toolchain that stops publishing it
    /// returns `nil`, and every caller fails closed instead of guessing.
    @MainActor
    var observedKeyboardFocus: Bool? {
        let key = "hasKeyboardFocus"
        guard responds(to: NSSelectorFromString(key)) else { return nil }
        return value(forKey: key) as? Bool
    }
}

extension XCUIApplication {
    /// XCTest may silently activate an application-targeted keyboard receiver.
    /// Refuse an observed ownership change instead of reclaiming another app's
    /// focus. A modal also needs its own explicit anchor, not a background
    /// control that happens to remain visible. These are point-in-time checks,
    /// not an atomic OS input guarantee.
    @MainActor
    func typeTextIfOwned(
        _ text: String,
        bundleIdentifier: String,
        modalAnchor: String? = nil
    ) -> UITestKeyboardAdmission {
        let admission = keyboardAdmission(bundleIdentifier: bundleIdentifier, modalAnchor: modalAnchor)
        guard admission == .admitted else { return admission }
        typeText(text)
        return admission
    }

    @MainActor
    func typeKeyIfOwned(
        _ key: XCUIKeyboardKey,
        modifierFlags: XCUIElement.KeyModifierFlags,
        bundleIdentifier: String,
        modalAnchor: String? = nil
    ) -> UITestKeyboardAdmission {
        let admission = keyboardAdmission(bundleIdentifier: bundleIdentifier, modalAnchor: modalAnchor)
        guard admission == .admitted else { return admission }
        typeKey(key, modifierFlags: modifierFlags)
        return admission
    }

    /// Observes ownership for at most one bounded interval. The run loop keeps
    /// servicing workspace notifications between probes, so a cached frontmost
    /// value or a sheet that is still closing can converge. Nothing is activated,
    /// dismissed or answered while waiting; a persistent mismatch is refused.
    @MainActor
    private func keyboardAdmission(
        bundleIdentifier: String,
        modalAnchor: String?,
        timeout: TimeInterval = 1
    ) -> UITestKeyboardAdmission {
        var admission = UITestKeyboardAdmission.keyboardNotOwned
        _ = waitForUITestCondition(timeout: timeout) {
            admission = observedKeyboardAdmission(
                bundleIdentifier: bundleIdentifier, modalAnchor: modalAnchor)
            return admission == .admitted
        }
        return admission
    }

    @MainActor
    private func observedKeyboardAdmission(
        bundleIdentifier: String,
        modalAnchor: String?
    ) -> UITestKeyboardAdmission {
        guard ownsModalContext(anchor: modalAnchor) else { return .modalContextMismatch }
        guard ownsKeyboardFocus(bundleIdentifier: bundleIdentifier) else { return .keyboardNotOwned }
        return .admitted
    }

    /// Sheets, alerts and app-modal dialogs (for example an `NSSavePanel` run
    /// with `runModal()`) capture Return and Escape, so default input refuses
    /// them. A `.dialog` that nothing can click is not one of them: macOS
    /// exposes the floating Writing Tools affordance that follows a native
    /// selection as a non-hittable dialog, and it never receives the keys.
    @MainActor
    private func ownsModalContext(anchor: String?) -> Bool {
        // An open panel remains in the tree while its Go to Folder sheet owns
        // input. Count independent innermost receivers, not their ancestors.
        let surfaces = activeModalSurfaces(in: self)
        // A sole active surface cannot have another active receiver below it.
        let receivers = surfaces.count < 2 ? surfaces : surfaces.filter {
            activeModalSurfaces(in: $0).isEmpty
        }
        guard let anchor else { return receivers.isEmpty }
        guard receivers.count == 1 else { return false }
        let receiver = receivers[0]
        return receiver.identifier == anchor
            || receiver.descendants(matching: .any).matching(identifier: anchor).count == 1
    }

    @MainActor
    private func activeModalSurfaces(in element: XCUIElement) -> [XCUIElement] {
        let attached = element.descendants(matching: .any).matching(NSPredicate(
            format: "elementType == %lu OR elementType == %lu",
            XCUIElement.ElementType.sheet.rawValue,
            XCUIElement.ElementType.alert.rawValue))
        let attachedCount = attached.count
        let dialogs = element.descendants(matching: .dialog)
        let interactiveDialogs = (0..<dialogs.count)
            .map { dialogs.element(boundBy: $0) }
            .filter { dialog in
                // A dialog containing an attached modal is already an ancestor.
                // Avoid its expensive native hit test while its child owns input.
                if attachedCount > 0 {
                    let nested = dialog.descendants(matching: .any).matching(NSPredicate(
                        format: "elementType == %lu OR elementType == %lu",
                        XCUIElement.ElementType.sheet.rawValue,
                        XCUIElement.ElementType.alert.rawValue))
                    if nested.count > 0 { return false }
                }
                return dialog.isHittable
            }
        return (0..<attachedCount).map { attached.element(boundBy: $0) } + interactiveDialogs
    }

    @MainActor
    private func ownsKeyboardFocus(bundleIdentifier: String) -> Bool {
        let candidates = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
        guard state == .runningForeground, candidates.count == 1 else { return false }
        return NSWorkspace.shared.frontmostApplication?.processIdentifier == candidates[0].processIdentifier
    }
}
