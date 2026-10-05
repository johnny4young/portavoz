import AppKit
import os
import XCTest

@testable import portavoz_app

@MainActor
final class DictationRecoveryCopyTests: XCTestCase {
    func testCopyRefusesMultipleItemsBeforeReadingOrWritingThem() async {
        let board = makeBoard()
        defer { board.releaseGlobally() }
        let provider = RecoveryCopyProvider()
        let first = NSPasteboardItem()
        first.setString("First — primero", forType: .string)
        let second = NSPasteboardItem()
        second.setString("Second — segundo", forType: .string)
        second.setDataProvider(provider, forTypes: [.rtf])
        XCTAssertTrue(board.writeObjects([first, second]))
        let generation = board.changeCount
        var writes = 0

        XCTAssertFalse(TextInserter.copy("Keep my dictation", to: board) { _, _ in
            writes += 1
            return false
        })

        XCTAssertEqual(writes, 0, "Refusal must precede the destructive clipboard declaration")
        XCTAssertEqual(provider.reads, 0, "An inadmissible item layout must not invoke lazy providers")
        XCTAssertEqual(board.changeCount, generation)
        XCTAssertEqual(board.pasteboardItems?.map { $0.string(forType: .string) },
                       ["First — primero", "Second — segundo"])
        XCTAssertEqual(board.pasteboardItems?.last?.types, [.string, .rtf])
    }

    func testCopyRefusesForeignOwnerPublishedDuringSnapshot() async {
        let board = makeBoard()
        defer { board.releaseGlobally() }
        let provider = RecoveryCopyProvider(replacementBoardName: board.name.rawValue)
        let item = NSPasteboardItem()
        item.setDataProvider(provider, forTypes: [.string])
        XCTAssertTrue(board.writeObjects([item]))
        var writes = 0

        XCTAssertFalse(TextInserter.copy("Do not overwrite the new owner", to: board) { _, _ in
            writes += 1
            return false
        })

        XCTAssertGreaterThan(provider.reads, 0, "Exercise the production snapshot's lazy read")
        XCTAssertEqual(writes, 0)
        XCTAssertEqual(board.string(forType: .string), "New owner's copy")
        XCTAssertEqual(board.pasteboardItems?.count, 1)
    }

    func testSingleItemFailedWriteStillRestoresAllRepresentations() async {
        let board = makeBoard()
        defer { board.releaseGlobally() }
        let item = NSPasteboardItem()
        let rich = Data("{\\rtf1 Original café}".utf8)
        item.setString("Original café", forType: .string)
        item.setData(rich, forType: .rtf)
        XCTAssertTrue(board.writeObjects([item]))
        var writes = 0

        XCTAssertFalse(TextInserter.copy("Recovery text", to: board) { _, _ in
            writes += 1
            return false
        })

        XCTAssertEqual(writes, 1)
        XCTAssertEqual(board.pasteboardItems?.count, 1)
        XCTAssertEqual(board.string(forType: .string), "Original café")
        XCTAssertEqual(board.data(forType: .rtf), rich)
    }

    private func makeBoard() -> NSPasteboard {
        let board = NSPasteboard(name: .init("app.portavoz.recovery-copy-test.\(UUID().uuidString)"))
        board.clearContents()
        return board
    }
}

private final class RecoveryCopyProvider: NSObject, NSPasteboardItemDataProvider {
    private let replacementBoardName: String?
    private let readCount = OSAllocatedUnfairLock(initialState: 0)
    var reads: Int { readCount.withLock { $0 } }

    init(replacementBoardName: String? = nil) {
        self.replacementBoardName = replacementBoardName
    }

    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem,
                    provideDataForType type: NSPasteboard.PasteboardType) {
        readCount.withLock { $0 += 1 }
        item.setData(Data("Original lazy value".utf8), forType: type)
        if let replacementBoardName {
            let board = NSPasteboard(name: .init(replacementBoardName))
            board.clearContents()
            board.setString("New owner's copy", forType: .string)
        }
    }
}
