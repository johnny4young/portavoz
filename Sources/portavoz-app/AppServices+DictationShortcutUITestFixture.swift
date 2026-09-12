import Foundation

extension AppServices {
    var dictationShortcutRegistrar: DictationShortcut.Registrar? {
        guard usesTemporaryMeetingStore else { return DictationShortcut.liveRegistrar }
        guard let dictationShortcutUITestFixture else { return nil }
        return { [dictationShortcutUITestFixture] _, _, _ in
            dictationShortcutUITestFixture.register()
        }
    }
}

/// A rejected registration followed by an explicit successful retry. It never
/// calls Carbon or claims native shortcut qualification for this test process.
@MainActor
final class DictationShortcutUITestFixture {
    private var attempts = 0

    init?(arguments: [String], usesTemporaryStore: Bool) {
        guard usesTemporaryStore, arguments.contains("-seed-dictation-shortcut-conflict") else { return nil }
    }

    func register() -> (any GlobalHotkeyRegistration)? {
        attempts += 1
        return attempts == 1 ? nil : InertRegistration()
    }
}

@MainActor
private final class InertRegistration: GlobalHotkeyRegistration {
    func unregister() {}
}
