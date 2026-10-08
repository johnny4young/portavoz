import AppKit
import os
import PortavozCore
import XCTest

@testable import portavoz_app

@MainActor
final class DictationClipboardInsertionTests: XCTestCase {
    func testInsertionRestoresEveryItemAndRepresentationInOrder() async throws {
        let board = makeBoard()
        defer { board.releaseGlobally() }
        let values = ["Don't delete — café", "No borres 1.250,50 €"]
        let items = values.map { text in
            let item = NSPasteboardItem()
            item.setString(text, forType: .string)
            item.setData(Data("<p>\(text)</p>".utf8), forType: .html)
            return item
        }
        XCTAssertTrue(board.writeObjects(items))
        let before = contents(board)
        var sent: String?
        let result = await insert("Own text", on: board) { sent = board.string(forType: .string); return true }
        XCTAssertEqual(result, .dispatched, "No readback: dispatch, not verification")
        XCTAssertEqual(sent, "Own text")
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while contents(board) != before && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertEqual(
            contents(board), before,
            "Restoration must finish on the original board; pending loans: \(DictationClipboard.shared.pendingLoanCount)")
    }

    func testPrivateRepresentationIsBorrowedAsOpaqueBytesAndRestored() async {
        let board = makeBoard()
        defer { board.releaseGlobally() }
        let unknown = NSPasteboard.PasteboardType("app.portavoz.tests.private-provider")
        let provider = ClipboardInsertionProvider(data: Data([1, 2, 3]))
        let item = NSPasteboardItem()
        item.setString("Keep original", forType: .string)
        item.setDataProvider(provider, forTypes: [unknown])
        XCTAssertTrue(board.writeObjects([item]))
        var posts = 0
        let result = await insert("Private formats do not block", on: board) { posts += 1; return false }
        XCTAssertEqual(result, .refused(.eventUnavailable))
        XCTAssertEqual(posts, 1, "An unknown type no longer refuses dictation")
        XCTAssertEqual(provider.reads, 1)
        XCTAssertEqual(board.string(forType: .string), "Keep original")
        XCTAssertEqual(board.data(forType: unknown), Data([1, 2, 3]))
    }

    func testUnreadableRichFormatCannotBecomeSuccessfulPlainTextSnapshot() async {
        let board = makeBoard()
        defer { board.releaseGlobally() }
        let provider = ClipboardInsertionProvider(data: nil)
        let item = NSPasteboardItem()
        item.setString("Keep every format", forType: .string)
        item.setDataProvider(provider, forTypes: [.rtf])
        board.writeObjects([item])
        let generation = board.changeCount
        var posts = 0
        let result = await insert("Refuse partial preservation", on: board) { posts += 1; return false }
        XCTAssertEqual(result, .refused(.clipboardUnavailable))
        XCTAssertEqual(posts, 0)
        XCTAssertEqual(board.changeCount, generation)
    }

    func testSecondPasteWaitsUntilFirstDeferredReaderFinished() async throws {
        let board = makeBoard()
        defer { board.releaseGlobally() }
        board.setString("Original", forType: .string)
        var reader: Task<String?, Never>?
        let first = await insert("First — primero", on: board) {
            reader = Task {
                try? await Task.sleep(for: .milliseconds(100))
                return board.string(forType: .string)
            }
            return true
        }
        XCTAssertEqual(first, .dispatched)
        let second = await insert("Second — segundo", on: board) { true }
        XCTAssertEqual(second, .dispatched)
        let observed = await reader?.value
        XCTAssertEqual(observed, "First — primero", "Restoring later does not repair a paste that read the wrong dictation")
        try await waitForString("Original", on: board)
    }

    func testForeignSameTextWriteSurvivesDelayedRestoration() async throws {
        let board = makeBoard()
        defer { board.releaseGlobally() }
        board.setString("Prior owner", forType: .string)
        let result = await insert("Identical content", on: board) { true }
        XCTAssertEqual(result, .dispatched)
        board.clearContents()
        board.setString("Identical content", forType: .string)
        let foreignGeneration = board.changeCount
        try await Task.sleep(for: TextInserter.restoreDelay + .milliseconds(100))
        XCTAssertEqual(board.changeCount, foreignGeneration)
        XCTAssertEqual(board.string(forType: .string), "Identical content")
    }

