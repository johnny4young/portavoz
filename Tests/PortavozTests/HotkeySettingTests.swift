import AppKit
import Carbon.HIToolbox
import Foundation
import XCTest

@testable import portavoz_app

final class HotkeySettingTests: XCTestCase {
    private let valid: [String: Any] = [
        HotkeySetting.keyCodeKey: Int(kVK_ANSI_M),
        HotkeySetting.modifiersKey: Int(cmdKey | optionKey),
        HotkeySetting.labelKey: "⌥⌘M",
    ]

    func testStoredBareKeyFallsBackInsteadOfHijackingTyping() {
        let defaults = preferences([HotkeySetting.modifiersKey: 0])
        XCTAssertEqual(HotkeySetting.load(from: defaults), .default)
    }

    func testMalformedPreferenceTypesAndIntegerBoundariesNeverTrapOrCoerce() {
        let invalid: [(String, Any)] = [
            (HotkeySetting.keyCodeKey, -1), (HotkeySetting.keyCodeKey, Int.max),
            (HotkeySetting.keyCodeKey, UInt64.max), (HotkeySetting.keyCodeKey, Int(UInt16.max) + 1),
            (HotkeySetting.keyCodeKey, 46.5), (HotkeySetting.keyCodeKey, true),
            (HotkeySetting.keyCodeKey, "46"), (HotkeySetting.keyCodeKey, [46]),
            (HotkeySetting.modifiersKey, -1), (HotkeySetting.modifiersKey, UInt64.max),
            (HotkeySetting.modifiersKey, 1 << 30), (HotkeySetting.modifiersKey, Int(controlKey)),
            (HotkeySetting.modifiersKey, 2304.5), (HotkeySetting.modifiersKey, false),
            (HotkeySetting.modifiersKey, "2304"), (HotkeySetting.labelKey, ""),
            (HotkeySetting.labelKey, "\n"), (HotkeySetting.labelKey, "⌘\0M"),
            (HotkeySetting.labelKey, String(repeating: "é", count: 65)),
            (HotkeySetting.labelKey, ["⌥⌘M"]), (HotkeySetting.labelKey, 23),
        ]
        for (key, value) in invalid {
            let restored = HotkeySetting.restore(from: preferences([key: value]))
            XCTAssertEqual(restored.setting, .default, "\(key): \(value)")
            XCTAssertTrue(restored.usedFallback, "\(key): \(value)")
        }
    }

    func testAbsentDefaultsDifferFromIncompleteSavedCombinationAndDoNotWrite() {
        let defaults = UserDefaults(suiteName: "hotkey-tests-\(UUID().uuidString)")!
        defaults.setVolatileDomain([:], forName: UserDefaults.argumentDomain)
        XCTAssertFalse(HotkeySetting.restore(from: defaults).usedFallback)
        let incomplete = [HotkeySetting.keyCodeKey: -1]
        defaults.setVolatileDomain(incomplete, forName: UserDefaults.argumentDomain)
        XCTAssertTrue(HotkeySetting.restore(from: defaults).usedFallback)
        XCTAssertEqual(defaults.volatileDomain(forName: UserDefaults.argumentDomain) as? [String: Int], incomplete)
    }

    func testExistingConfiguredKeysAndUnicodeLabelsSurviveRestoration() {
        for (code, modifiers, label) in [
            (Int(kVK_ANSI_M), Int(cmdKey | optionKey), "⌥⌘M"),
            (Int(kVK_ANSI_A), Int(optionKey), "⌥Á"),
            (Int(kVK_ANSI_N), Int(cmdKey | controlKey | shiftKey), "⌃⇧⌘Ñ"),
        ] {
            let restored = HotkeySetting.restore(from: preferences([
                HotkeySetting.keyCodeKey: code, HotkeySetting.modifiersKey: modifiers,
                HotkeySetting.labelKey: label,
            ]))
            XCTAssertFalse(restored.usedFallback)
            XCTAssertEqual(restored.setting, HotkeySetting(keyCode: UInt32(code), modifiers: UInt32(modifiers), label: label))
        }
    }

    @MainActor
    func testRecorderControlKeysRoundTripWithoutBecomingCorruptPreferences() async throws {
        for (code, characters, label) in [
            (kVK_Return, "\r", "⌘↩"), (kVK_Tab, "\t", "⌘⇥"),
            (kVK_Delete, "\u{7f}", "⌘⌫"), (kVK_F1, "\u{f704}", "⌘F1"),
        ] {
            let event = try XCTUnwrap(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: .command,
                timestamp: 0, windowNumber: 0, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: UInt16(code)))
            let setting = try XCTUnwrap(HotkeySetting.from(event: event))
            XCTAssertEqual(setting.label, label)
            let restored = HotkeySetting.restore(from: preferences([
                HotkeySetting.keyCodeKey: code, HotkeySetting.modifiersKey: Int(cmdKey),
                HotkeySetting.labelKey: "⌘" + characters,
            ]))
            XCTAssertFalse(restored.usedFallback)
            XCTAssertEqual(restored.setting, setting)
        }
    }

    func testExplicitSaveSupersedesOnlyOwnedStartupOverrides() {
        let suite = "hotkey-save-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.setVolatileDomain([
            HotkeySetting.keyCodeKey: -1, HotkeySetting.modifiersKey: 0,
            HotkeySetting.labelKey: "invalid", "unrelatedPreference": "kept",
        ], forName: UserDefaults.argumentDomain)
        HotkeySetting.default.save(to: defaults)
        XCTAssertEqual(HotkeySetting.load(from: defaults), .default)
        XCTAssertFalse(HotkeySetting.restore(from: defaults).usedFallback)
        XCTAssertEqual(defaults.string(forKey: "unrelatedPreference"), "kept")
        XCTAssertEqual(defaults.volatileDomain(forName: UserDefaults.argumentDomain).count, 1)
        XCTAssertEqual(defaults.persistentDomain(forName: suite)?[HotkeySetting.keyCodeKey] as? Int, Int(kVK_ANSI_D))
    }

    private func preferences(_ overrides: [String: Any]) -> UserDefaults {
        let defaults = UserDefaults(suiteName: "hotkey-tests-\(UUID().uuidString)")!
        defaults.setVolatileDomain(valid.merging(overrides) { _, new in new }, forName: UserDefaults.argumentDomain)
        return defaults
    }
}
