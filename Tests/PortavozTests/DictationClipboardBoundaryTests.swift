import AppKit
import XCTest

@testable import portavoz_app

@MainActor
final class DictationClipboardBoundaryTests: XCTestCase {
    func testOrderedItemAndRepresentationLimitsAreInclusive() async {
        for (count, extraType, accepted) in [(16, false, true), (17, false, false), (16, true, false)] {
            let board = makeBoard()
            defer { board.releaseGlobally() }
            let types: [NSPasteboard.PasteboardType] = [
                .string, .init("public.utf16-plain-text"), .init("public.utf16-external-plain-text"),
                .init("org.nspasteboard.source")
            ]
            let items = (0..<count).map { index in
                let item = NSPasteboardItem()
                for type in types { item.setData(Data([UInt8(index)]), forType: type) }
                if extraType && index == 0 { item.setData(Data([1]), forType: .font) }
                return item
            }
            XCTAssertTrue(board.writeObjects(items))
            XCTAssertEqual(board.pasteboardItems?.reduce(0) { $0 + $1.types.count }, count * 4 + (extraType ? 1 : 0))
            let generation = board.changeCount
            let snapshot = PasteboardSnapshot(of: board)
            XCTAssertEqual(snapshot != nil, accepted, "items=\(count), extra representation=\(extraType)")
            XCTAssertEqual(board.changeCount, generation)
            if let snapshot {
                XCTAssertTrue(snapshot.restore(to: board))
                XCTAssertEqual(board.pasteboardItems?.count, count)
                for (index, item) in (board.pasteboardItems ?? []).enumerated() {
                    XCTAssertEqual(item.data(forType: .init("org.nspasteboard.source")), Data([UInt8(index)]))
                }
            }
        }
    }

    func testRetainedByteLimitsAcceptTheBoundaryAndRefuseTheNextByte() async {
        let cap = PasteboardSnapshot.maximumRepresentationBytes
        for sizes in [[cap], [cap + 1], [cap, cap], [cap, cap, 1]] {
            let board = makeBoard()
            defer { board.releaseGlobally() }
            let items = sizes.map { size in
                let item = NSPasteboardItem()
                item.setData(Data(repeating: 0x41, count: size), forType: .init("org.nspasteboard.source"))
                return item
            }
            XCTAssertTrue(board.writeObjects(items))
            let generation = board.changeCount
            let accepted = sizes.allSatisfy { $0 <= cap }
                && sizes.reduce(0, +) <= PasteboardSnapshot.maximumRetainedBytes
            XCTAssertEqual(PasteboardSnapshot(of: board) != nil, accepted, "sizes=\(sizes)")
            XCTAssertEqual(board.changeCount, generation)
        }
    }

    func testFreshItemsAllowRepeatedRestorationAndExpectedOwnerRefusesForeignWrite() async throws {
        let board = makeBoard()
        defer { board.releaseGlobally() }
        let first = NSPasteboardItem()
        first.setString("café", forType: .string)
        let second = NSPasteboardItem()
        second.setString("don't — don’t", forType: .string)
        board.writeObjects([first, second])
        let snapshot = try XCTUnwrap(PasteboardSnapshot(of: board))
        for _ in 0..<3 {
            board.clearContents()
            board.setString("Temporary", forType: .string)
            XCTAssertTrue(snapshot.restore(to: board, expectedChangeCount: board.changeCount))
            XCTAssertEqual(board.pasteboardItems?.map { $0.string(forType: .string) }, ["café", "don't — don’t"])
        }
        let oldGeneration = board.changeCount
        board.clearContents()
        board.setString("Foreign owner", forType: .string)
        XCTAssertFalse(snapshot.restore(to: board, expectedChangeCount: oldGeneration))
        XCTAssertEqual(board.string(forType: .string), "Foreign owner")
    }

    func testIdenticalForeignTextIsNotAuthorityAndLoanCannotRestoreAnotherBoard() async throws {
        let board = makeBoard()
        let other = makeBoard()
        defer { board.releaseGlobally(); other.releaseGlobally() }
        board.setString("Original", forType: .string)
        other.setString("Other", forType: .string)
        let clipboard = DictationClipboard()
        let loan = try XCTUnwrap(clipboard.borrow("Own text", on: board))
        clipboard.restore(loan, on: other)
        XCTAssertTrue(clipboard.isCurrent(loan, on: board), "Wrong-board restoration must not retire a valid loan")
        board.clearContents()
        board.setString("Own text", forType: .string)
        clipboard.restore(loan, on: board)
        XCTAssertEqual(board.string(forType: .string), "Own text")
        XCTAssertEqual(other.string(forType: .string), "Other")
        XCTAssertEqual(clipboard.pendingLoanCount, 0)
    }

    func testClipboardFixtureCannotEscapeItsTemporaryUUIDNamespace() async {
        for temporary in [false, true] {
            for flags in [[], ["-seed-dictation-clipboard"], ["-seed-dictation", "-seed-dictation-clipboard"]] {
                let fixture = DictationUITestFixture(arguments: flags, usesTemporaryStore: temporary)
                XCTAssertEqual(fixture?.exerciseClipboard == true, temporary && flags.count == 2)
                for name in ["", "NSGeneralPboard", "app.portavoz.dictation-test.invalid"] {
                    let dependencies = DictationUITestFixture.dependencies(fixture: fixture, environment: [
                        DictationNativeUITestFixture.environmentKey: name
                    ])
                    let outcome = await dependencies.insert("Must not touch real data")
                    XCTAssertEqual(outcome, fixture?.exerciseClipboard == true ? .clipboardUnavailable : .focusUnavailable)
                }
            }
        }
    }

    private func makeBoard() -> NSPasteboard {
        let board = NSPasteboard(name: .init("app.portavoz.clipboard-boundary.\(UUID().uuidString)"))
        board.clearContents()
        return board
    }
}
