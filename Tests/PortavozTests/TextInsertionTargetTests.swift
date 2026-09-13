import AppKit
import ApplicationServices
import PortavozCore
import XCTest

@testable import portavoz_app

@MainActor
final class TextInsertionTargetTests: XCTestCase {
    func testFocusedElementBridgeRejectsWrongCoreFoundationType() async {
        let root = AXUIElementCreateSystemWide()
        let accepted: AXUIElement? = TextInserter.checkedCFValue(root, as: .accessibilityElement)
        let rejected: AXUIElement? = TextInserter.checkedCFValue("not an AX element" as CFString,
                                                                 as: .accessibilityElement)
        XCTAssertNotNil(accepted)
        XCTAssertNil(rejected)
    }

    func testProcessExitAtEachAdmissionBoundaryNeverPostsOrLosesClipboard() async {
        for exitAt in 1...3 {
            let board = makeBoard()
            defer { board.releaseGlobally() }
            let originalCount = board.changeCount
            var checks = 0
            let target = TextInserter.Target(processID: 101) { nil }
            let result = await TextInserter.insert(
                "No borres — don't delete", into: target, pasteboard: board,
                effects: .init(
                    waitForModifiers: { true },
                    post: { _ in XCTFail("An exited process received a paste event"); return true },
                    isProcessLive: { _ in
                        checks += 1
                        return checks < exitAt
                    }))
            XCTAssertEqual(result, .refused(.eventUnavailable))
            XCTAssertEqual(checks, exitAt)
            if exitAt < 3 { XCTAssertEqual(board.changeCount, originalCount) }
            XCTAssertEqual(board.string(forType: .string), "Original café")
            XCTAssertEqual(board.data(forType: .rtf), Data("{\\rtf1 Original}".utf8))
        }
    }

    func testChangedDestinationAfterModifierWaitNeverTouchesClipboard() async {
        let board = makeBoard()
        defer { board.releaseGlobally() }
        let originalCount = board.changeCount
        var isOriginal = true
        let target = TextInserter.Target(processID: 101) { isOriginal ? nil : .targetChanged }
        let result = await TextInserter.insert("No borres — don’t delete", into: target, pasteboard: board,
            effects: .init(waitForModifiers: { isOriginal = false; return true }, post: { _ in
                XCTFail("Changed focus reached native dispatch"); return true
            }))
        XCTAssertEqual(result, .refused(.targetChanged))
        XCTAssertEqual(board.changeCount, originalCount)
        XCTAssertEqual(board.string(forType: .string), "Original café")
    }

    func testFinalTargetCheckRestoresOwnedRichClipboardAndNeverDispatches() async {
        for failure: DictationDeliveryOutcome.Refusal in [.targetChanged, .secureField, .focusUnavailable] {
            let board = makeBoard()
            defer { board.releaseGlobally() }
            var checks = 0
            let target = TextInserter.Target(processID: 101) {
                checks += 1
                return checks == 1 ? nil : failure
            }
            let result = await TextInserter.insert("Don't send 1.250,50 €", into: target, pasteboard: board,
                effects: .init(waitForModifiers: { true }, post: { _ in
                    XCTFail("A changed final destination reached dispatch"); return true
                }))
            XCTAssertEqual(result, .refused(failure))
            XCTAssertEqual(checks, 2)
            XCTAssertEqual(board.string(forType: .string), "Original café")
            XCTAssertEqual(board.data(forType: .rtf), Data("{\\rtf1 Original}".utf8))
        }
    }

    func testCancellationInsideEitherValidationCannotPostAnEvent() async {
        for cancelAt in [1, 2] {
            let board = makeBoard()
            defer { board.releaseGlobally() }
            let originalCount = board.changeCount
            var checks = 0
            var job: Task<DictationDeliveryOutcome, Never>?
            let target = TextInserter.Target(processID: 101) {
                checks += 1
                if checks == cancelAt { job?.cancel() }
                return nil
            }
            job = Task {
                await TextInserter.insert("Cancellation is not permission", into: target, pasteboard: board,
                    effects: .init(waitForModifiers: { true }, post: { _ in
                        XCTFail("Cancellation during AX validation reached dispatch"); return true
                    }))
            }
            let result = await job?.value
            job = nil
            XCTAssertEqual(result, .refused(.cancelled))
            XCTAssertEqual(board.string(forType: .string), "Original café")
            if cancelAt == 1 { XCTAssertEqual(board.changeCount, originalCount) }
        }
    }

    func testRefusedFinalTargetDoesNotClobberNewClipboardOwner() async {
        let board = makeBoard()
        defer { board.releaseGlobally() }
        var checks = 0
        let target = TextInserter.Target(processID: 101) {
            checks += 1
            if checks == 2 {
                board.clearContents()
                board.setString("Someone else's copy", forType: .string)
                return .targetChanged
            }
            return nil
        }
        let result = await TextInserter.insert("Do not dispatch", into: target, pasteboard: board,
            effects: .init(waitForModifiers: { true }, post: { _ in XCTFail("Unexpected paste"); return true }))
        XCTAssertEqual(result, .refused(.targetChanged))
        XCTAssertEqual(board.string(forType: .string), "Someone else's copy")
    }

    func testClipboardChangedDuringSuccessfulFinalValidationNeverDispatches() async {
        let board = makeBoard()
        defer { board.releaseGlobally() }
        var checks = 0
        let target = TextInserter.Target(processID: 101) {
            checks += 1
            if checks == 2 {
                board.clearContents()
                board.setString("An unrelated copied command", forType: .string)
            }
            return nil
        }
        let result = await TextInserter.insert("No borres nada", into: target, pasteboard: board,
            effects: .init(waitForModifiers: { true }, post: { _ in
                XCTFail("The clipboard no longer contains the dictation"); return true
            }))
        XCTAssertEqual(result, .refused(.clipboardUnavailable))
        XCTAssertEqual(board.string(forType: .string), "An unrelated copied command")
    }

    func testAcceptedDispatchUsesCapturedPIDAndActuallyRestoresClipboard() async {
        let board = makeBoard()
        defer { board.releaseGlobally() }
        var posted: [pid_t] = []
        let target = TextInserter.Target(processID: 107) { nil }
        let result = await TextInserter.insert("Café — no borres 0,5", into: target, pasteboard: board,
            effects: .init(waitForModifiers: { true }, post: { posted.append($0); return true }))
        XCTAssertEqual(result, .dispatched, "This is dispatch evidence, not an external editor acknowledgement")
        XCTAssertEqual(posted, [107])
        XCTAssertEqual(board.string(forType: .string), "Café — no borres 0,5")
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while board.string(forType: .string) != "Original café", ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(board.string(forType: .string), "Original café", "Observe restoration, not only elapsed time")
    }

    func testExplicitCopyWritesTheFullTextToTheChosenBoard() async {
        let board = makeBoard()
        defer { board.releaseGlobally() }
        let text = String(repeating: "Don’t remove — no borres 0,5. ", count: 100)
        XCTAssertTrue(TextInserter.copy(text, to: board))
        XCTAssertEqual(board.string(forType: .string), text)
    }

    private func makeBoard() -> NSPasteboard {
        let board = NSPasteboard(name: .init("app.portavoz.dictation-test." + UUID().uuidString))
        board.declareTypes([.string, .rtf], owner: nil)
        board.setString("Original café", forType: .string)
        board.setData(Data("{\\rtf1 Original}".utf8), forType: .rtf)
        return board
    }
}
