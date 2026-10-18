import AppKit
import Carbon.HIToolbox

/// A modifier held on its own as push-to-talk. Off by default.
enum ModifierKeySetting: String, CaseIterable {
    case off
    case function
    case rightOption
    case rightCommand

    static let defaultsKey = "dictationModifierKey"

    static func load(from defaults: UserDefaults = .standard) -> Self {
        Self(rawValue: defaults.string(forKey: defaultsKey) ?? "") ?? .off
    }

    var keyCode: Int64? {
        switch self {
        case .off: nil
        case .function: Int64(kVK_Function)
        case .rightOption: Int64(kVK_RightOption)
        case .rightCommand: Int64(kVK_RightCommand)
        }
    }

    /// Device-dependent bits keep the right-hand key apart from its left twin.
    var flag: UInt64 {
        switch self {
        case .off: 0
        case .function: CGEventFlags.maskSecondaryFn.rawValue
        case .rightOption: 0x40
        case .rightCommand: 0x10
        }
    }

    /// Another modifier already held means a shortcut, not dictation.
    func holdsOtherModifier(_ flags: UInt64) -> Bool {
        let own: CGEventFlags = switch self {
        case .off: []
        case .function: .maskSecondaryFn
        case .rightOption: .maskAlternate
        case .rightCommand: .maskCommand
        }
        let others = CGEventFlags([.maskCommand, .maskAlternate, .maskControl, .maskShift, .maskSecondaryFn])
            .subtracting(own)
        return flags & others.rawValue != 0
    }
}

/// Pure hold logic. A press starts only after `startDelay` with nothing else
/// typed, so Fn+arrow or ⌥+letter shortcuts never open dictation.
struct ModifierKeyGesture {
    enum Input: Equatable {
        case down
        case up
        case otherKey
        case delayElapsed
    }

    enum Output: Equatable {
        case scheduleStart
        case press
        case release
        case chord
    }

    static let startDelay: Duration = .milliseconds(200)

    /// Maps one tapped keyboard event to a gesture input.
    static func input(
        for type: CGEventType, keyCode: Int64, flags: UInt64, setting: ModifierKeySetting
    ) -> Input {
        guard type == .flagsChanged, keyCode == setting.keyCode else { return .otherKey }
        guard flags & setting.flag != 0 else { return .up }
        return setting.holdsOtherModifier(flags) ? .otherKey : .down
    }

    private enum State { case idle, pending, held, ignoredUntilUp }
    private var state = State.idle

    mutating func handle(_ input: Input) -> Output? {
        switch (state, input) {
        case (.idle, .down):
            state = .pending
            return .scheduleStart
        case (.pending, .delayElapsed):
            state = .held
            return .press
        case (.pending, .otherKey):
            state = .ignoredUntilUp
            return nil
        case (.held, .otherKey):
            state = .ignoredUntilUp
            return .chord
        case (.held, .up):
            state = .idle
            return .release
        case (_, .up):
            state = .idle
            return nil
        default:
            return nil
        }
    }
}

/// Watches one modifier through a session event tap. Every event passes
/// through untouched; it needs the Accessibility trust pasting already uses.
@MainActor
final class ModifierKeyPTT {
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private let setting: ModifierKeySetting
    private var gesture = ModifierKeyGesture()
    private var pendingStart: Task<Void, Never>?
    private let onPress: () -> Void
    private let onRelease: () -> Void
    private let onChord: () -> Void

    init?(
        setting: ModifierKeySetting,
        onPress: @escaping () -> Void,
        onRelease: @escaping () -> Void,
        onChord: @escaping () -> Void
    ) {
        guard setting.keyCode != nil else { return nil }
        self.setting = setting
        self.onPress = onPress
        self.onRelease = onRelease
        self.onChord = onChord

        let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let ptt = Unmanaged<ModifierKeyPTT>.fromOpaque(userInfo).takeUnretainedValue()
                let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
                let flags = event.flags.rawValue
                // Attached to the main run loop, so the callback is on the main thread.
                MainActor.assumeIsolated { ptt.handle(type: type, keyCode: keyCode, flags: flags) }
                return Unmanaged.passUnretained(event)
            },
            userInfo: selfPointer)
        else { return nil }

        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func handle(type: CGEventType, keyCode: Int64, flags: UInt64) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            // Events may have been lost while disabled: end any hold rather than
            // let a pending start or a missed release keep dictation listening.
            apply(.up)
            return
        }
        apply(ModifierKeyGesture.input(for: type, keyCode: keyCode, flags: flags, setting: setting))
    }

    private func apply(_ input: ModifierKeyGesture.Input) {
        switch gesture.handle(input) {
        case .scheduleStart:
            pendingStart = Task { @MainActor [weak self] in
                try? await Task.sleep(for: ModifierKeyGesture.startDelay)
                guard !Task.isCancelled else { return }
                self?.apply(.delayElapsed)
            }
        case .press:
            onPress()
        case .release:
            onRelease()
        case .chord:
            onChord()
        case nil:
            if input != .delayElapsed {
                pendingStart?.cancel()
                pendingStart = nil
            }
        }
    }

    func invalidate() {
        pendingStart?.cancel()
        pendingStart = nil
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            self.tap = nil
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
            self.runLoopSource = nil
        }
    }
}
