import Foundation
import XCTest

@testable import portavoz_app

@MainActor
extension DictationControllerTests {
    func testAPauseEndsOnlyATapStartedDictation() async {
        for text in ["Envía el informe.", "Send the report."] {
            let harness = DictationControllerHarness(text: text)
            defer { harness.controller.cancel() }
            var reportPause: (@Sendable () -> Void)?
            var dependencies = harness.dependencies
            dependencies.makePauseDetector = { onPause in
                reportPause = onPause
                return nil
            }

            harness.controller.handleHotkeyPress(using: dependencies, at: harness.now)
            let held = await awaitEventually { harness.controller.partialText == text }
            XCTAssertTrue(held)
            harness.now = harness.now.addingTimeInterval(1)
            reportPause?()
            // Longer than the stop tail a wrongful finish would take to deliver.
            try? await Task.sleep(for: .milliseconds(600))
            XCTAssertTrue(harness.insertions.isEmpty, "a held hotkey owns the stop")
            harness.controller.handleHotkeyRelease(at: harness.now.addingTimeInterval(1))
            let released = await awaitEventually { harness.insertions == [text] }
            XCTAssertTrue(released)

            harness.controller.toggle(using: dependencies)
            let tapped = await awaitEventually { harness.controller.partialText == text }
            XCTAssertTrue(tapped)
            harness.now = harness.now.addingTimeInterval(3)
            reportPause?()
            let stopped = await awaitEventually { harness.insertions == [text, text] }
            XCTAssertTrue(stopped, "a tap-started dictation stops itself after the pause")
        }
    }

    func testAPauseNeverEndsADictationAHeldModifierOwns() async {
        let text = "Send the report."
        let harness = DictationControllerHarness(text: text)
        defer { harness.controller.cancel() }
        var reportPause: (@Sendable () -> Void)?
        var dependencies = harness.dependencies
        dependencies.makePauseDetector = { onPause in
            reportPause = onPause
            return nil
        }
        harness.controller.toggle(using: dependencies)
        let listening = await awaitEventually { harness.controller.partialText == text }
        XCTAssertTrue(listening)
        harness.controller.modifierTrigger.ownsSession = true
        harness.now = harness.now.addingTimeInterval(3)
        reportPause?()
        // Longer than the stop tail a wrongful finish would take to deliver.
        try? await Task.sleep(for: .milliseconds(600))
        XCTAssertTrue(harness.insertions.isEmpty, "the held key owns the stop")
    }
}
