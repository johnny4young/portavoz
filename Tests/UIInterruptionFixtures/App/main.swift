import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private let status = NSTextField(labelWithString: "Ready")

    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(
            contentRect: NSRect(x: 420, y: 360, width: 520, height: 220),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Disposable interruption proof"
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 20
        stack.translatesAutoresizingMaskIntoConstraints = false
        status.setAccessibilityIdentifier("proof-status")
        let arm = NSButton(title: "Arm synthetic dialog", target: self, action: #selector(arm))
        arm.setAccessibilityIdentifier("proof-arm")
        let target = NSButton(title: "Unrelated action", target: self, action: #selector(targetAction))
        target.setAccessibilityIdentifier("proof-target")
        for view in [status, arm, target] { stack.addArrangedSubview(view) }
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: window.contentView!.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: window.contentView!.centerYAnchor)
        ])
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func targetAction() {
        guard let root = ProcessInfo.processInfo.environment["PROOF_EFFECTS_ROOT"] else { exit(64) }
        do { try Data().write(to: URL(fileURLWithPath: root).appendingPathComponent("target")) }
        catch { exit(74) }
        status.stringValue = "Target action happened"
    }

    @objc private func arm() {
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
}
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
