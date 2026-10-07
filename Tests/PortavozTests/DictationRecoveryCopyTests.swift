import AppKit
import XCTest

@testable import portavoz_app

/// Recovery Copy is an explicit user Copy: it replaces the clipboard like any
/// Copy command instead of refusing because of what the clipboard held.
@MainActor
final class DictationRecoveryCopyTests: XCTestCase {
    func testCopyReplacesMultipleItemsWithTheCompleteDictation() async {
        let board = makeBoard()
        defer { board.releaseGlobally() }
        let first = NSPasteboardItem()
        first.setString("First — primero", forType: .string)
        let second = NSPasteboardItem()
        second.setString("Second — segundo", forType: .string)
        XCTAssertTrue(board.writeObjects([first, second]))
        let text = "Keep my dictation — café, C++, 1.250,50 €."

        XCTAssertTrue(TextInserter.copy(text, to: board))

        XCTAssertEqual(board.pasteboardItems?.count, 1)
        XCTAssertEqual(board.string(forType: .string), text)
    }

    func testCopyReplacesRichSingleItemContents() async {
        let board = makeBoard()
        defer { board.releaseGlobally() }
        let item = NSPasteboardItem()
        item.setString("Original café", forType: .string)
        item.setData(Data("{\\rtf1 Original café}".utf8), forType: .rtf)
        XCTAssertTrue(board.writeObjects([item]))

        XCTAssertTrue(TextInserter.copy("Recovery text", to: board))

        XCTAssertEqual(board.string(forType: .string), "Recovery text")
        XCTAssertNil(board.data(forType: .rtf))
    }

    func testFailedWriteAndEmptyTextReportFailure() async {
        let board = makeBoard()
        defer { board.releaseGlobally() }
        var writes = 0
        XCTAssertFalse(TextInserter.copy("Recovery text", to: board) { _, _ in
            writes += 1
            return false
        })
        XCTAssertEqual(writes, 1)
        XCTAssertFalse(TextInserter.copy("", to: board))
        XCTAssertEqual(writes, 1, "Empty text never touches the clipboard")
    }

    private func makeBoard() -> NSPasteboard {
        let board = NSPasteboard(name: .init("app.portavoz.recovery-copy-test.\(UUID().uuidString)"))
        board.clearContents()
        return board
    }
}
