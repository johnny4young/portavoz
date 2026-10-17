import XCTest
@testable import portavoz_app

final class DictationPanelTranscriptTests: XCTestCase {
    func testShortTranscriptIsShownUnchanged() {
        XCTAssertEqual(
            DictationPanelTranscript.visible(confirmed: "No borres", partial: "estas notas."),
            .init(confirmed: "No borres", partial: " estas notas."))
        XCTAssertEqual(
            DictationPanelTranscript.visible(confirmed: "Don’t delete these notes.", partial: ""),
            .init(confirmed: "Don’t delete these notes.", partial: ""))
    }

    func testLongTranscriptKeepsTheNewestWholeWords() {
        let confirmed = Array(repeating: "palabra", count: 40).joined(separator: " ") + " final confirmada"
        let visible = DictationPanelTranscript.visible(confirmed: confirmed, partial: "y la cola nueva", limit: 40)
        XCTAssertTrue(visible.confirmed.hasPrefix("…"))
        XCTAssertTrue(visible.confirmed.hasSuffix("final confirmada"))
        XCTAssertEqual(visible.partial, " y la cola nueva", "The volatile tail keeps its own style")
        let shown = visible.confirmed.dropFirst() + visible.partial
        XCTAssertLessThanOrEqual(shown.count, 40)
        XCTAssertTrue(confirmed.hasSuffix(String(visible.confirmed.dropFirst())), "Elision starts at a word")
    }

    func testElisionInsideTheVolatileTailDropsTheConfirmedPrefix() {
        let partial = Array(repeating: "words", count: 20).joined(separator: " ") + " still arriving"
        let visible = DictationPanelTranscript.visible(confirmed: "Settled.", partial: partial, limit: 30)
        XCTAssertEqual(visible.confirmed, "…")
        XCTAssertTrue(visible.partial.hasSuffix("still arriving"))
        XCTAssertFalse(visible.partial.hasPrefix(" "))
    }

    func testAWordLongerThanHalfTheLimitIsCutRatherThanHidden() {
        let word = String(repeating: "x", count: 50)
        let visible = DictationPanelTranscript.visible(confirmed: word, partial: "", limit: 20)
        XCTAssertEqual(visible.confirmed, "…" + String(repeating: "x", count: 20))
    }
}
