import PortavozCore
import XCTest

@testable import portavoz_app

@MainActor
final class DictationDeliveryOutcomeTests: XCTestCase {
    func testControllerUsesInserterObservationAndNeverRetriesDispatchedOutput() async {
        for supported in [false, true] {
            for text in ["Don’t delete 0.5", "No borres estas notas"] {
                let controller = DictationControllerHarness(text: text)
                let receiver = TextReadbackHarness()
                defer { controller.controller.cancel(); receiver.board.releaseGlobally() }
                controller.set(false, forKey: DictationController.fillerFilterKey)
                receiver.readbackAvailable = supported
                var dependencies = controller.dependencies
                dependencies.captureDestination = {
                    CapturedDictationDestination(name: "Test receiver", canRetry: true, insert: receiver.insert)
                }
                controller.controller.toggle(using: dependencies)
                let partial = await eventually { controller.controller.partialText == text }
                XCTAssertTrue(partial)
                controller.now = controller.now.addingTimeInterval(1)
                controller.controller.toggle(using: dependencies)
                let words = text.split(whereSeparator: \.isWhitespace).count
                let expected: DictationController.Phase = supported ? .verified(words) : .dispatched(words)
                let delivered = await eventually { controller.controller.phase == expected }
                XCTAssertTrue(delivered)
                XCTAssertEqual(receiver.posts, 1)
                XCTAssertTrue(controller.controller.recoveryText.isEmpty)
                controller.controller.retryUndeliveredText()
                XCTAssertNil(controller.controller.retryDeliveryTask)
                XCTAssertEqual(receiver.posts, 1, "Delivery observation must reach the controller, not a fake success")
                XCTAssertEqual(controller.finishes, 1)
            }
        }
    }

    func testRestartRetiresTheDeliveryTimerWithoutClosingTheNewCapture() async {
        let harness = DictationControllerHarness(text: "Do not remove the notes")
        defer { harness.controller.cancel() }
        harness.controller.toggle(using: harness.dependencies)
        let partial = await eventually { !harness.controller.partialText.isEmpty }
        XCTAssertTrue(partial)
        harness.now = harness.now.addingTimeInterval(1)
        harness.controller.toggle(using: harness.dependencies)
        let sent = await eventually { harness.controller.phase == .dispatched(5) }
        XCTAssertTrue(sent)
        XCTAssertEqual(harness.finishes, 1, "The banner must not own the completed runtime")
        let retiringTimer = harness.controller.dismissTask
        XCTAssertNotNil(retiringTimer)
        harness.controller.toggle(using: harness.dependencies)
        await retiringTimer?.value
        let restarted = await eventually { harness.loads == 2 && !harness.controller.partialText.isEmpty }
        XCTAssertTrue(restarted)
        XCTAssertEqual(harness.controller.phase, .listening)
        XCTAssertNil(harness.controller.dismissTask)
        XCTAssertEqual(harness.insertions.count, 1)
        harness.controller.cancel()
        let released = await eventually { harness.finishes == 2 }
        XCTAssertTrue(released)
        XCTAssertEqual(harness.controller.phase, .idle)
    }

    func testDeliveryFixtureCannotAcknowledgeOutsideExplicitTemporaryComposition() async {
        let arguments = ["-seed-dictation", "-seed-dictation-delivery", "-seed-dictation-verified"]
        XCTAssertNil(DictationUITestFixture(arguments: arguments, usesTemporaryStore: false))
        XCTAssertNil(DictationUITestFixture(arguments: Array(arguments.dropFirst()), usesTemporaryStore: true))
        XCTAssertFalse(DictationUITestFixture.dependencies(fixture: nil).canInsert())
        for verified in [false, true] {
            let flags = verified ? arguments : Array(arguments.dropLast())
            let fixture = DictationUITestFixture(arguments: flags, usesTemporaryStore: true)
            let destination = DictationUITestFixture.dependencies(fixture: fixture).captureDestination()
            let result = await destination.insert("Synthetic output")
            XCTAssertEqual(result, verified ? .verified : .dispatched)
        }
    }

    private func eventually(_ predicate: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while !predicate(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
        return predicate()
    }
}