    func testPrivacyMarkersExistAtActualPostAndFailedPostRestoresEmptyBoard() async {
        let board = makeBoard()
        defer { board.releaseGlobally() }
        var calls = 0
        let result = await insert("Private dictation", on: board) {
            calls += 1
            let types = Set(board.types?.map(\.rawValue) ?? [])
            for marker in ["TransientType", "ConcealedType", "AutoGeneratedType"] {
                XCTAssertTrue(types.contains("org.nspasteboard." + marker))
            }
            return false
        }
        XCTAssertEqual(result, .refused(.eventUnavailable))
        XCTAssertEqual(calls, 1)
        XCTAssertTrue(board.pasteboardItems?.isEmpty != false)
    }

    func testCancellationDuringLazyReadDoesNotBorrowOrPost() async {
        let board = makeBoard()
        defer { board.releaseGlobally() }
        let taskBox = OSAllocatedUnfairLock<Task<DictationDeliveryOutcome, Never>?>(initialState: nil)
        let provider = ClipboardInsertionProvider(data: Data([1]), onRead: { taskBox.withLock { $0?.cancel() } })
        let item = NSPasteboardItem()
        item.setDataProvider(provider, forTypes: [.init("org.nspasteboard.source")])
        board.writeObjects([item])
        let generation = board.changeCount
        var posts = 0
        let task = Task { await insert("Cancelled", on: board) { posts += 1; return false } }
        taskBox.withLock { $0 = task }
        let result = await task.value
        taskBox.withLock { $0 = nil }
        XCTAssertEqual(provider.reads, 1)
        XCTAssertEqual(result, .refused(.cancelled))
        XCTAssertEqual(posts, 0)
        XCTAssertEqual(board.changeCount, generation)
    }

    func testSecureFieldAppearingDuringProviderReadPreventsDispatch() async {
        let board = makeBoard()
        defer { board.releaseGlobally() }
        let becameSecure = OSAllocatedUnfairLock(initialState: false)
        let provider = ClipboardInsertionProvider(data: Data([1]), onRead: { becameSecure.withLock { $0 = true } })
        let item = NSPasteboardItem()
        item.setDataProvider(provider, forTypes: [.init("org.nspasteboard.source")])
        board.writeObjects([item])
        var posts = 0
        let target = testTarget { becameSecure.withLock { $0 } ? .secureField : nil }
        let result = await TextInserter.insert(
            "Not a password", into: target, pasteboard: board,
            effects: .init(waitForModifiers: { true }, post: { _ in posts += 1; return false }))
        XCTAssertEqual(result, .refused(.secureField))
        XCTAssertEqual(posts, 0)
        XCTAssertEqual(board.pasteboardItems?.first?.data(forType: .init("org.nspasteboard.source")), Data([1]))
    }

    func testForeignWriteDuringFinalFieldInspectionCannotBePostedOrRestoredOver() async {
        let board = makeBoard()
        defer { board.releaseGlobally() }
        board.setString("Original", forType: .string)
        var inspections = 0
        var posts = 0
        let target = testTarget {
            inspections += 1
            if inspections == 2 {
                board.clearContents()
                board.setString("Foreign copy", forType: .string)
            }
            return nil
        }
        let result = await TextInserter.insert(
            "Own text", into: target, pasteboard: board,
            effects: .init(waitForModifiers: { true }, post: { _ in posts += 1; return false }))
        XCTAssertEqual(result, .refused(.clipboardUnavailable))
        XCTAssertEqual(posts, 0)
        XCTAssertEqual(board.string(forType: .string), "Foreign copy")
    }

    func testCapturedProcessIsValidatedTwiceAndIsTheOnlyDispatchTarget() async {
        let board = makeBoard()
        defer { board.releaseGlobally() }
        board.setString("Preserve", forType: .string)
        var validations = 0
        var posted: [pid_t] = []
        let target = testTarget { validations += 1; return nil }
        let result = await TextInserter.insert("No borres", into: target, pasteboard: board,
            effects: .init(waitForModifiers: { true }, post: { processID in
                posted.append(processID)
                return false
            }, postToSession: {
                XCTFail("Clipboard delivery must not fall back to session routing")
                return false
            }))
        XCTAssertEqual(result, .refused(.eventUnavailable))
        XCTAssertEqual(validations, 2, "Validate before borrowing and again before posting")
        XCTAssertEqual(posted, [ProcessInfo.processInfo.processIdentifier])
        XCTAssertEqual(board.string(forType: .string), "Preserve")
    }

