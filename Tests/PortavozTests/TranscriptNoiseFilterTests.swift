import XCTest

@testable import PortavozCore

final class TranscriptNoiseFilterTests: XCTestCase {
    private func noise(_ t: String, _ c: Double?) -> Bool {
        TranscriptNoiseFilter.isLikelyNoise(text: t, confidence: c)
    }

    func testLoneLettersAreNoiseRegardlessOfConfidence() {
        // Field garbage from a barely-used mic — single letters even at mid confidence.
        XCTAssertTrue(noise("R", 0.52))
        XCTAssertTrue(noise("E", 0.18))
        XCTAssertTrue(noise("D", 0.54))
        XCTAssertTrue(noise("", 0.9))
        XCTAssertTrue(noise("—", 0.9))
    }

    func testShortNoVowelTokensAreNoise() {
        XCTAssertTrue(noise("SR", 0.38))
        XCTAssertTrue(noise("MK", 0.38))
    }

    func testConfidentShortWordsAndAcronymsAreKept() {
        XCTAssertFalse(noise("OK", 0.8))
        XCTAssertFalse(noise("AI", 0.8))
        XCTAssertFalse(noise("ML", 0.8))
    }

    func testLowConfidenceFragmentsAreNoise() {
        XCTAssertTrue(noise("TO", 0.21))
        XCTAssertTrue(noise("IT'NAKE THINKE", 0.36))
        XCTAssertTrue(noise("YOU MAY IGHT", 0.37))
        XCTAssertTrue(noise("THE PARE", 0.36))
    }

    func testLowConfidenceSentenceIsNotDeletedWholesale() {
        XCTAssertFalse(noise(
            "The rollout still needs approval from the security team.", 0.36))
    }

    func testRealSpeechIsKept() {
        XCTAssertFalse(noise("You can do that one, okay?", 0.66))
        XCTAssertFalse(noise("Okay.", 0.72))
        XCTAssertFalse(noise("Hi", 0.8))  // real short word with a vowel
        XCTAssertFalse(noise("Let's ship it Monday.", 0.6))
        XCTAssertFalse(noise("Revisemos el presupuesto.", 0.7))  // Spanish, accents
    }

    func testUppercaseVowelsCountAsVowels() {
        // The vowel set is lowercase and the text is case-folded before the
        // lookup, so an UPPERCASE acronym with a vowel is NOT shape-junk.
        // Pinned with no confidence, where the shape rule alone decides —
        // that is the branch the folding actually feeds.
        XCTAssertFalse(noise("AI", nil))
        XCTAssertFalse(noise("OK", nil))
        XCTAssertTrue(noise("MK", nil))  // contrast: same shape, no vowel
    }

    func testMissingConfidenceFallsBackToShape() {
        // With no confidence we only drop the obvious shape-junk, never real words.
        XCTAssertTrue(noise("R", nil))
        XCTAssertFalse(noise("You can do that one, okay?", nil))
    }
}

final class TranscriptContentPolicyTests: XCTestCase {
    func testPunctuationSymbolsAndEmojiHaveNoLexicalContent() {
        for text in ["", " ", ".", "...", "—", "¿?", "👏"] {
            XCTAssertFalse(TranscriptContentPolicy.hasLexicalContent(text), text)
        }
    }

    func testLettersDigitsAndAccentedSpeechAreLexical() {
        for text in ["a", "2026", "¿Qué pasó?", "ação", "日本語"] {
            XCTAssertTrue(TranscriptContentPolicy.hasLexicalContent(text), text)
        }
    }
}
