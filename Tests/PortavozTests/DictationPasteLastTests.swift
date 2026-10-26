import AppKit
import Foundation
import os
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

    func testSleepOrLockForgetsTheText() {
        let last = DictationLastText()
        last.remember("Envía el informe.")
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
        XCTAssertNil(last.current, "sleep drops the remembered text")
    }

    func testSleepLockOrExpiryEndsPasteLastForRecoveryWordsButKeepsCopy() async {
        for forgets in ["sleep", "lock", "expiry"] {
            let text = "Send the report."
            var now = Date(timeIntervalSince1970: 1_000)
            let last = DictationLastText(now: { now }, observesSystem: forgets != "expiry")
            let harness = DictationControllerHarness(
                text: text, controller: DictationController(presentsPanel: false, lastText: last))
            defer { harness.controller.cancel() }
            var copies: [String] = []
            var refusing = harness.dependencies
            refusing.captureDestination = {
                CapturedDictationDestination(name: "Refusing receiver", canRetry: true) { _ in .refused(.cancelled) }
            }
            refusing.copyText = { copies.append($0); return true }
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

            if forgets == "sleep" {
                NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
            } else if forgets == "lock" {
                NSWorkspace.shared.notificationCenter.post(
                    name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
            } else {
                now += DictationLastText.lifetime + 1
            }
            XCTAssertFalse(harness.controller.hasPastableText, "\(forgets) ends Paste last for the waiting words")
            harness.controller.pasteLastDictation(using: harness.dependencies)
            for _ in 0..<5 { await Task.yield() }
            XCTAssertTrue(harness.insertions.isEmpty, "nothing is pasted after \(forgets)")
            XCTAssertEqual(harness.controller.recoveryText, text, "the panel still holds the words")
            harness.controller.copyPendingText()
            XCTAssertEqual(copies, [text], "Copy still works from the panel")
        }
    }

    func testRecoveryPastesWhereTheUserIsNowAndKeepsTheWordsIfRefusedAgain() async {
        let text = "Send the report."
        var now = Date(timeIntervalSince1970: 1_000)
        let last = DictationLastText(now: { now }, observesSystem: false)
        let harness = DictationControllerHarness(
            text: text, controller: DictationController(presentsPanel: false, lastText: last))
        defer { harness.controller.cancel() }
        let attempts = OSAllocatedUnfairLock(initialState: 0)
        var refusing = harness.dependencies
        refusing.captureDestination = {
            CapturedDictationDestination(name: "Refusing receiver", canRetry: true) { _ in
                attempts.withLock { $0 += 1 }
                return .refused(.cancelled)
            }
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
        now += DictationLastText.lifetime - 1
        XCTAssertTrue(harness.controller.hasPastableText, "the menu offers Paste last for the waiting words")
        harness.controller.pasteLastDictation(using: refusing)
        let stillWaiting = await awaitEventually {
            guard attempts.withLock({ $0 }) == 2, !harness.controller.isRetryingDelivery else { return false }
            if case .recovery = harness.controller.phase { return true }
            return false
        }
        XCTAssertTrue(stillWaiting, "a second refusal keeps the panel")
        XCTAssertEqual(harness.controller.recoveryText, text, "the words are never lost")

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
