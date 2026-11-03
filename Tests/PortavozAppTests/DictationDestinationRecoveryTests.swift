import AppKit
import PortavozCore
import TranscriptionKit
import XCTest

@testable import portavoz_app

@MainActor
final class DictationDestinationRecoveryTests: XCTestCase {
    func testControllerCapturesOnceAndKeepsOriginalDestinationAcrossRecovery() async {
        for text in ["Don’t delete 0.5", "No borres estas notas sin revisar"] {
            let harness = DictationControllerHarness(text: text)
            defer { harness.controller.cancel() }
            harness.set(false, forKey: DictationController.fillerFilterKey)
            var current = 1
            var captures = 0
            var deliveries: [Int] = []
            var dependencies = harness.dependencies
            dependencies.captureDestination = {
                captures += 1
                let original = current
                return CapturedDictationDestination(name: "Original app", canRetry: true) { _ in
                    guard current == original else { return .refused(.targetChanged) }
                    deliveries.append(original)
                    return .dispatched
                }
            }
            harness.controller.toggle(using: dependencies)
            XCTAssertEqual(captures, 1, "Capture must happen before asynchronous model preparation")
            let partial = await eventually { harness.controller.partialText == text }
            XCTAssertTrue(partial)
            current = 2
            harness.now = harness.now.addingTimeInterval(1)
            harness.controller.toggle(using: dependencies)
            let retained = await eventually { harness.controller.phase == .recovery(.targetChanged) }
            XCTAssertTrue(retained)
            XCTAssertEqual(harness.controller.recoveryText, text)
            XCTAssertTrue(deliveries.isEmpty)
            let released = await eventually { harness.finishes == 1 }
            XCTAssertTrue(released, "An undelivered result must not retain the model lease")

            harness.controller.toggle(using: dependencies)
            XCTAssertEqual(harness.loads, 1, "Another trigger cannot replace undelivered words")
            harness.controller.retryUndeliveredText()
            let refused = await eventually { !harness.controller.isRetryingDelivery }
            XCTAssertTrue(refused)
            XCTAssertEqual(harness.controller.recoveryText, text)
            XCTAssertTrue(deliveries.isEmpty)
            XCTAssertEqual(captures, 1, "Retry must never capture the new frontmost application")

            current = 1
            harness.controller.retryUndeliveredText()
            let sent = await eventually { !deliveries.isEmpty }
            XCTAssertTrue(sent)
            XCTAssertEqual(deliveries, [1])
            XCTAssertEqual(captures, 1)
        }
    }

    func testFullOutputSurvivesFailedCopyAndRemainsUntilExplicitDiscard() async {
        let text = (1...80).map { "Section \($0): café 0,5." }.joined(separator: " ")
        let harness = DictationControllerHarness(text: text)
        defer { harness.controller.cancel() }
        harness.set(false, forKey: DictationController.fillerFilterKey)
        let board = NSPasteboard(name: .init("app.portavoz.dictation-test." + UUID().uuidString))
        defer { board.releaseGlobally() }
        var copies = 0
        var dependencies = harness.dependencies
        dependencies.captureDestination = { .unavailable(name: nil, result: .focusUnavailable) }
        dependencies.copyText = {
            copies += 1
            return copies > 1 && TextInserter.copy($0, to: board)
        }
        await enterRecovery(harness, dependencies: dependencies)
        XCTAssertFalse(harness.controller.canRetryDelivery)
        harness.controller.copyPendingText()
        XCTAssertEqual(harness.controller.copyStatus, .failed)
        XCTAssertEqual(harness.controller.recoveryText, text)
        harness.controller.copyPendingText()
        XCTAssertEqual(harness.controller.copyStatus, .copied)
        XCTAssertEqual(board.string(forType: .string), text, "Copy must not use the panel's truncated excerpt")
        XCTAssertEqual(harness.controller.recoveryText, text)
        harness.controller.cancel()
        XCTAssertEqual(harness.controller.phase, .idle)
        XCTAssertTrue(harness.controller.recoveryText.isEmpty)
        XCTAssertTrue(harness.controller.confirmedText.isEmpty)
        XCTAssertTrue(harness.controller.partialText.isEmpty)
        XCTAssertNil(harness.controller.targetApp)
    }

