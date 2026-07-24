import TranscriptionKit
import XCTest

final class DictationTextRulesTests: XCTestCase {
    func testFillersDisappearInBothLanguagesWithSeamsRepaired() {
        XCTAssertEqual(
            DictationTextRules.apply(
                "Um, hello there uh let's start",
                replacements: [], removeFillers: true),
            "hello there let's start")
        XCTAssertEqual(
            DictationTextRules.apply(
                "eh, dame un momento ehm para revisar",
                replacements: [], removeFillers: true),
            "dame un momento para revisar")
        // A filler right before closing punctuation must not strand a space.
        XCTAssertEqual(
            DictationTextRules.apply(
                "so that works um.", replacements: [], removeFillers: true),
            "so that works.")
    }

    func testFillerRemovalNeverTouchesRealWordsContainingFillerLetters() {
        // "um" inside "summer"/"museum", "eh" inside "vehemente".
        XCTAssertEqual(
            DictationTextRules.apply(
                "summer at the museum was vehemente",
                replacements: [], removeFillers: true),
            "summer at the museum was vehemente")
    }

    func testFillerFilterOffLeavesTextVerbatim() {
        XCTAssertEqual(
            DictationTextRules.apply(
                "um, as I was saying", replacements: [], removeFillers: false),
            "um, as I was saying")
    }

    func testReplacementsMatchWholeWordsCaseInsensitively() {
        let rules = [DictationReplacement(trigger: "gancho", replacement: "Gancho")]
        XCTAssertEqual(
            DictationTextRules.apply(
                "abre GANCHO y busca gancho, no el desganchado",
                replacements: rules, removeFillers: false),
            "abre Gancho y busca Gancho, no el desganchado")
    }

    func testLongestTriggerWinsOverItsPrefix() {
        let rules = [
            DictationReplacement(trigger: "pull", replacement: "PULL"),
            DictationReplacement(trigger: "pull request", replacement: "PR"),
        ]
        XCTAssertEqual(
            DictationTextRules.apply(
                "open a pull request and pull main",
                replacements: rules, removeFillers: false),
            "open a PR and PULL main")
    }

    func testTriggersWithRegexMetacharactersMatchLiterally() {
        let rules = [DictationReplacement(trigger: "c++", replacement: "C++")]
        XCTAssertEqual(
            DictationTextRules.apply(
                "learn c++ today", replacements: rules, removeFillers: false),
            "learn C++ today")
        // A replacement containing template metacharacters stays literal.
        let dollar = [DictationReplacement(trigger: "price", replacement: "$100")]
        XCTAssertEqual(
            DictationTextRules.apply(
                "the price exactly", replacements: dollar, removeFillers: false),
            "the $100 exactly")
    }

    func testCodecRoundTripsAndToleratesGarbage() {
        let rules = [
            DictationReplacement(trigger: "lvgt", replacement: "LVGT"),
            DictationReplacement(trigger: "que es ele", replacement: "QESL"),
        ]
        XCTAssertEqual(
            DictationTextRules.decode(
                replacements: DictationTextRules.encode(rules)),
            rules)
        XCTAssertEqual(DictationTextRules.decode(replacements: "not json"), [])
        XCTAssertEqual(DictationTextRules.decode(replacements: ""), [])
    }

    func testFillerPassRunsBeforeReplacementsAndResultIsTrimmed() {
        // The user's rule sees the cleaned text, and an edge filler leaves
        // no leading/trailing whitespace behind.
        let rules = [DictationReplacement(trigger: "hello", replacement: "Hi")]
        XCTAssertEqual(
            DictationTextRules.apply(
                "um hello world uh", replacements: rules, removeFillers: true),
            "Hi world")
    }
}
