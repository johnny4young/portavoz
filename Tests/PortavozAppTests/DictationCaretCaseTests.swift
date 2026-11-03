import AppKit
import XCTest
@testable import portavoz_app

@MainActor
final class DictationCaretCaseTests: XCTestCase {
    /// Common words are those the fake dictionary lists; nothing is a name unless told.
    private func caretCase(common: Set<String> = ["then", "the", "we", "lunes", "a"], names: Set<String> = [],
                           protected: Set<String> = []) -> DictationCaretCase {
        var caretCase = DictationCaretCase(protectedWords: protected)
        caretCase.isCommonWord = { common.contains($0) }
        caretCase.isName = { word, _ in names.contains(word) }
        return caretCase
    }

    func testThePositionComesFromTheTextBeforeTheCaret() async {
        let cases: [(String, Bool, DictationCaretCase.Position)] = [
            ("", true, .sentenceStart),
            ("Done. ", false, .sentenceStart),
            ("Really?", false, .sentenceStart),
            ("Hola. ¿", false, .sentenceStart),
            ("First line\n", false, .sentenceStart),
            ("We ship it", false, .midSentence),
            ("Lists, ", false, .midSentence),
            ("Version 2 ", false, .midSentence),
            ("Note: ", false, .unknown),
            ("Talk to Dr. ", false, .unknown),
            ("see e.g. ", false, .unknown),
            ("J. ", false, .unknown),
            ("He said “ok” ", false, .unknown),
            ("   ", false, .unknown)
        ]
        for (preceding, atStart, expected) in cases {
            XCTAssertEqual(DictationCaretCase.position(after: preceding, atFieldStart: atStart), expected,
                           "“\(preceding)”")
        }
    }

    func testASentenceStartIsCapitalizedAndAContinuationLowered() async {
        let adapter = caretCase()
        XCTAssertEqual(adapter.adapt("then we ship", after: "Done. ", atFieldStart: false), "Then we ship")
        XCTAssertEqual(adapter.adapt("¿qué tal?", after: "", atFieldStart: true), "¿Qué tal?")
        XCTAssertEqual(adapter.adapt("Then we ship.", after: "We test it, ", atFieldStart: false), "then we ship.")
        XCTAssertEqual(adapter.adapt("Lunes a las 9.", after: "Nos vemos el ", atFieldStart: false),
                       "lunes a las 9.")
    }

    func testNamesAcronymsIAndTheUsersSpellingsKeepTheirCapital() async {
        let adapter = caretCase(common: ["then", "mark", "nasa", "portavoz"], names: ["Mark"], protected: ["Portavoz"])
        for word in ["Juan", "Mark", "NASA", "I", "I'm", "Portavoz", "McDonald"] {
            XCTAssertEqual(adapter.adapt("\(word) said so", after: "and ", atFieldStart: false), "\(word) said so",
                           word)
        }
    }

    func testAnUnclearPositionChangesNothing() async {
        let adapter = caretCase()
        for preceding in ["Note: ", "Talk to Dr. ", "He said “ok” "] {
            XCTAssertEqual(adapter.adapt("Then we ship", after: preceding, atFieldStart: false), "Then we ship")
            XCTAssertEqual(adapter.adapt("then we ship", after: preceding, atFieldStart: false), "then we ship")
        }
        XCTAssertEqual(adapter.adapt("2 more", after: "Done. ", atFieldStart: false), "2 more")
    }

    func testTheSystemDictionaryTellsCommonWordsFromNames() async throws {
        let languages = NSSpellChecker.shared.availableLanguages
        try XCTSkipUnless(languages.contains("en") && languages.contains("es"), "Needs the en and es dictionaries")
        XCTAssertTrue(DictationCaretCase.systemDictionaryKnows("then"))
        XCTAssertTrue(DictationCaretCase.systemDictionaryKnows("lunes"))
        XCTAssertFalse(DictationCaretCase.systemDictionaryKnows("bogotá"))
        let live = DictationCaretCase()
        XCTAssertEqual(live.adapt("Then we ship", after: "We test it, ", atFieldStart: false), "then we ship")
        for kept in ["Mark said so", "Monday works", "Juan dijo que sí", "Bogotá queda lejos"] {
            XCTAssertEqual(live.adapt(kept, after: "and ", atFieldStart: false), kept, kept)
        }
    }

    func testTheInserterReadsEightyUnitsOnlyWhenItIsOn() async {
        let document = String(repeating: "x", count: 100) + " we test it, "
        for isOn in [false, true] {
            let receiver = TextReadbackHarness()
            defer { receiver.board.releaseGlobally() }
            receiver.document = document
            receiver.selection = NSRange(location: document.utf16.count, length: 0)
            receiver.providesContext = true
            receiver.caretCase = isOn ? caretCase() : nil
            let result = await receiver.insert("Then we ship.")
            XCTAssertEqual(result, .verified)
            let length = isOn ? DictationCaretCase.contextLength : 2
            XCTAssertEqual(receiver.contextSpans, [NSRange(location: document.utf16.count - length, length: length)])
            XCTAssertEqual(receiver.document, document + (isOn ? "then we ship." : "Then we ship."))
        }
    }
}
