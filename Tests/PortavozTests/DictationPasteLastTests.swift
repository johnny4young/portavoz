import AppKit
import Foundation
import XCTest

@testable import portavoz_app

@MainActor
extension DictationControllerTests {
    func testLastTextExpiresAndClearsWithoutTouchingDisk() async {
        var now = Date(timeIntervalSince1970: 1_000)
        let last = DictationLastText(now: { now }, observesSystem: false)
        XCTAssertNil(last.current)
        last.remember("Envía el informe.")
        now += DictationLastText.lifetime - 1
        XCTAssertEqual(last.current, "Envía el informe.")
        now += 2
        XCTAssertNil(last.current, "older than the lifetime is gone")
        last.remember("Send the report.")
        last.clear()
        XCTAssertNil(last.current)
    }

    func testTheLastDictationPastesAgainIntoTheCurrentDestination() async {
        for text in ["Envía el informe.", "Send the report."] {
            var now = Date(timeIntervalSince1970: 1_000)
            let last = DictationLastText(now: { now }, observesSystem: false)
            let harness = DictationControllerHarness(
                text: text, controller: DictationController(presentsPanel: false, lastText: last))
            defer { harness.controller.cancel() }
            harness.controller.pasteLastDictation(using: harness.dependencies)
            XCTAssertTrue(harness.insertions.isEmpty, "nothing to paste before a dictation")

            harness.controller.toggle(using: harness.dependencies)
            let ready = await awaitEventually { harness.controller.partialText == text }
            XCTAssertTrue(ready)
            harness.controller.pasteLastDictation(using: harness.dependencies)
            harness.now = harness.now.addingTimeInterval(1)
            harness.controller.toggle(using: harness.dependencies)
            let delivered = await awaitEventually { harness.insertions == [text] }
            XCTAssertTrue(delivered, "a paste request during capture is ignored")

            harness.controller.pasteLastDictation(using: harness.dependencies)
            let pasted = await awaitEventually { harness.insertions == [text, text] }
            XCTAssertTrue(pasted)

            now += DictationLastText.lifetime
            await Task.yield()
            harness.controller.pasteLastDictation(using: harness.dependencies)
            for _ in 0..<5 { await Task.yield() }
            XCTAssertEqual(harness.insertions, [text, text], "an expired dictation is never replayed")
        }
    }

    func testSleepOrLockForgetsTheTextAndRecoveryPastesWhereTheUserIsNow() async {
        let last = DictationLastText()
        last.remember("Envía el informe.")
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
        XCTAssertNil(last.current, "sleep drops the remembered text")

        let text = "Send the report."
        let harness = DictationControllerHarness(text: text)
        defer { harness.controller.cancel() }
        var refusing = harness.dependencies
        refusing.captureDestination = {
            CapturedDictationDestination(name: "Refusing receiver", canRetry: true) { _ in .refused(.cancelled) }
        }
        harness.controller.toggle(using: refusing)
        let ready = await awaitEventually { harness.controller.partialText == text }
        XCTAssertTrue(ready)
        harness.now = harness.now.addingTimeInterval(1)
        harness.controller.toggle(using: refusing)
        let refused = await awaitEventually {
            if case .recovery = harness.controller.phase { return true }
            return false
        }
        XCTAssertTrue(refused)
        harness.controller.pasteLastDictation(using: harness.dependencies)
        let pasted = await awaitEventually { harness.insertions == [text] }
        XCTAssertTrue(pasted, "the undelivered words paste into the field focused now")
        let closed = await awaitEventually {
            if case .recovery = harness.controller.phase { return false }
            return true
        }
        XCTAssertTrue(closed, "a successful paste closes the recovery panel")
    }
}
