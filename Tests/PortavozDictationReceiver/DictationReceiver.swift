import AppKit

/// Disposable native editor, built only by the UI-test project. Its paste
/// action reads a named pasteboard; the user's clipboard is never inspected.
@main
@MainActor
final class DictationReceiver: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var editor: NSTextView?
    private var enableEditorButton: NSButton?

    static func main() {
        let app = NSApplication.shared
        let delegate = DictationReceiver()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { app.run() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu()
        let edit = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        edit.submenu = NSMenu(title: "Edit")
        edit.submenu?.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        menu.addItem(edit)
        NSApplication.shared.mainMenu = menu
        let window = NSWindow(
            contentRect: NSRect(x: 160, y: 200, width: 640, height: 320),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Dictation receiver"
        let editor = ReceiverTextView(frame: NSRect(x: 20, y: 20, width: 600, height: 280))
        editor.setAccessibilityIdentifier("dictation-receiver-editor")
        editor.font = .systemFont(ofSize: 18)
        editor.isRichText = false
        // This receiver measures literal delivery, not the host's smart-editing preferences.
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        let delaysEditor = ProcessInfo.processInfo.environment["PORTAVOZ_RECEIVER_DELAY_EDITOR"] == "1"
        editor.isHidden = delaysEditor
        window.contentView?.addSubview(editor)
        if delaysEditor {
            let enable = NSButton(title: "Enable editor", target: self, action: #selector(enableEditor))
            enable.frame = NSRect(x: 20, y: 250, width: 180, height: 44)
            enable.setAccessibilityIdentifier("dictation-receiver-enable-editor")
            window.contentView?.addSubview(enable)
            window.makeFirstResponder(enable)
            enableEditorButton = enable
        } else {
            window.makeFirstResponder(editor)
        }
        self.editor = editor
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        self.window = window
    }

    @objc private func enableEditor() {
        editor?.isHidden = false
        enableEditorButton?.isHidden = true
        window?.makeFirstResponder(editor)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@MainActor
private final class ReceiverTextView: NSTextView {
    override func paste(_ sender: Any?) {
        guard let name = ProcessInfo.processInfo.environment["PORTAVOZ_RECEIVER_PASTEBOARD"],
              name.hasPrefix("app.portavoz.dictation-test."),
              let text = NSPasteboard(name: .init(name)).string(forType: .string)
        else { return }
        insertText(text, replacementRange: selectedRange())
    }
}
