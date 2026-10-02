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
                XCTAssertEqual(controller.controller.recoveryText, supported ? "" : text)
                controller.controller.retryUndeliveredText()
                XCTAssertNil(controller.controller.retryDeliveryTask)
                XCTAssertEqual(receiver.posts, 1, "Delivery observation must reach the controller, not a fake success")
                XCTAssertEqual(controller.finishes, 1)
            }
        }
    }

    func testUnacknowledgedOutputSurvivesFailedCopyAndAnotherTriggerWithoutResending() async {
        let longText = String(String(repeating: "café ñ 1,25 ", count: 1_500).prefix(16_384)) + "X"
        XCTAssertEqual(longText.utf16.count, 16_385)
        for text in ["Don’t remove 0.5 no punctuation", "No borres café C++ 1.250,50 €", longText] {
            let harness = DictationControllerHarness(text: text)
            let receiver = TextReadbackHarness()
            defer { harness.controller.cancel(); receiver.board.releaseGlobally() }
            harness.set(false, forKey: DictationController.fillerFilterKey)
            receiver.readbackAvailable = false
            receiver.appliesPaste = false
            var copies: [String] = []
            var dependencies = harness.dependencies
            dependencies.captureDestination = {
                CapturedDictationDestination(name: "Unsupported receiver", canRetry: true, insert: receiver.insert)
            }
            dependencies.copyText = { text in copies.append(text); return copies.count > 1 }
            var feedbackRequests = 0
            dependencies.waitForFeedbackDismissal = { _ in feedbackRequests += 1 }
            harness.controller.toggle(using: dependencies)
            let recognized = await eventually { harness.controller.partialText == text }
            XCTAssertTrue(recognized)
            harness.now = harness.now.addingTimeInterval(1)
            harness.controller.toggle(using: dependencies)
            let dispatched = await eventually { if case .dispatched = harness.controller.phase { true } else { false } }
            XCTAssertTrue(dispatched)
            XCTAssertEqual(harness.controller.recoveryText, text, "Posted does not mean received")
            await Task.yield()
            XCTAssertEqual(feedbackRequests, 0, "Unacknowledged output must not schedule an expiry")
            XCTAssertEqual(harness.controller.recoveryText, text)
            harness.controller.copyPendingText()
            XCTAssertEqual(harness.controller.copyStatus, .failed)
            XCTAssertEqual(harness.controller.recoveryText, text)
            harness.controller.copyPendingText()
            XCTAssertEqual(harness.controller.copyStatus, .copied)
            XCTAssertEqual(copies, [text, text], "Copy uses complete output, not the visible excerpt")
            harness.controller.retryUndeliveredText()
            harness.controller.toggle(using: dependencies)
            XCTAssertEqual(harness.controller.recoveryText, text)
            XCTAssertFalse(harness.controller.isActive)
            XCTAssertEqual(harness.loads, 1)
            XCTAssertEqual(receiver.posts, 1, "No implicit second paste or new capture")
            harness.controller.cancel()
            XCTAssertTrue(harness.controller.recoveryText.isEmpty)
            XCTAssertEqual(harness.controller.phase, .idle)
        }
    }

    func testRestartRetiresVerifiedFeedbackWithoutClosingTheNewCapture() async {
        let harness = DictationControllerHarness(text: "Do not remove the notes")
        let receiver = TextReadbackHarness()
        let feedback = DeliveryFeedbackGate()
        defer { harness.controller.cancel(); feedback.release(); receiver.board.releaseGlobally() }
        var dependencies = harness.dependencies
        dependencies.waitForFeedbackDismissal = { _ in await feedback.wait() }
        dependencies.captureDestination = {
            CapturedDictationDestination(name: "Disposable receiver", canRetry: true, insert: receiver.insert)
        }
        harness.controller.toggle(using: dependencies)
        let partial = await eventually { !harness.controller.partialText.isEmpty }
        XCTAssertTrue(partial)
        harness.now = harness.now.addingTimeInterval(1)
        harness.controller.toggle(using: dependencies)
        let sent = await eventually { harness.controller.phase == .verified(5) }
        XCTAssertTrue(sent)
        XCTAssertEqual(harness.finishes, 1, "The banner must not own the completed runtime")
        let waiting = await eventually { feedback.started }
        XCTAssertTrue(waiting)
        harness.controller.toggle(using: dependencies)
        feedback.release() // The old wait deliberately ignores cancellation.
        let returned = await eventually { feedback.returned }
        XCTAssertTrue(returned)
        let restarted = await eventually { harness.loads == 2 && !harness.controller.partialText.isEmpty }
        XCTAssertTrue(restarted)
        XCTAssertEqual(harness.controller.phase, .listening)
        XCTAssertEqual(receiver.posts, 1)
        harness.controller.cancel()
        let released = await eventually { harness.finishes == 2 }
        XCTAssertTrue(released)
        XCTAssertEqual(harness.controller.phase, .idle)
    }

    func testDeliveryFixtureCannotAcknowledgeOutsideExplicitTemporaryComposition() async {
        let arguments = ["-seed-dictation", "-seed-dictation-delivery", "-seed-dictation-verified"]
        XCTAssertNil(DictationUITestFixture(arguments: arguments, usesTemporaryStore: false))
        XCTAssertNil(DictationUITestFixture(arguments: Array(arguments.dropFirst()), usesTemporaryStore: true))
        let unavailable = DictationUITestFixture.dependencies(fixture: nil, beginCapture: { {} })
        XCTAssertFalse(unavailable.canInsert())
        for verified in [false, true] {
            let flags = verified ? arguments : Array(arguments.dropLast())
            let fixture = DictationUITestFixture(arguments: flags, usesTemporaryStore: true)
            let dependencies = DictationUITestFixture.dependencies(fixture: fixture, beginCapture: { {} })
            let destination = dependencies.captureDestination()
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

@MainActor
private final class DeliveryFeedbackGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var started = false
    private(set) var returned = false

    func wait() async {
        started = true
        await withCheckedContinuation { continuation = $0 }
        returned = true
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}
