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

final class LibrarySearchFusionTests: XCTestCase {
    func testExactHitsStayFirstAndSemanticHitsOnlyFillGaps() {
        XCTAssertEqual(
            LibrarySearchFusion.exactFirst(
                lexical: ["exact-a", "shared"],
                semantic: ["shared", "semantic-b"],
                limit: 3),
            ["exact-a", "shared", "semantic-b"])
    }

    func testFusionHonorsEmptyAndBoundedResultContracts() {
        XCTAssertTrue(LibrarySearchFusion.exactFirst(
            lexical: [1],
            semantic: [2],
            limit: 0).isEmpty)
        XCTAssertEqual(LibrarySearchFusion.exactFirst(
            lexical: [1, 2],
            semantic: [3],
            limit: 2), [1, 2])
    }
}
