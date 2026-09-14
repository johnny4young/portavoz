import AppKit
import Darwin

@MainActor
final class OverlayDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var parentExit: DispatchSourceProcess?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = ProcessInfo.processInfo.arguments
        guard args.count >= 5, let x = Double(args[1]), let y = Double(args[2]),
              let parent = Int32(args[3]), parent > 1 else { exit(64) }
        guard kill(parent, 0) == 0 else { exit(0) }
        let ownerExit = DispatchSource.makeProcessSource(
            identifier: parent, eventMask: .exit, queue: .global(qos: .utility))
        ownerExit.setEventHandler { exit(0) }
        ownerExit.resume()
        parentExit = ownerExit
        guard kill(parent, 0) == 0 else { exit(0) }
        window = NSWindow(contentRect: NSRect(x: x, y: y, width: 520, height: 220),
                          styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Synthetic interruption owner"
        window.level = .modalPanel
        let choice = NSButton(title: "Synthetic choice", target: self, action: #selector(choiceMade))
        choice.setAccessibilityIdentifier("proof-choice")
        choice.frame = NSRect(x: 100, y: 80, width: 320, height: 40)
        window.contentView!.addSubview(choice)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func choiceMade() {
        let effects = ProcessInfo.processInfo.arguments[4]
        do { try Data().write(to: URL(fileURLWithPath: effects).appendingPathComponent("choice")) }
        catch { exit(74) }
    }
}
let app = NSApplication.shared
let delegate = OverlayDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
