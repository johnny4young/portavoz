import Foundation
import XCTest

@testable import TranscriptionKit

final class VocabularyMinerTests: XCTestCase {
    func testRecurringDomainShapesAreSuggestedMostFrequentFirst() {
        let texts = [
            "we register the device in Qord2M and the QVTL queue",
            "Qord2M rejected the payload, check QVTL again",
            "the Qord2M spec says the identifier has no spaces",
            "QVTL owns that flow now",
            "Qord2M again for the record",
        ]

        let suggested = VocabularyMiner.suggest(from: texts, existing: [], minimumOccurrences: 3)

        XCTAssertEqual(suggested, ["Qord2M", "QVTL"], "frequency order, both above threshold")
    }

    func testPlainWordsAndSentenceCapitalsAreNeverSuggested() {
        let texts = Array(
            repeating: "The meeting Started early because Marta wanted the update",
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
        let texts = Array(repeating: "Qord2M is OK per the QVTL checklist", count: 4)

        let suggested = VocabularyMiner.suggest(
            from: texts, existing: ["qord2m"], minimumOccurrences: 3)

        XCTAssertEqual(suggested, ["QVTL"], "existing (case-insensitive) and OK dropped")
    }

    func testBelowThresholdIsNotSuggested() {
        let texts = ["Qord2M once", "Qord2M twice"]
        XCTAssertTrue(
            VocabularyMiner.suggest(from: texts, existing: [], minimumOccurrences: 3).isEmpty)
    }

    func testShapeHeuristics() {
        XCTAssertTrue(VocabularyMiner.looksLikeDomainTerm("QVTL"))
        XCTAssertTrue(VocabularyMiner.looksLikeDomainTerm("Qord2M"))
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
