import Foundation
import XCTest

@testable import portavoz_app

@MainActor
extension DictationControllerTests {
    func testAHeldKeyControlsOnlyTheDictationItStarted() async {
        for text in ["Envía el informe.", "Send the report."] {
            let harness = DictationControllerHarness(text: text)
            defer { harness.controller.cancel() }
            let start = { harness.controller.toggle(using: harness.dependencies) }

            start()
            let tapped = await awaitEventually { harness.controller.partialText == text }
            XCTAssertTrue(tapped)
            harness.now = harness.now.addingTimeInterval(1)
            harness.controller.handleModifier(.press, start: start)
            harness.controller.handleModifier(.release, start: start)
            try? await Task.sleep(for: .milliseconds(600))
            XCTAssertTrue(harness.insertions.isEmpty, "Fn during a tap-started dictation leaves it running")
            XCTAssertTrue(harness.controller.isActive)

            let owned = DictationControllerHarness(text: text)
            defer { owned.controller.cancel() }
            let startOwned = { owned.controller.toggle(using: owned.dependencies) }
            owned.controller.handleModifier(.press, start: startOwned)
            let held = await awaitEventually { owned.controller.partialText == text }
            XCTAssertTrue(held)
            owned.now = owned.now.addingTimeInterval(1)
            owned.controller.handleModifier(.release, start: startOwned)
            let delivered = await awaitEventually { owned.insertions == [text] }
            XCTAssertTrue(delivered, "releasing the key that started the dictation delivers it")
        }
    }
}