    func testTargetLostDuringLazyReadRestoresWithoutPosting() async {
        let board = makeBoard()
        defer { board.releaseGlobally() }
        let available = OSAllocatedUnfairLock(initialState: true)
        let provider = ClipboardInsertionProvider(data: Data([1]), onRead: {
            available.withLock { $0 = false }
        })
        let item = NSPasteboardItem()
        item.setDataProvider(provider, forTypes: [.init("org.nspasteboard.source")])
        XCTAssertTrue(board.writeObjects([item]))
        var posts = 0
        let result = await TextInserter.insert("Never paste", into: testTarget(), pasteboard: board,
            effects: .init(waitForModifiers: { true }, post: { _ in posts += 1; return true },
                           isProcessLive: { _ in available.withLock { $0 } }))
        XCTAssertEqual(provider.reads, 1)
        XCTAssertEqual(result, .refused(.eventUnavailable))
        XCTAssertEqual(posts, 0)
        XCTAssertEqual(board.pasteboardItems?.first?.data(forType: .init("org.nspasteboard.source")), Data([1]))
    }

    func testSecondArrivalDuringModifierWaitCannotStealExclusiveLoan() async throws {
        let board = makeBoard()
        defer { board.releaseGlobally() }
        board.setString("Original", forType: .string)
        var posts = 0
        let result = await TextInserter.insert(
            "Late contender", into: testTarget(), pasteboard: board,
            effects: .init(waitForModifiers: {
                let first = await self.insert("First posted", on: board) { posts += 1; return true }
                XCTAssertEqual(first, .dispatched)
                return true
            }, post: { _ in posts += 1; return true }))
        XCTAssertEqual(result, .refused(.clipboardUnavailable))
        XCTAssertEqual(posts, 1)
        XCTAssertEqual(board.string(forType: .string), "First posted")
        try await waitForString("Original", on: board)
    }

    private func insert(
        _ text: String, on board: NSPasteboard, post: @escaping @MainActor () -> Bool
    ) async -> DictationDeliveryOutcome {
        await TextInserter.insert(text, into: testTarget(), pasteboard: board,
            effects: .init(waitForModifiers: { true }, post: { _ in post() }))
    }

    /// The test process is a live, positive PID; refusal comes only from `validate`.
    private func testTarget(
        validate: @escaping () -> DictationDeliveryOutcome.Refusal? = { nil }
    ) -> TextInserter.Target {
        TextInserter.Target(processID: ProcessInfo.processInfo.processIdentifier, validate: validate)
    }

    private func makeBoard() -> NSPasteboard {
        let board = NSPasteboard(name: .init("app.portavoz.clipboard-test.\(UUID().uuidString)"))
        board.clearContents()
        return board
    }

    private func waitForString(_ expected: String, on board: NSPasteboard) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while board.string(forType: .string) != expected && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertEqual(board.string(forType: .string), expected,
                       "Delayed restoration did not settle; pending loans: \(DictationClipboard.shared.pendingLoanCount)")
    }

    private func contents(_ board: NSPasteboard) -> [[String: Data]] {
        (board.pasteboardItems ?? []).map { item in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { type in
                item.data(forType: type).map { (type.rawValue, $0) }
            })
        }
    }
}

private final class ClipboardInsertionProvider: NSObject, NSPasteboardItemDataProvider {
    let data: Data?
    let onRead: (@Sendable () -> Void)?
    private let count = OSAllocatedUnfairLock(initialState: 0)
    var reads: Int { count.withLock { $0 } }

    init(data: Data?, onRead: (@Sendable () -> Void)? = nil) {
        self.data = data
        self.onRead = onRead
    }

    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem,
                    provideDataForType type: NSPasteboard.PasteboardType) {
        count.withLock { $0 += 1 }
        onRead?()
        if let data { item.setData(data, forType: type) }
    }
}
