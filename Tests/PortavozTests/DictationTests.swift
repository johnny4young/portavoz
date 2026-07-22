import AppKit
import XCTest

@testable import TranscriptionKit
@testable import portavoz_app

/// Clipboard preservation around the dictation paste. Uses uniquely named
/// pasteboards so the user's real clipboard is never touched by the suite.
final class PasteboardSnapshotTests: XCTestCase {
    private func scratchPasteboard() -> NSPasteboard {
        NSPasteboard(name: .init("portavoz-tests-\(UUID().uuidString)"))
    }

    func testRoundTripsRichMultiTypeContent() {
        let pasteboard = scratchPasteboard()
        defer { pasteboard.releaseGlobally() }
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        pasteboard.declareTypes([.png, .string], owner: nil)
        pasteboard.setData(png, forType: .png)
        pasteboard.setString("informe Q3", forType: .string)

        let snapshot = PasteboardSnapshot(of: pasteboard)
        XCTAssertNotNil(snapshot, "rich content must produce a snapshot")

        pasteboard.clearContents()
        pasteboard.setString("dictado nuevo", forType: .string)
        XCTAssertNil(pasteboard.data(forType: .png))

        snapshot?.restore(to: pasteboard)
        XCTAssertEqual(pasteboard.data(forType: .png), png)
        XCTAssertEqual(pasteboard.string(forType: .string), "informe Q3")
    }

    func testEmptyPasteboardProducesNoSnapshot() {
        let pasteboard = scratchPasteboard()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        XCTAssertNil(PasteboardSnapshot(of: pasteboard))
    }

    func testChangeCountAdvancesWhenAnotherWriterTakesOver() {
        // The restore guard keys on changeCount, not value equality: an
        // identical string written by a clipboard manager still advances the
        // count, which is exactly the signal that restoring would clobber it.
        let pasteboard = scratchPasteboard()
        defer { pasteboard.releaseGlobally() }
        pasteboard.declareTypes([.string], owner: nil)
        pasteboard.setString("dictado", forType: .string)
        let ours = pasteboard.changeCount

        pasteboard.declareTypes([.string], owner: nil)
        pasteboard.setString("dictado", forType: .string)
        XCTAssertNotEqual(
            pasteboard.changeCount, ours,
            "an identical value must still read as a foreign write")
    }
}

/// Pure text assembly for system-wide dictation.
final class DictationAssemblerTests: XCTestCase {
    func testJoinsConfirmedAndPartial() {
        XCTAssertEqual(
            DictationAssembler.text(confirmed: "hola equipo,", partial: "revisemos el sprint"),
            "hola equipo, revisemos el sprint")
    }

    func testTrimsAndDropsEmptyPieces() {
        XCTAssertEqual(DictationAssembler.text(confirmed: "  hola  ", partial: "   "), "hola")
        XCTAssertEqual(DictationAssembler.text(confirmed: "", partial: "solo parcial"), "solo parcial")
        XCTAssertEqual(DictationAssembler.text(confirmed: "", partial: ""), "")
    }
}