    func testControllerFailedCopyKeepsTheOutputAndNeverWritesAfterAnotherWriter() async {
        // Recovery Copy is an explicit user Copy: it replaces the clipboard and
        // does not snapshot or restore it. A failed write keeps the output.
        for anotherWriterTakesOver in [false, true] {
            let harness = DictationControllerHarness(text: "No borres — don't delete")
            defer { harness.controller.cancel() }
            let board = NSPasteboard(name: .init("app.portavoz.dictation-test." + UUID().uuidString))
            defer { board.releaseGlobally() }
            let richText = Data("{\\rtf1 original}".utf8)
            board.declareTypes([.string, .rtf], owner: nil)
            XCTAssertTrue(board.setString("Original", forType: .string))
            XCTAssertTrue(board.setData(richText, forType: .rtf))
            XCTAssertFalse(TextInserter.copy("", to: board))
            XCTAssertEqual(board.data(forType: .rtf), richText, "Empty text never touches the clipboard")

            var dependencies = harness.dependencies
            dependencies.captureDestination = { .unavailable(name: nil, result: .focusUnavailable) }
            dependencies.copyText = { text in
                TextInserter.copy(text, to: board) { pasteboard, _ in
                    if anotherWriterTakesOver {
                        pasteboard.declareTypes([.string], owner: nil)
                        _ = pasteboard.setString("Another writer", forType: .string)
                    }
                    return false
                }
            }
            await enterRecovery(harness, dependencies: dependencies)
            harness.controller.copyPendingText()
            XCTAssertEqual(harness.controller.copyStatus, .failed)
            XCTAssertEqual(harness.controller.recoveryText, "No borres — don't delete")
            if anotherWriterTakesOver {
                XCTAssertEqual(board.string(forType: .string), "Another writer")
            }
        }
    }

    func testDuplicateRetryAndLateResultCannotReviveDiscardedOutput() async {
        let harness = DictationControllerHarness(text: "No borres — don't delete")
        defer { harness.controller.cancel() }
        let gate = RetryGate()
        var attempts = 0
        var dependencies = harness.dependencies
        dependencies.captureDestination = {
            CapturedDictationDestination(name: "Original app", canRetry: true) { _ in
                attempts += 1
                if attempts == 1 { return .refused(.targetChanged) }
                await gate.wait()
                return .dispatched // A deliberately uncooperative late result, not a native effect.
            }
        }
        await enterRecovery(harness, dependencies: dependencies)
        harness.controller.retryUndeliveredText()
        harness.controller.retryUndeliveredText()
        let waiting = await eventually { gate.started }
        XCTAssertTrue(waiting)
        XCTAssertEqual(attempts, 2, "One automatic attempt and exactly one explicit retry")
        let retiring = harness.controller.retryDeliveryTask
        XCTAssertNotNil(retiring)
        harness.controller.cancel()
        gate.release()
        await retiring?.value
        XCTAssertTrue(gate.returned)
        XCTAssertEqual(harness.controller.phase, .idle)
        XCTAssertTrue(harness.controller.recoveryText.isEmpty)
        XCTAssertFalse(harness.controller.isRetryingDelivery)
    }

