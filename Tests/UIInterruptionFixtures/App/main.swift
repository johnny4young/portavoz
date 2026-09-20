import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSTextFieldDelegate {
    private var window: NSWindow!
    private let status = NSTextField(labelWithString: "Ready")
    private let input = NSTextField(string: "")

    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu()
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        menu.addItem(editItem)
        NSApp.mainMenu = menu
        window = NSWindow(
            contentRect: NSRect(x: 420, y: 360, width: 520, height: 220),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Disposable interruption proof"
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 20
        stack.translatesAutoresizingMaskIntoConstraints = false
        status.setAccessibilityIdentifier("proof-status")
        input.setAccessibilityIdentifier("proof-input")
        // The synthetic app must not raise its own completion popover: that
        // surface covers this fixture's own controls and interrupts the control
        // before it reaches the behaviour under test. Real completion belongs to
        // product journeys, not to this disposable harness proof.
        input.isAutomaticTextCompletionEnabled = false
        input.delegate = self
        input.widthAnchor.constraint(equalToConstant: 280).isActive = true
        let arm = NSButton(title: "Arm synthetic dialog", target: self, action: #selector(arm))
        arm.setAccessibilityIdentifier("proof-arm")
        let target = NSButton(title: "Unrelated action", target: self, action: #selector(targetAction))
        target.setAccessibilityIdentifier("proof-target")
        for view in [status, input, arm, target] { stack.addArrangedSubview(view) }
        // Launch with the button focused so no editor owns the keyboard before
        // a control deliberately clicks the field.
        window.initialFirstResponder = arm
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: window.contentView!.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: window.contentView!.centerYAnchor)
        ])
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func controlTextDidChange(_ notification: Notification) {
        recordEffect("typed")
    }

    @objc private func targetAction() {
        recordEffect("target")
        status.stringValue = "Target action happened"
    }

    private func recordEffect(_ name: String) {
        guard let root = ProcessInfo.processInfo.environment["PROOF_EFFECTS_ROOT"] else { exit(64) }
        do { try Data().write(to: URL(fileURLWithPath: root).appendingPathComponent(name)) }
        catch { exit(74) }
    }

    @objc private func arm() {
        if ProcessInfo.processInfo.environment["PROOF_APP_MODAL_DIALOG"] == "1" {
            status.stringValue = "Dialog armed"
            // Return from the click first; the app-modal session then owns the
            // run loop exactly like a product `NSSavePanel.runModal()`.
            perform(#selector(presentAppModalDialog), with: nil, afterDelay: 0)
            return
        }
        if ProcessInfo.processInfo.environment["PROOF_SAME_APP_MODAL"] == "1" {
            let alert = NSAlert()
            alert.messageText = "Synthetic modal interruption"
            alert.informativeText = "Disposable fixture only; this is not a system permission request."
            let editor = NSTextField(string: "")
            editor.setAccessibilityIdentifier("proof-modal-editor")
            editor.isAutomaticTextCompletionEnabled = false
            editor.delegate = self
            editor.frame.size = NSSize(width: 240, height: 24)
            alert.accessoryView = editor
            alert.addButton(withTitle: "Synthetic modal choice").setAccessibilityIdentifier("proof-modal-choice")
            status.stringValue = "Dialog armed"
            alert.beginSheetModal(for: window) { [weak self] _ in self?.recordEffect("modal-choice") }
            return
        }
        guard let path = ProcessInfo.processInfo.environment["PROOF_OVERLAY_EXECUTABLE"],
              let effects = ProcessInfo.processInfo.environment["PROOF_EFFECTS_ROOT"] else {
            status.stringValue = "Missing fixture path"
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = [String(Double(window.frame.minX)), String(Double(window.frame.minY)),
                                   String(ProcessInfo.processInfo.processIdentifier), effects,
                                   "-ApplePersistenceIgnoreState", "YES", "-NSQuitAlwaysKeepsWindows", "NO"]
        configuration.activates = true
        configuration.addsToRecentItems = false
        configuration.createsNewApplicationInstance = true
        let appURL = URL(fileURLWithPath: path).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        Task { @MainActor in
            do {
                _ = try await NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
                status.stringValue = "Dialog armed"
            } catch {
                status.stringValue = "Fixture launch failed"
            }
        }
    }

    @objc private func presentAppModalDialog() {
        let alert = NSAlert()
        alert.messageText = "Synthetic app-modal interruption"
        alert.informativeText = "Disposable fixture only; this is not a system permission request."
        let editor = NSTextField(string: "")
        editor.setAccessibilityIdentifier("proof-dialog-editor")
        editor.isAutomaticTextCompletionEnabled = false
        editor.delegate = self
        editor.frame.size = NSSize(width: 240, height: 24)
        alert.accessoryView = editor
        alert.addButton(withTitle: "Synthetic dialog choice").setAccessibilityIdentifier("proof-dialog-choice")
        _ = alert.runModal()
        recordEffect("modal-choice")
    }
}
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
