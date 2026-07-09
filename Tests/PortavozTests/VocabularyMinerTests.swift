import Foundation
import XCTest

@testable import TranscriptionKit

final class VocabularyMinerTests: XCTestCase {
    func testRecurringDomainShapesAreSuggestedMostFrequentFirst() {
        let texts = [
            "we register the device in Cots2M and the LVGT queue",
            "Cots2M rejected the payload, check LVGT again",
            "the Cots2M spec says the identifier has no spaces",
            "LVGT owns that flow now",
            "Cots2M again for the record",
        ]

        let suggested = VocabularyMiner.suggest(from: texts, existing: [], minimumOccurrences: 3)

        XCTAssertEqual(suggested, ["Cots2M", "LVGT"], "frequency order, both above threshold")
    }

    func testPlainWordsAndSentenceCapitalsAreNeverSuggested() {
        let texts = Array(
            repeating: "The meeting Started early because Daniel wanted the update",
            count: 5)

        XCTAssertTrue(VocabularyMiner.suggest(from: texts, existing: []).isEmpty)
    }

    func testCamelCaseCountsAndPunctuationIsTrimmed() {
        let texts = [
            "we ship (WhisperKit), yes WhisperKit,",
            "WhisperKit... is pinned",
        ]

        XCTAssertEqual(
            VocabularyMiner.suggest(from: texts, existing: [], minimumOccurrences: 3),
            ["WhisperKit"])
    }

    func testExistingVocabularyAndStoplistAreExcluded() {
        let texts = Array(repeating: "Cots2M is OK per the LVGT checklist", count: 4)

        let suggested = VocabularyMiner.suggest(
            from: texts, existing: ["cots2m"], minimumOccurrences: 3)

        XCTAssertEqual(suggested, ["LVGT"], "existing (case-insensitive) and OK dropped")
    }

    func testBelowThresholdIsNotSuggested() {
        let texts = ["Cots2M once", "Cots2M twice"]
        XCTAssertTrue(
            VocabularyMiner.suggest(from: texts, existing: [], minimumOccurrences: 3).isEmpty)
    }

    func testShapeHeuristics() {
        XCTAssertTrue(VocabularyMiner.looksLikeDomainTerm("LVGT"))
        XCTAssertTrue(VocabularyMiner.looksLikeDomainTerm("Cots2M"))
        XCTAssertTrue(VocabularyMiner.looksLikeDomainTerm("WhisperKit"))
        XCTAssertTrue(VocabularyMiner.looksLikeDomainTerm("iPhone"))
        XCTAssertFalse(VocabularyMiner.looksLikeDomainTerm("Started"), "plain capitalized word")
        XCTAssertFalse(VocabularyMiner.looksLikeDomainTerm("meeting"))
        XCTAssertFalse(VocabularyMiner.looksLikeDomainTerm("A"))
        XCTAssertFalse(
            VocabularyMiner.looksLikeDomainTerm("TRANSCRIPTION"), "all-caps shouting, not acronym")
        XCTAssertFalse(VocabularyMiner.looksLikeDomainTerm("42"), "needs at least two letters")
    }
}
