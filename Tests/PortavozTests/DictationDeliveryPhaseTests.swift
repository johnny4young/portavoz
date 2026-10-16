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

@MainActor
extension DictationControllerTests {
    func testEscapeIsClaimedOnlyWhileCapturingAndCancelsThatSession() async {
        for text in ["No borres estas notas.", "Don’t delete these notes."] {
            let harness = DictationControllerHarness(text: text)
            let keys = CancelKeyRecorder()
            defer { harness.controller.cancel() }
            var dependencies = harness.dependencies
            dependencies.registerCancelKey = keys.register

            harness.controller.toggle(using: dependencies)
            XCTAssertEqual(keys.active, 1, "Escape is claimed from preparation onward")
            let ready = await awaitEventually { harness.controller.partialText == text }
            XCTAssertTrue(ready)
            keys.press()
            let cancelled = await awaitEventually { harness.controller.phase == .idle }
            XCTAssertTrue(cancelled)
            XCTAssertEqual(keys.active, 0)
            XCTAssertTrue(harness.insertions.isEmpty)

            harness.controller.toggle(using: dependencies)
            let restarted = await awaitEventually { harness.controller.partialText == text }
            XCTAssertTrue(restarted)
            harness.now = harness.now.addingTimeInterval(1)
            harness.controller.toggle(using: dependencies)
            let delivered = await awaitEventually { harness.insertions == [text] }
            XCTAssertTrue(delivered)
            XCTAssertEqual(keys.active, 0, "Delivery returns Escape to the destination")
            keys.press()
            await Task.yield()
            XCTAssertEqual(harness.insertions, [text])
            XCTAssertNotEqual(harness.controller.phase, .idle, "A stale Escape cannot hide the outcome")
        }
    }
}

@MainActor
extension DictationControllerTests {
    func testEscapeQueuedDuringAnInFlightPasteCannotCancelIt() async {
        for text in ["No borres estas notas.", "Don’t delete these notes."] {
            let harness = DictationControllerHarness(text: text)
            let keys = CancelKeyRecorder()
            let paste = PreparationGate()
            defer { harness.controller.cancel(); paste.release() }
            var dependencies = harness.dependencies
            dependencies.registerCancelKey = keys.register
            dependencies.captureDestination = { [weak harness] in
                CapturedDictationDestination(name: "Slow receiver", canRetry: true) { value in
                    await paste.wait()
                    harness?.insertions.append(value)
                    return .dispatched
                }
            }
            harness.controller.toggle(using: dependencies)
            let ready = await awaitEventually { harness.controller.partialText == text }
            XCTAssertTrue(ready)
            harness.now = harness.now.addingTimeInterval(1)
            harness.controller.toggle(using: dependencies)
            let delivering = await awaitEventually { paste.started }
            XCTAssertTrue(delivering)
            XCTAssertEqual(keys.active, 0, "Escape returns to the destination before the paste")

            keys.press()
            for _ in 0..<5 { await Task.yield() }
            XCTAssertEqual(harness.controller.phase, .delivering)
            paste.release()
            let presented = await awaitEventually { harness.insertions == [text] }
            XCTAssertTrue(presented)
        }
    }
}

@MainActor
private final class CancelKeyRecorder {
    private final class Registration: GlobalHotkeyRegistration {
        let onPress: () -> Void
        var isRegistered = true
        init(onPress: @escaping () -> Void) { self.onPress = onPress }
        func unregister() { isRegistered = false }
    }

    private var registrations: [Registration] = []
    var active: Int { registrations.filter(\.isRegistered).count }

    func register(_ onPress: @escaping () -> Void) -> (any GlobalHotkeyRegistration)? {
        let registration = Registration(onPress: onPress)
        registrations.append(registration)
        return registration
    }

    /// Fires the latest callback even after release, like a Carbon event already queued.
    func press() { registrations.last?.onPress() }
}
