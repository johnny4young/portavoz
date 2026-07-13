import AppKit
import SwiftUI

/// An NSTextField-backed field that focuses itself and selects all its text
/// the moment it appears — so a rename sheet always opens with the current
/// title highlighted, ready to type over or edit. (A SwiftUI `TextField`
/// inside `.alert` shows a stale/empty value on the second presentation and
/// can't select-all; this sidesteps both.)
struct AutoSelectTextField: NSViewRepresentable {
    @Binding var text: String
    var onSubmit: () -> Void = {}

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: text)
        field.delegate = context.coordinator
        field.bezelStyle = .roundedBezel
        field.font = .systemFont(ofSize: 13)
        field.lineBreakMode = .byTruncatingTail
        field.setAccessibilityIdentifier("meeting-rename-field")
        // Focus + select-all after the field joins the window.
        DispatchQueue.main.async {
            field.window?.makeFirstResponder(field)
            field.currentEditor()?.selectAll(nil)
        }
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        private let parent: AutoSelectTextField
        init(_ parent: AutoSelectTextField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(
            _ control: NSControl, textView: NSTextView, doCommandBy selector: Selector
        ) -> Bool {
            if selector == #selector(NSResponder.insertNewline(_:)) {
                parent.onSubmit()
                return true
            }
            return false
        }
    }
}
