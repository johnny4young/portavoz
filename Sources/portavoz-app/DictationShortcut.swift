import Foundation
import Observation

@MainActor
protocol GlobalHotkeyRegistration: AnyObject {
    func unregister()
}

/// Owns one keyboard registration, not the dictation session. Availability is
/// observable so a rejected Carbon binding cannot leave a silent dead shortcut.
@MainActor
@Observable
final class DictationShortcut {
    enum Availability: Equatable {
        case disabled
        case inactive
        case registered
        case unavailable
    }

    typealias Registrar = @MainActor (
        HotkeySetting, @escaping () -> Void, @escaping () -> Void
    ) -> (any GlobalHotkeyRegistration)?

    private(set) var setting = HotkeySetting.default
    private(set) var usedFallback = false
    private(set) var availability = Availability.disabled
    @ObservationIgnored private var registration: (any GlobalHotkeyRegistration)?
    @ObservationIgnored private var generation: UUID?

    static let liveRegistrar: Registrar = { setting, press, release in
        GlobalHotkey(
            keyCode: setting.keyCode, modifiers: setting.modifiers,
            onPress: press, onRelease: release)
    }

    func sync(
        defaults: UserDefaults = .standard,
        registrar: Registrar?,
        onPress: @escaping () -> Void,
        onRelease: @escaping () -> Void
    ) {
        generation = nil
        registration?.unregister()
        registration = nil
        let restored = HotkeySetting.restore(from: defaults)
        setting = restored.setting
        usedFallback = restored.usedFallback
        guard defaults.bool(forKey: DictationController.defaultsKey) else {
            availability = .disabled
            return
        }
        guard let registrar else {
            availability = .inactive
            return
        }
        let generation = UUID()
        self.generation = generation
        availability = .unavailable
        registration = registrar(setting, { [weak self] in
            guard self?.generation == generation, self?.availability == .registered else { return }
            onPress()
        }, { [weak self] in
            guard self?.generation == generation, self?.availability == .registered else { return }
            onRelease()
        })
        availability = registration == nil ? .unavailable : .registered
    }

    func useDefault(in defaults: UserDefaults = .standard) {
        HotkeySetting.default.save(to: defaults)
    }
}
