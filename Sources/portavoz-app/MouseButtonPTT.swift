import AppKit
import Carbon.HIToolbox
import SwiftUI

/// The configured push-to-talk mouse button as stored settings. Button
/// numbers follow `CGEvent`: 0 = left, 1 = right, 2 = middle, 3+ = extra
/// buttons. Only 2+ are eligible — rebinding a primary button would break
/// clicking everywhere, so left/right can never become a PTT trigger.
struct MouseButtonSetting {
    static let buttonKey = "dictationMouseButton"
    /// Sentinel for "no mouse PTT configured" (also the left button's
    /// number, which is never eligible — the two can share safely).
    static let off = 0

    static func isEligible(_ button: Int) -> Bool { button >= 2 }

    static func load(from defaults: UserDefaults = .standard) -> Int {
        defaults.integer(forKey: buttonKey)
    }

    static func save(_ button: Int, to defaults: UserDefaults = .standard) {
        defaults.set(button, forKey: buttonKey)
    }

    /// Human ordinal: hardware button 2 reads "Button 3" like mouse vendors
    /// label it.
    static func label(for button: Int) -> String {
        L10n.format("Button %d", button + 1)
    }
}

/// A session event tap that turns one spare mouse button into a
/// push-to-talk trigger anywhere on the system. The tap CONSUMES the
/// configured button's press/release (the target app never sees the click)
/// and passes every other button through untouched. Requires the same
/// Accessibility trust the paste path already asks for; `init` fails
/// without it and the caller stays keyboard-only.
@MainActor
final class MouseButtonPTT {
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private let button: Int64
    private let onPress: () -> Void
    private let onRelease: () -> Void

    init?(
        button: Int,
        onPress: @escaping () -> Void,
        onRelease: @escaping () -> Void
    ) {
        guard MouseButtonSetting.isEligible(button) else { return nil }
        self.button = Int64(button)
        self.onPress = onPress
        self.onRelease = onRelease

        let mask = (1 << CGEventType.otherMouseDown.rawValue)
            | (1 << CGEventType.otherMouseUp.rawValue)
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let ptt = Unmanaged<MouseButtonPTT>.fromOpaque(userInfo)
                    .takeUnretainedValue()
                let button = event.getIntegerValueField(.mouseEventButtonNumber)
                // The source is attached to the main run loop, so the
                // callback always arrives on the main thread. Only Sendable
                // values cross into the isolation check — the CGEvent stays
                // out here.
                let consumed = MainActor.assumeIsolated {
                    ptt.handle(type: type, button: button)
                }
                return consumed ? nil : Unmanaged.passUnretained(event)
            },
            userInfo: selfPointer)
        else { return nil }

        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    /// Returns whether the event was consumed — true means the click never
    /// reaches the app under the cursor.
    private func handle(type: CGEventType, button: Int64) -> Bool {
        // macOS disables a tap it considers slow; silently staying dead
        // would strand the user mid-dictation, so always re-arm.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        }
        guard button == self.button else { return false }
        if type == .otherMouseDown {
            onPress()
        } else {
            onRelease()
        }
        return true
    }

    func invalidate() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            self.tap = nil
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
            self.runLoopSource = nil
        }
    }

    // No deinit cleanup for the same reason as GlobalHotkey: a nonisolated
    // deinit cannot touch main-actor state under Swift 6. The controller
    // owns exactly one instance and always calls `invalidate()` first.
}

/// "Click here with a spare mouse button": arms a local monitor that
/// captures the next extra-button click as the PTT trigger. Esc cancels;
/// the primary buttons never arrive (`.otherMouseDown` excludes them).
struct MouseButtonRecorder: View {
    @State private var recording = false
    @State private var monitors: [Any] = []
    @State private var button = MouseButtonSetting.load()
    /// Called AFTER the accepted new setting was persisted.
    let onChange: () -> Void

    var body: some View {
        HStack {
            Text("Push-to-talk mouse button")
            Spacer()
            Button {
                recording ? stopRecording() : startRecording()
            } label: {
                Text(currentLabel)
                    .font(.body.monospaced())
                    .frame(minWidth: 90)
            }
            .accessibilityIdentifier("settings-dictation-mouse-recorder")
            if button != MouseButtonSetting.off, !recording {
                Button {
                    button = MouseButtonSetting.off
                    MouseButtonSetting.save(button)
                    onChange()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.text("Remove the push-to-talk mouse button"))
                .accessibilityIdentifier("settings-dictation-mouse-clear")
            }
        }
    }

    private var currentLabel: String {
        if recording { return L10n.text("Click a mouse button…") }
        if button == MouseButtonSetting.off { return L10n.text("Off") }
        return MouseButtonSetting.label(for: button)
    }

    private func startRecording() {
        recording = true
        let mouse = NSEvent.addLocalMonitorForEvents(matching: .otherMouseDown) { event in
            defer { stopRecording() }
            let candidate = event.buttonNumber
            guard MouseButtonSetting.isEligible(candidate) else {
                NSSound.beep()
                return nil
            }
            button = candidate
            MouseButtonSetting.save(candidate)
            onChange()
            return nil
        }
        let keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == UInt16(kVK_Escape) else { return event }
            stopRecording()
            return nil
        }
        monitors = [mouse, keys].compactMap { $0 }
    }

    private func stopRecording() {
        recording = false
        for monitor in monitors {
            NSEvent.removeMonitor(monitor)
        }
        monitors = []
    }
}
