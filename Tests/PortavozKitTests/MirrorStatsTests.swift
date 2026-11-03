import XCTest

@testable import ApplicationKit

final class MirrorStatsTests: XCTestCase {
    func testQualifiesNeedsTwoSpeakersAndFiveMinutes() {
        XCTAssertTrue(MirrorStats.qualifies(speakerCount: 2, seconds: 300))
        XCTAssertFalse(MirrorStats.qualifies(speakerCount: 1, seconds: 1200))
        XCTAssertFalse(MirrorStats.qualifies(speakerCount: 3, seconds: 120))
    }

    func testNotableDeltaThreshold() {
        XCTAssertTrue(MirrorStats.isNotable(myShare: 0.20, average: 0.40))  // 20 pts
        XCTAssertFalse(MirrorStats.isNotable(myShare: 0.38, average: 0.42))  // 4 pts
    }

    func testSynthesisIsFactualAndCarriesNoVerdict() {
        let line = MirrorStats.synthesis(
            myShare: 0.20, average: 0.45, questions: 2, language: "en")
        XCTAssertEqual(line, "You listened more than usual. You asked 2 questions.")
        // No evaluative adjectives leak in.
        for banned in ["too", "bad", "poor", "should", "only"] {
            XCTAssertFalse(line.lowercased().contains(banned), "verdict word leaked: \(banned)")
        }
    }

    func testSynthesisSpanishAndSingularQuestion() {
        let line = MirrorStats.synthesis(
            myShare: 0.70, average: 0.45, questions: 1, language: "es")
        XCTAssertEqual(line, "Hablaste más de lo habitual. Hiciste 1 pregunta.")
    }

    func testSynthesisWithoutAverageJustStatesFacts() {
        let line = MirrorStats.synthesis(
            myShare: 0.5, average: nil, questions: 0, language: "en")
        XCTAssertEqual(line, "Your talk balance was close to your usual. You asked no questions.")
    }
}
