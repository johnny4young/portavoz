import ApplicationKit
import XCTest

final class BilingualSearchQueryExpanderTests: XCTestCase {
    private let expander = BilingualSearchQueryExpander()

    func testExpandsEnglishMonthIntoSpanish() {
        XCTAssertEqual(expander.expand("august"), ["august", "agosto"])
    }

    func testExpandsSpanishMeetingTermsIntoEnglish() {
        XCTAssertEqual(
            expander.expand("presupuesto agosto"),
            ["presupuesto agosto", "budget august"])
    }

    func testExpandsSpanishMultiwordPhrasesIntoEnglish() {
        XCTAssertEqual(
            expander.expand("hoja de ruta con fecha límite"),
            ["hoja de ruta con fecha límite", "roadmap con deadline"])
    }

    func testPreservesTechnicalVocabularyWhileExpandingKnownTerms() {
        XCTAssertEqual(
            expander.expand("DriveQ deployment"),
            ["DriveQ deployment", "DriveQ despliegue"])
    }

    func testDoesNotTreatLowercaseMayAsTheMonthInsideASentence() {
        XCTAssertEqual(
            expander.expand("we may release"),
            ["we may release", "we may lanzamiento"])
        XCTAssertEqual(expander.expand("May"), ["May", "mayo"])
    }

    func testUnknownQueryRemainsSingleAndExact() {
        XCTAssertEqual(expander.expand("Cots2M GraphQL"), ["Cots2M GraphQL"])
    }
}
