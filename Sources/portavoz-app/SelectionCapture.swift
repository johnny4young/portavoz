import AppKit
import ApplicationKit
import ApplicationServices

/// Why a selection cannot be rewritten, or its replacement was withheld.
enum SelectionRewriteFailure: Error, Equatable {
    case accessibilityRequired
    case secureField
    case nothingSelected
    case tooLong
    case unavailable
    case selectionChanged
}

/// The text selected when a rewrite started, and the one way to replace exactly it.
@MainActor
struct CapturedSelection {
    enum Source: Equatable { case accessibility, copied }

    let text: String
    let source: Source
    let applicationName: String?
    /// Nil while the same field still selects the same text.
    let revalidate: () -> SelectionRewriteFailure?
    let destination: CapturedDictationDestination
}

extension TextInserter {
    @MainActor
    static func captureSelection(
        pasteboard: NSPasteboard = .general
    ) async -> Result<CapturedSelection, SelectionRewriteFailure> {
        guard canInsert(promptIfNeeded: true) else { return .failure(.accessibilityRequired) }
        guard let application = NSWorkspace.shared.frontmostApplication,
              application.processIdentifier > 0, !application.isTerminated else { return .failure(.unavailable) }
        let element = focusedApplicationElement(application.processIdentifier)
        if let element, fieldSecurity(of: element) == .secure { return .failure(.secureField) }
        let destination = captureDestination(pasteboard: pasteboard)
        let focusIsUnchanged = {
            guard let current = NSWorkspace.shared.frontmostApplication, application.isEqual(current) else {
                return false
            }
            guard let element else { return true }
            return focusedApplicationElement(current.processIdentifier).map { CFEqual($0, element) } ?? false
        }
        if let element, let selected = accessibleSelection(in: element) {
            let (range, text, readback) = selected
            guard text.count <= PolishDictation.maximumCharacters else { return .failure(.tooLong) }
            return .success(CapturedSelection(
                text: text, source: .accessibility, applicationName: application.localizedName,
                revalidate: {
                    guard focusIsUnchanged(), readback.position()?.selection == range,
                          readback.string(range) == text else { return .selectionChanged }
                    return nil
                },
                destination: destination))
        }
        // The shortcut's own modifiers would turn the copy into another command.
        guard await waitForModifierRelease() else { return .failure(.unavailable) }
        let copied = await DictationClipboard.shared.copySelection(on: pasteboard) {
            postCommandC(to: application.processIdentifier)
        }
        guard let text = copied, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failure(.nothingSelected)
        }
        guard text.count <= PolishDictation.maximumCharacters else { return .failure(.tooLong) }
        return .success(CapturedSelection(
            text: text, source: .copied, applicationName: application.localizedName,
            revalidate: { focusIsUnchanged() ? nil : .selectionChanged },
            destination: destination))
    }

    /// The selected span and its text through Accessibility; nil when the field exposes neither.
    @MainActor
    private static func accessibleSelection(
        in element: AXUIElement
    ) -> (NSRange, String, DictationTextReadback)? {
        guard let readback = DictationTextReadback.accessibility(element),
              let position = readback.position(), position.isValid, position.selection.length > 0,
              position.selection.length <= DictationTextReadback.maximumUTF16Length,
              let text = readback.string(position.selection),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return (position.selection, text, readback)
    }
}
