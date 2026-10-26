import Foundation
import XCTest

@testable import portavoz_app

@MainActor
extension DictationControllerTests {
    func testNoSpeechVerdictOffersTheTextWithoutPasting() async {
        for text in ["No borres estas notas.", "Don’t delete these notes."] {
            let harness = DictationControllerHarness(text: text)
            defer { harness.controller.cancel() }
            var copied: [String] = []
            var dependencies = harness.dependencies
            dependencies.makeSpeechGate = { DictationSpeechGate { { _ in false } } }
            dependencies.copyText = { copied.append($0); return true }
            await dictateAndStop(harness, using: dependencies)

            let offered = await awaitEventually { harness.controller.phase == .noSpeech }
            XCTAssertTrue(offered)
            XCTAssertTrue(harness.insertions.isEmpty, "Silence is never pasted")
            XCTAssertEqual(harness.controller.recoveryText, text)
            XCTAssertEqual(harness.measurements.map(\.outcome), [.noSpeech])
            harness.controller.copyPendingText()
            XCTAssertEqual(copied, [text], "A missed speech can still be copied")

            harness.controller.toggle(using: dependencies)
            XCTAssertEqual(harness.controller.phase, .preparing, "The notice never blocks the next dictation")
        }
    }

    func testSpeechOrAnUndecidedGateKeepsTheOriginalDelivery() async {
        struct Unavailable: Error {}
        let gates: [() -> DictationSpeechGate?] = [
            { DictationSpeechGate { { _ in true } } },
            { DictationSpeechGate { throw Unavailable() } },
            { nil }
        ]
        for makeGate in gates {
            let harness = DictationControllerHarness(text: "No borres estas notas.")
            defer { harness.controller.cancel() }
            var dependencies = harness.dependencies
            dependencies.makeSpeechGate = makeGate
            await dictateAndStop(harness, using: dependencies)
            let delivered = await awaitEventually { harness.insertions == [harness.text] }
            XCTAssertTrue(delivered, "Only a confident no-speech verdict withholds the paste")
        }
    }

    private func dictateAndStop(
        _ harness: DictationControllerHarness, using dependencies: DictationSessionDependencies
    ) async {
        harness.controller.toggle(using: dependencies)
        let ready = await awaitEventually { harness.controller.partialText == harness.text }
        XCTAssertTrue(ready)
        harness.now = harness.now.addingTimeInterval(1)
        harness.controller.toggle(using: dependencies)
    }
}
