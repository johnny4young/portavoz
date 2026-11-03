import TranscriptionKit
import XCTest

final class TranscriptionAccuracyTests: XCTestCase {
    func testPerfectHypothesisScoresZeroDespiteFormatting() {
        let report = TranscriptionAccuracy.report(
            reference: "Mañana revisamos el presupuesto, ¿de acuerdo?",
            hypothesis: "mañana revisamos el presupuesto de acuerdo")
        XCTAssertEqual(report.wordErrorRate, 0, accuracy: 0.0001)
        XCTAssertEqual(report.characterErrorRate, 0, accuracy: 0.0001)
        XCTAssertEqual(report.referenceWords, 6)
    }

    func testAccentsArePhonemicAndCountAsRealErrors() {
        // "papa" for "papá" is a transcription error in Spanish, not a
        // formatting difference — normalization must NOT strip accents.
        let report = TranscriptionAccuracy.report(
            reference: "mi papá llega mañana",
            hypothesis: "mi papa llega manana")
        XCTAssertEqual(report.wordErrorRate, 0.5, accuracy: 0.0001)
        XCTAssertGreaterThan(report.characterErrorRate, 0)
    }

    func testEachEditKindCountsOnce() {
        // reference: 4 words; one substitution + one deletion = 2/4.
        let report = TranscriptionAccuracy.report(
            reference: "el equipo cierra hoy",
            hypothesis: "el grupo cierra")
        XCTAssertEqual(report.wordErrorRate, 0.5, accuracy: 0.0001)

        // Pure insertion: rambling hypothesis against a short reference.
        let rambling = TranscriptionAccuracy.report(
            reference: "hola",
            hypothesis: "hola hola hola")
        XCTAssertEqual(rambling.wordErrorRate, 2.0, accuracy: 0.0001)
    }

    func testEmptyEdgesStayDefined() {
        XCTAssertEqual(
            TranscriptionAccuracy.report(reference: "", hypothesis: "").wordErrorRate,
            0)
        XCTAssertEqual(
            TranscriptionAccuracy.report(reference: "", hypothesis: "algo").wordErrorRate,
            1)
        XCTAssertEqual(
            TranscriptionAccuracy.report(reference: "algo", hypothesis: "").wordErrorRate,
            1)
    }

    func testCharacterRateIsSteadierThanWordRateOnSuffixFlips() {
        // One wrong gender suffix flips a whole word for WER but is a single
        // character edit for CER — the reason the bench reports both.
        let report = TranscriptionAccuracy.report(
            reference: "la propuesta quedó lista",
            hypothesis: "la propuesta quedó listo")
        XCTAssertEqual(report.wordErrorRate, 0.25, accuracy: 0.0001)
        XCTAssertLessThan(report.characterErrorRate, 0.06)
    }
}
