import AppKit
import XCTest
@testable import portavoz_app

final class DictationCaretJoinTests: XCTestCase {
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
            ("10", "%", "%")
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
            receiver.providesPreceding = true
            let result = await receiver.insert(text)
            XCTAssertEqual(result, .verified)
            XCTAssertEqual(receiver.document, document + " " + text)
            XCTAssertEqual(receiver.precedingSpans, [NSRange(location: document.utf16.count - 2, length: 2)])
            XCTAssertEqual(receiver.requestedSpans, [NSRange(location: document.utf16.count, length: text.utf16.count + 1)])
        }
    }

    func testCaretAtTheStartReadsNothingBeforeIt() async {
        let receiver = TextReadbackHarness()
        defer { receiver.board.releaseGlobally() }
        receiver.document = ""
        receiver.selection = NSRange(location: 0, length: 0)
        receiver.providesPreceding = true
        let result = await receiver.insert("No borres esto.")
        XCTAssertEqual(result, .verified)
        XCTAssertEqual(receiver.document, "No borres esto.")
        XCTAssertTrue(receiver.precedingSpans.isEmpty)
    }

    func testTextBeforeTheCaretIsNeverRequestedOnceTheFieldFailsValidation() async {
        let receiver = TextReadbackHarness()
        defer { receiver.board.releaseGlobally() }
        receiver.document = "password"
        receiver.selection = NSRange(location: 8, length: 0)
        receiver.providesPreceding = true
        // The modifier check validates first; the field turns secure before the context read.
        receiver.onValidate = { if $0 == 2 { receiver.targetFailure = .secureField } }
        let result = await receiver.insert("secret")
        XCTAssertEqual(result, .refused(.secureField))
        XCTAssertTrue(receiver.precedingSpans.isEmpty)
        XCTAssertEqual(receiver.posts, 0)
        XCTAssertEqual(receiver.document, "password")
    }
}