    func testRecoveryFreezesFinalRulesAcrossCopyAndRepeatedRetry() async {
        for phrase in ["um alpha don’t delete 0.5", "eh alpha no borres 0,5"] {
            let harness = DictationControllerHarness(text: phrase)
            defer { harness.controller.cancel() }
            harness.set(true, forKey: DictationController.fillerFilterKey)
            harness.set(DictationTextRules.encode([
                .init(trigger: "alpha", replacement: "beta"),
                .init(trigger: "beta", replacement: "gamma"),
            ]), forKey: DictationController.replacementsKey)
            let expected = phrase.replacingOccurrences(of: "um ", with: "")
                .replacingOccurrences(of: "eh ", with: "")
                .replacingOccurrences(of: "alpha", with: "beta")
            var delivered: [String] = []
            var copied: [String] = []
            var dependencies = harness.dependencies
            dependencies.captureDestination = {
                CapturedDictationDestination(name: "Original app", canRetry: true) { text in
                    delivered.append(text)
                    return .refused(.targetChanged)
                }
            }
            dependencies.copyText = { copied.append($0); return true }
            await enterRecovery(harness, dependencies: dependencies)
            XCTAssertEqual(harness.controller.recoveryText, expected)
            // Changing preferences while recovering cannot rewrite already
            // offered output, nor may retry run non-cascading rules a second time.
            harness.set(DictationTextRules.encode([
                .init(trigger: "beta", replacement: "changed after delivery"),
            ]), forKey: DictationController.replacementsKey)
            harness.controller.copyPendingText()
            for _ in 0..<2 {
                harness.controller.retryUndeliveredText()
                await harness.controller.retryDeliveryTask?.value
            }
            XCTAssertEqual(copied, [expected])
            XCTAssertEqual(delivered, [expected, expected, expected])
            XCTAssertEqual(harness.loads, 1, "Recovery must not reopen the model or capture pipeline")
            XCTAssertEqual(harness.controller.recoveryText, expected)
        }
    }

    func testLateRecoveryFeedbackCannotCloseTheNextLanguageSession() async {
        for texts in [["No borres estas notas.", "Don’t delete these notes."],
                      ["Don’t delete these notes.", "No borres estas notas."]] {
            let first = DictationControllerHarness(text: texts[0])
            let next = DictationControllerHarness(text: texts[1], controller: first.controller)
            let feedback = RetryGate()
            defer { first.controller.cancel(); feedback.release() }
            var attempts = 0
            var captures = 0
            var dependencies = first.dependencies
            dependencies.captureDestination = {
                captures += 1
                return CapturedDictationDestination(name: "Original app", canRetry: true) { _ in
                    attempts += 1
                    return attempts == 1 ? .refused(.targetChanged) : .verified
                }
            }
            dependencies.waitForFeedbackDismissal = { _ in await feedback.wait() }
            await enterRecovery(first, dependencies: dependencies)
            first.controller.retryUndeliveredText()
            let waiting = await eventually { feedback.started && first.controller.retryDeliveryTask == nil }
            XCTAssertTrue(waiting, "Delivery must finish independently from cosmetic feedback")
            XCTAssertEqual(first.controller.phase, .verified(4))
            let released = await eventually { first.finishes == 1 }
            XCTAssertTrue(released, "Recovery feedback cannot retain the transcription lease")
            XCTAssertEqual(captures, 1)
            XCTAssertEqual(attempts, 2)

            first.controller.toggle(using: next.dependencies)
            let listening = await eventually { first.controller.partialText == texts[1] }
            XCTAssertTrue(listening)
            feedback.release() // Deliberately ignores the old task's cancellation.
            let finished = await eventually { feedback.returned }
            XCTAssertTrue(finished)
            XCTAssertEqual(first.controller.phase, .listening)
            XCTAssertEqual(first.controller.partialText, texts[1])
            XCTAssertTrue(next.insertions.isEmpty)
            XCTAssertEqual(captures, 1, "A late deadline must not recapture the old destination")
        }
    }

    private func enterRecovery(_ harness: DictationControllerHarness, dependencies: DictationSessionDependencies) async {
        harness.controller.toggle(using: dependencies)
        let partial = await eventually { !harness.controller.partialText.isEmpty }
        XCTAssertTrue(partial)
        harness.now = harness.now.addingTimeInterval(1)
        harness.controller.toggle(using: dependencies)
        let retained = await eventually {
            if case .recovery = harness.controller.phase { return true }
            return false
        }
        XCTAssertTrue(retained)
    }

    private func eventually(_ predicate: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while !predicate(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
        return predicate()
    }

    @MainActor
    private final class RetryGate {
        var started = false
        var returned = false
        private var continuation: CheckedContinuation<Void, Never>?

        func wait() async {
            started = true
            await withCheckedContinuation { continuation = $0 }
            returned = true
        }

        func release() { continuation?.resume(); continuation = nil }
    }
}
