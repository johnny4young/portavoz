import AppKit
import XCTest
@testable import portavoz_app

final class DictationCaretJoinTests: XCTestCase {
    func testSeparatorIsAddedBeforeAFollowingWordOnly() {
        let cases: [(preceding: String?, text: String, following: String?, expected: String)] = [
            ("o ", "big", "wo", "big "),
            ("", "Hola", "mu", "Hola "),
            ("a ", "dos", "3,", "dos "),
            ("a ", "b", ".", "b"),
            ("x ", "y", " z", "y"),
            ("(", "nota", ")", "nota"),
            ("la", "casa", "de", " casa "),
            ("a ", "big", nil, "big"),
            ("a ", "(", "x", "(")
        ]
        for item in cases {
            XCTAssertEqual(DictationCaretJoin.join(item.text, after: item.preceding, before: item.following),
                           item.expected, "\(String(describing: item.preceding)) | \(item.text) | \(String(describing: item.following))")
        }
    }

    func testSeparatorIsAddedOnlyAfterTextThatNeedsOne() {
        let cases: [(preceding: String?, text: String, expected: String)] = [
            (nil, "Mundo", "Mundo"),
            ("", "Hola", "Hola"),
            ("a.", "Mundo", " Mundo"),
            ("la", "casa", " casa"),
            ("es", "World", " World"),
            ("👩🏽‍💻", "listo", " listo"),
            ("e\u{301}", "bien", " bien"),
            ("o ", "casa", "casa"),
            (".\n", "Next", "Next"),
            ("\t", "x", "x"),
            ("¿", "Qué", "Qué"),
            ("¡", "Ya", "Ya"),
            ("“", "Hi", "Hi"),
            ("(", "nota", "nota"),
            ("@", "juan", "juan"),
            ("os", ", y", ", y"),
            ("lo", ".", "."),
            ("si", "?", "?"),
            ("10", "%", "%"),
            ("o \"", "hola", "hola"),
            ("\"", "Hi", "Hi"),
            ("d'", "x", " x"),
            ("s\"", "and", " and"),
            (" '", "hey", "hey")
        ]
        for item in cases {
            XCTAssertEqual(DictationCaretJoin.join(item.text, after: item.preceding), item.expected,
                           "\(String(describing: item.preceding)) + \(item.text)")
        }
    }
}

@MainActor
final class TextInsertionCaretJoinTests: XCTestCase {
    func testInsertionAfterASentenceGainsASpaceAndIsVerifiedExactly() async {
        for (document, text) in [("Hola.", "Mundo"), ("Hello,", "world")] {
            let receiver = TextReadbackHarness()
            defer { receiver.board.releaseGlobally() }
            receiver.document = document
            receiver.selection = NSRange(location: document.utf16.count, length: 0)
            receiver.providesContext = true
            let result = await receiver.insert(text)
            XCTAssertEqual(result, .verified)
            XCTAssertEqual(receiver.document, document + " " + text)
            XCTAssertEqual(receiver.contextSpans, [NSRange(location: document.utf16.count - 2, length: 2)])
            XCTAssertEqual(receiver.requestedSpans, [NSRange(location: document.utf16.count, length: text.utf16.count + 1)])
        }
    }

    func testInsertionBeforeAWordOrOverASelectionIsSpacedOnBothSides() async {
        for (document, selection, text, expected) in [
            ("Hello world", NSRange(location: 6, length: 0), "big", "Hello big world"),
            ("Hola mundo", NSRange(location: 5, length: 5), "gente", "Hola gente")
        ] {
            let receiver = TextReadbackHarness()
            defer { receiver.board.releaseGlobally() }
            receiver.document = document
            receiver.selection = selection
            receiver.providesContext = true
            let result = await receiver.insert(text)
            XCTAssertEqual(result, .verified)
            XCTAssertEqual(receiver.document, expected)
            let end = selection.location + selection.length
            let afterLength = min(2, document.utf16.count - end)
            let expectedSpans = [NSRange(location: selection.location - 2, length: 2)]
                + (afterLength > 0 ? [NSRange(location: end, length: afterLength)] : [])
            XCTAssertEqual(receiver.contextSpans, expectedSpans, "Never more than two units on each side")
        }
    }

    func testCaretAtTheStartReadsNothingBeforeIt() async {
        let receiver = TextReadbackHarness()
        defer { receiver.board.releaseGlobally() }
        receiver.document = ""
        receiver.selection = NSRange(location: 0, length: 0)
        receiver.providesContext = true
        let result = await receiver.insert("No borres esto.")
        XCTAssertEqual(result, .verified)
        XCTAssertEqual(receiver.document, "No borres esto.")
        XCTAssertTrue(receiver.contextSpans.isEmpty)
    }

    func testTextBeforeTheCaretIsNeverRequestedOnceTheFieldFailsValidation() async {
        let receiver = TextReadbackHarness()
        defer { receiver.board.releaseGlobally() }
        receiver.document = "password"
        receiver.selection = NSRange(location: 8, length: 0)
        receiver.providesContext = true
        // The modifier check validates first; the field turns secure before the context read.
        receiver.onValidate = { if $0 == 2 { receiver.targetFailure = .secureField } }
        let result = await receiver.insert("secret")
        XCTAssertEqual(result, .refused(.secureField))
        XCTAssertTrue(receiver.contextSpans.isEmpty)
        XCTAssertEqual(receiver.posts, 0)
        XCTAssertEqual(receiver.document, "password")
    }
}
