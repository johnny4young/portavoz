import AppKit
import XCTest

@testable import portavoz_app

/// The Copy buttons outside dictation (the command-line tool rows) use the same Copy command.
@MainActor
final class PasteboardCopyTests: XCTestCase {
    func testCopyReplacesEveryItemWithTheText() async {
        let board = NSPasteboard(name: .init("app.portavoz.pasteboard-copy-test.\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        let first = NSPasteboardItem()
        first.setString("First — primero", forType: .string)
        let second = NSPasteboardItem()
        second.setString("Second — segundo", forType: .string)
        XCTAssertTrue(board.writeObjects([first, second]))

        XCTAssertTrue(PasteboardCopy.copy("/usr/local/bin/portavoz", to: board))

        XCTAssertEqual(board.pasteboardItems?.count, 1)
        XCTAssertEqual(board.string(forType: .string), "/usr/local/bin/portavoz")
    }

    func testEmptyTextAndAFailedWriteReportFailure() async {
        let board = NSPasteboard(name: .init("app.portavoz.pasteboard-copy-test.\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        var writes = 0
        XCTAssertFalse(PasteboardCopy.copy("", to: board) { _, _ in
            writes += 1
            return true
        })
        XCTAssertEqual(writes, 0, "empty text never touches the clipboard")
        XCTAssertFalse(PasteboardCopy.copy("text", to: board) { _, _ in false })
    }
}
