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

/// The first failed check in the same observation that refused dispatch.
/// Never include process identities, window names, key values or field text.
private enum UITestKeyboardOwnershipFailure: String {
    case targetNotForeground = "target-not-foreground"
    case receiverMissing = "receiver-missing"
    case receiverAmbiguous = "receiver-ambiguous"
    case frontmostUnavailable = "frontmost-unavailable"
    case frontmostMismatch = "frontmost-mismatch"
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
        var ownershipFailure: UITestKeyboardOwnershipFailure?
        _ = waitForUITestCondition(timeout: timeout) {
            admission = observedKeyboardAdmission(
                bundleIdentifier: bundleIdentifier,
                modalAnchor: modalAnchor,
                ownershipFailure: &ownershipFailure)
            return admission == .admitted
        }
        if admission == .keyboardNotOwned, let ownershipFailure {
            let receipt = "PORTAVOZ_UI_KEYBOARD_REFUSAL cause=\(ownershipFailure.rawValue)\n"
            FileHandle.standardError.write(Data(receipt.utf8))
        }
        return admission
    }

    @MainActor
    private func observedKeyboardAdmission(
        bundleIdentifier: String,
        modalAnchor: String?,
        ownershipFailure: inout UITestKeyboardOwnershipFailure?
    ) -> UITestKeyboardAdmission {
        ownershipFailure = nil
        guard ownsModalContext(anchor: modalAnchor) else { return .modalContextMismatch }
        ownershipFailure = keyboardOwnershipFailure(bundleIdentifier: bundleIdentifier)
        guard ownershipFailure == nil else { return .keyboardNotOwned }
        return .admitted
    }

    /// Sheets, alerts and app-modal dialogs (for example an `NSSavePanel` run
    /// with `runModal()`) capture Return and Escape, so default input refuses
    /// them. A `.dialog` that nothing can click is not one of them: macOS
    /// exposes the floating Writing Tools affordance that follows a native
    /// selection as a non-hittable dialog, and it never receives the keys.
    @MainActor
    private func ownsModalContext(anchor: String?) -> Bool {
        let attached = descendants(matching: .any).matching(NSPredicate(
            format: "elementType == %lu OR elementType == %lu",
            XCUIElement.ElementType.sheet.rawValue,
            XCUIElement.ElementType.alert.rawValue))
        let attachedCount = attached.count
        let dialogs = descendants(matching: .dialog)
        let interactiveDialogs = (0..<dialogs.count)
            .map { dialogs.element(boundBy: $0) }
            .filter(\.isHittable)
        guard let anchor else { return attachedCount + interactiveDialogs.count == 0 }
        guard attachedCount + interactiveDialogs.count == 1 else { return false }
        guard attachedCount == 1 else {
            let dialog = interactiveDialogs[0]
            return dialog.identifier == anchor
                || dialog.descendants(matching: .any).matching(identifier: anchor).count == 1
        }
        return attached.matching(identifier: anchor).count == 1
            || attached.containing(.any, identifier: anchor).count == 1
    }

    @MainActor
    private func keyboardOwnershipFailure(bundleIdentifier: String) -> UITestKeyboardOwnershipFailure? {
        let candidates = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
        guard state == .runningForeground else { return .targetNotForeground }
        guard !candidates.isEmpty else { return .receiverMissing }
        guard candidates.count == 1 else { return .receiverAmbiguous }
        guard let frontmost = NSWorkspace.shared.frontmostApplication else { return .frontmostUnavailable }
        return frontmost.processIdentifier == candidates[0].processIdentifier ? nil : .frontmostMismatch
    }
}
