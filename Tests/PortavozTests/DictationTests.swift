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

    func testRestoreDoesNotAdvertiseTypesThatWereNotCaptured() {
        let pasteboard = scratchPasteboard()
        defer { pasteboard.releaseGlobally() }
        let uncaptured = NSPasteboard.PasteboardType("app.portavoz.tests.uncaptured")
        pasteboard.declareTypes([.string, uncaptured], owner: nil)
        pasteboard.setString("original", forType: .string)

        let snapshot = PasteboardSnapshot(of: pasteboard)
        pasteboard.clearContents()
        snapshot?.restore(to: pasteboard)

        XCTAssertEqual(pasteboard.string(forType: .string), "original")
        XCTAssertFalse(pasteboard.types?.contains(uncaptured) == true)
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

/// The privacy gate that keeps dictation out of password fields.
final class SecureFieldGateTests: XCTestCase {
    func testSecureSubroleOrRoleBlocksAndRegularFieldsPass() {
        XCTAssertEqual(
            TextInserter.classifyFocusedField(
                role: "AXTextField", subrole: "AXSecureTextField"),
            .secure)
        XCTAssertEqual(
            TextInserter.classifyFocusedField(
                role: "AXSecureTextField", subrole: nil),
            .secure)
        XCTAssertEqual(
            TextInserter.classifyFocusedField(
                role: "AXTextField", subrole: "AXSearchField"),
            .regular)
        XCTAssertEqual(
            TextInserter.classifyFocusedField(role: "AXTextArea", subrole: nil),
            .regular)
    }

    func testMissingRoleFailsClosed() {
        XCTAssertEqual(
            TextInserter.classifyFocusedField(role: nil, subrole: nil),
            .unavailable)
    }
}

final class DictationCapturePolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 10_000)

    func testFinishBeforeMicrophoneStartsCancels() {
        XCTAssertEqual(
            DictationCapturePolicy.finishDecision(captureStartedAt: nil, now: now),
            .cancel)
    }

    func testFinishUsesActualMicrophoneCaptureDuration() {
        XCTAssertEqual(
            DictationCapturePolicy.finishDecision(
                captureStartedAt: now.addingTimeInterval(-0.74), now: now),
            .cancel)
        XCTAssertEqual(
            DictationCapturePolicy.finishDecision(
                captureStartedAt: now.addingTimeInterval(-0.75), now: now),
            .stopAfterTail)
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

    func testLexicalContentGateKeepsWordsAndRejectsNoiseArtifacts() {
        XCTAssertTrue(DictationAssembler.hasLexicalContent("sí"))
        XCTAssertTrue(DictationAssembler.hasLexicalContent("reunión a las 3"))
        XCTAssertTrue(DictationAssembler.hasLexicalContent("ok!"))
        XCTAssertFalse(DictationAssembler.hasLexicalContent(""))
        XCTAssertFalse(DictationAssembler.hasLexicalContent("."))
        XCTAssertFalse(DictationAssembler.hasLexicalContent("…"))
        XCTAssertFalse(DictationAssembler.hasLexicalContent("¿? ,,, —"))
    }
}
