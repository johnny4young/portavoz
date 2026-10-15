import Foundation
import XCTest
@testable import portavoz_app

@MainActor
extension DictationControllerTests {
    func testTriggersDuringAnInFlightPasteNeitherCancelNorRestartIt() async {
        for text in ["No borres estas notas.", "Don’t delete these notes."] {
            let harness = DictationControllerHarness(text: text)
            let paste = PreparationGate()
            defer { harness.controller.cancel(); paste.release() }
            var dependencies = harness.dependencies
            dependencies.captureDestination = { [weak harness] in
                CapturedDictationDestination(name: "Slow receiver", canRetry: true) { value in
                    await paste.wait()
                    harness?.insertions.append(value)
                    return .dispatched
                }
            }
            harness.controller.handleHotkeyPress(using: dependencies, at: harness.now)
            let ready = await awaitEventually { harness.controller.partialText == text }
            XCTAssertTrue(ready)
            harness.now = harness.now.addingTimeInterval(1)
            harness.controller.toggle(using: dependencies)
            let delivering = await awaitEventually { paste.started }
            XCTAssertTrue(delivering)
            XCTAssertEqual(harness.controller.phase, .delivering)
            XCTAssertTrue(harness.controller.isActive, "A paste in flight still owns the capture slot")
            XCTAssertFalse(harness.controller.canChangeTextMode)

            for _ in 0..<3 { harness.controller.toggle(using: dependencies) }
            harness.controller.handleHotkeyPress(using: dependencies, at: harness.now)
            harness.controller.handleHotkeyRelease(at: harness.now.addingTimeInterval(2))
            XCTAssertEqual(harness.controller.phase, .delivering)
            XCTAssertEqual(harness.loads, 1, "No trigger may start another session over the paste")

            paste.release()
            let words = text.split(whereSeparator: \.isWhitespace).count
            let presented = await awaitEventually { harness.controller.phase == .dispatched(words) }
            XCTAssertTrue(presented, "The outcome of the paste must still be reported")
            XCTAssertEqual(harness.insertions, [text])
        }
    }
}
