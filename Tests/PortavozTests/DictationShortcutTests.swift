import Carbon.HIToolbox
import Foundation
import XCTest

@testable import portavoz_app

@MainActor
final class DictationShortcutTests: XCTestCase {
    func testFailedRegistrationRecoversOnlyWhenRetriedAndCannotDispatch() async {
        let defaults = preferences()
        let shortcut = DictationShortcut()
        let host = RegistrationHost()
        host.failNext = true
        var presses = 0
        var releases = 0
        shortcut.sync(defaults: defaults, registrar: host.register,
                      onPress: { presses += 1 }, onRelease: { releases += 1 })
        XCTAssertEqual(shortcut.availability, .unavailable)
        host.callbacks[0].0()
        host.callbacks[0].1()
        XCTAssertEqual(presses, 0)
        XCTAssertEqual(releases, 0)
        XCTAssertEqual(host.settings.count, 1)

        shortcut.sync(defaults: defaults, registrar: host.register,
                      onPress: { presses += 1 }, onRelease: { releases += 1 })
        XCTAssertEqual(shortcut.availability, .registered)
        host.callbacks[0].0()
        XCTAssertEqual(presses, 0, "a delayed callback from the failed attempt cannot start capture")
        host.callbacks[1].0()
        host.callbacks[1].1()
        XCTAssertEqual(presses, 1)
        XCTAssertEqual(releases, 1)
    }

    func testRebindAndDisableReleaseExactHandlesAndRejectOldCallbacks() async {
        let defaults = preferences()
        let shortcut = DictationShortcut()
        let host = RegistrationHost()
        var presses = 0
        shortcut.sync(defaults: defaults, registrar: host.register, onPress: { presses += 1 }, onRelease: {})
        defaults.setVolatileDomain([
            DictationController.defaultsKey: true,
            HotkeySetting.keyCodeKey: Int(kVK_ANSI_M),
            HotkeySetting.modifiersKey: Int(cmdKey | optionKey),
            HotkeySetting.labelKey: "⌥⌘M",
        ], forName: UserDefaults.argumentDomain)
        shortcut.sync(defaults: defaults, registrar: host.register, onPress: { presses += 1 }, onRelease: {})
        XCTAssertEqual(host.handles[0].unregistrations, 1)
        XCTAssertEqual(shortcut.setting.label, "⌥⌘M")
        host.callbacks[0].0()
        host.callbacks[1].0()
        XCTAssertEqual(presses, 1)

        defaults.setVolatileDomain([DictationController.defaultsKey: false], forName: UserDefaults.argumentDomain)
        for _ in 0..<2 {
            shortcut.sync(defaults: defaults, registrar: host.register, onPress: { presses += 1 }, onRelease: {})
        }
        XCTAssertEqual(shortcut.availability, .disabled)
        XCTAssertEqual(host.handles[1].unregistrations, 1)
        XCTAssertEqual(host.settings.count, 2)
        host.callbacks[1].0()
        XCTAssertEqual(presses, 1)
    }

    func testNoRegistrarKeepsTemporaryCompositionInert() async {
        let shortcut = DictationShortcut()
        shortcut.sync(defaults: preferences(), registrar: nil, onPress: { XCTFail("unexpected input") }, onRelease: {})
        XCTAssertEqual(shortcut.availability, .inactive)
        XCTAssertEqual(shortcut.setting, .default)
        XCTAssertNil(DictationShortcutUITestFixture(
            arguments: ["-seed-dictation-shortcut-conflict"], usesTemporaryStore: false))
        XCTAssertNil(DictationShortcutUITestFixture(arguments: [], usesTemporaryStore: true))
    }

    func testCorruptPreferencesReachRegistrarAsSafeDefaults() async {
        let defaults = preferences()
        defaults.setVolatileDomain([
            DictationController.defaultsKey: true, HotkeySetting.keyCodeKey: -1,
        ], forName: UserDefaults.argumentDomain)
        let shortcut = DictationShortcut()
        let host = RegistrationHost()
        shortcut.sync(defaults: defaults, registrar: host.register, onPress: {}, onRelease: {})
        XCTAssertTrue(shortcut.usedFallback)
        XCTAssertEqual(host.settings, [.default])
    }

    private func preferences() -> UserDefaults {
        let defaults = UserDefaults(suiteName: "shortcut-tests-\(UUID().uuidString)")!
        defaults.setVolatileDomain([DictationController.defaultsKey: true], forName: UserDefaults.argumentDomain)
        return defaults
    }
}

@MainActor
private final class RegistrationHost {
    var failNext = false
    var settings: [HotkeySetting] = []
    var handles: [RegistrationHandle] = []
    var callbacks: [(() -> Void, () -> Void)] = []

    func register(_ setting: HotkeySetting, press: @escaping () -> Void, release: @escaping () -> Void)
        -> (any GlobalHotkeyRegistration)? {
        settings.append(setting)
        callbacks.append((press, release))
        if failNext {
            failNext = false
            return nil
        }
        let handle = RegistrationHandle()
        handles.append(handle)
        return handle
    }
}

@MainActor
private final class RegistrationHandle: GlobalHotkeyRegistration {
    var unregistrations = 0
    func unregister() { unregistrations += 1 }
}
