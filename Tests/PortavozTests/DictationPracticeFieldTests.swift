import AppKit
import PortavozCore
import XCTest

@testable import portavoz_app

@MainActor
final class DictationPracticeFieldTests: XCTestCase {
    func testDeliveryStaysWithTheFrontmostAppUnlessTheKeyWindowShowsTheField() async throws {
        let practice = DictationPracticeField()
        let holder = UUID()
        let base = try baseDependencies()

        for (shown, isKey, appIsActive) in [(false, false, true), (true, false, true), (true, true, false)] {
            if shown { practice.show(holder, isKey: isKey) } else { practice.hide(holder) }
            let routed = practice.route(base, appIsActive: appIsActive)
            XCTAssertFalse(routed.canInsert(), "shown \(shown), key \(isKey), active \(appIsActive)")
            XCTAssertEqual(routed.captureDestination().name, "Dictation test receiver")
        }

        practice.show(holder, isKey: true)
        let routed = practice.route(base, appIsActive: true)
        XCTAssertTrue(routed.canInsert(), "Practice needs no Accessibility")
        let destination = routed.captureDestination()
        XCTAssertFalse(destination.canRetry)
        let outcome = await destination.insert("Hola")
        XCTAssertEqual(outcome, .verified)
        XCTAssertEqual(practice.text, "Hola")
    }

    func testPracticeAppendsWordsRefusesEmptyTextAndForgetsWhenHidden() async {
        let practice = DictationPracticeField()
        let onboarding = UUID()
        let settings = UUID()
        practice.show(onboarding, isKey: true)
        practice.show(settings, isKey: false)

        XCTAssertEqual(practice.receive("  Primera frase. "), .verified)
        XCTAssertEqual(practice.receive("Second one."), .verified)
        XCTAssertEqual(practice.receive(" \n"), .refused(.emptyText))
        XCTAssertEqual(practice.text, "Primera frase. Second one.")

        practice.hide(onboarding)
        XCTAssertFalse(practice.isArmed, "A field behind another window never takes the shortcut")
        XCTAssertEqual(practice.text, "Primera frase. Second one.", "Another view still shows the words")
        practice.hide(settings)
        XCTAssertEqual(practice.text, "")
        XCTAssertEqual(practice.receive("Late words"), .refused(.targetChanged))
        XCTAssertEqual(practice.text, "")
    }

    func testRealControllerDeliversToThePracticeFieldWithoutTouchingTheClipboard() async throws {
        let controller = DictationController(presentsPanel: false)
        let services = try AppServices(
            arguments: ["-use-temp-store", "-seed-dictation", "-seed-dictation-delivery", "-seed-dictation-verified"],
            environment: [:], dictation: controller)
        let holder = UUID()
        services.dictationPractice.show(holder, isKey: true)
        defer { services.dictationPractice.hide(holder) }
        let clipboard = NSPasteboard.general.changeCount
        let dependencies = services.dictationPractice.route(
            services.makeDictationSessionDependencies(), appIsActive: true)

        controller.toggle(using: dependencies)
        let listening = await eventually { controller.partialText == "No borres estas notas." }
        XCTAssertTrue(listening)
        controller.toggle(using: dependencies)
        let delivered = await eventually { services.dictationPractice.text == "No borres estas notas." }

        XCTAssertTrue(delivered)
        XCTAssertEqual(controller.phase, .verified(4))
        XCTAssertEqual(controller.targetApp, L10n.text("the practice field"))
        XCTAssertEqual(NSPasteboard.general.changeCount, clipboard)
        controller.cancel()
    }

    private func baseDependencies() throws -> DictationSessionDependencies {
        let services = try AppServices(
            arguments: ["-use-temp-store"], environment: [:],
            dictation: DictationController(presentsPanel: false))
        var dependencies = services.makeDictationSessionDependencies()
        dependencies.canInsert = { false }
        return dependencies
    }

    private func eventually(_ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }
}
