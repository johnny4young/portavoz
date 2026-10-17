import CoreGraphics
import Foundation
import XCTest

@testable import portavoz_app

final class ModifierKeyGestureTests: XCTestCase {
    func testHoldingAloneStartsAfterTheDelayAndReleaseDelivers() async {
        var gesture = ModifierKeyGesture()
        XCTAssertEqual(gesture.handle(.down), .scheduleStart)
        XCTAssertEqual(gesture.handle(.delayElapsed), .press)
        XCTAssertEqual(gesture.handle(.up), .release)
        XCTAssertEqual(gesture.handle(.down), .scheduleStart, "the next hold starts fresh")
    }

    func testShortcutsTypedWithTheKeyNeverDictate() async {
        var shortcut = ModifierKeyGesture()
        _ = shortcut.handle(.down)
        XCTAssertNil(shortcut.handle(.otherKey), "Fn+arrow before the delay opens nothing")
        XCTAssertNil(shortcut.handle(.delayElapsed), "a late timer cannot start it")
        XCTAssertNil(shortcut.handle(.up))

        var quickTap = ModifierKeyGesture()
        _ = quickTap.handle(.down)
        XCTAssertNil(quickTap.handle(.up))
        XCTAssertNil(quickTap.handle(.delayElapsed))

        var heldChord = ModifierKeyGesture()
        _ = heldChord.handle(.down)
        _ = heldChord.handle(.delayElapsed)
        XCTAssertEqual(heldChord.handle(.otherKey), .chord, "a shortcut after dictation began discards it")
        XCTAssertNil(heldChord.handle(.up), "its release must not deliver")
    }

    func testAnotherHeldModifierMeansAShortcutAndRightKeysStayApart() async throws {
        XCTAssertTrue(ModifierKeySetting.function.holdsOtherModifier(
            CGEventFlags([.maskSecondaryFn, .maskCommand]).rawValue))
        XCTAssertFalse(ModifierKeySetting.function.holdsOtherModifier(CGEventFlags.maskSecondaryFn.rawValue))
        XCTAssertFalse(ModifierKeySetting.rightOption.holdsOtherModifier(
            CGEventFlags.maskAlternate.rawValue | ModifierKeySetting.rightOption.flag))
        XCTAssertNotEqual(ModifierKeySetting.rightOption.flag, 0)
        XCTAssertNotEqual(ModifierKeySetting.rightOption.keyCode, ModifierKeySetting.rightCommand.keyCode)

        let suite = "modifier-key-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(ModifierKeySetting.load(from: defaults), .off, "the trigger is opt-in")
        defaults.set("capsLock", forKey: ModifierKeySetting.defaultsKey)
        XCTAssertEqual(ModifierKeySetting.load(from: defaults), .off)
        defaults.set("function", forKey: ModifierKeySetting.defaultsKey)
        XCTAssertEqual(ModifierKeySetting.load(from: defaults), .function)
    }
}
