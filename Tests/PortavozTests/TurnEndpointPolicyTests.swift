import Foundation
import IntelligenceKit
import PortavozCore
import XCTest

/// D138 stage 0: the deterministic end-of-turn endpointer. Closing is
/// delta-driven, so these rules are what stands between "a question followed
/// by silence" and "no card until someone speaks again".
final class TurnEndpointPolicyTests: XCTestCase {

    // MARK: - Candidate gates (must mirror the real-close gates exactly)

    func testRemoteQuestionAfterSilenceIsACandidate() {
        XCTAssertTrue(TurnEndpointPolicy.isTurnEndCandidate(
            channel: .system,
            text: "¿Cuándo sale el rollout a producción?",
            confidence: 0.9,
            ownerName: nil))
    }

    func testMicrophoneRowsAreNeverCandidates() {
        // Live cards answer the ROOM, not the user — same rule as the close.
        XCTAssertFalse(TurnEndpointPolicy.isTurnEndCandidate(
            channel: .microphone,
            text: "¿Cuándo sale el rollout a producción?",
            confidence: 0.9,
            ownerName: nil))
    }

    func testGarbledLowConfidenceTextDoesNotBurnAModelCall() {
        XCTAssertFalse(TurnEndpointPolicy.isTurnEndCandidate(
            channel: .system,
            text: "el qué no",
            confidence: 0.2,
            ownerName: nil))
    }

    func testPlainStatementsReachTheCalibratedClassifier() {
        XCTAssertTrue(TurnEndpointPolicy.isTurnEndCandidate(
            channel: .system,
            text: "El rollout quedó agendado para el viernes.",
            confidence: 0.9,
            ownerName: nil))
    }

    func testOwnerMentionOpensTheGateWithoutAQuestionMark() {
        // "Asked you" (D26): being addressed by name is a turn worth
        // detecting even when the sentence is imperative.
        XCTAssertTrue(TurnEndpointPolicy.isTurnEndCandidate(
            channel: .system,
            text: "Johnny, cuéntanos del despliegue de la semana pasada.",
            confidence: 0.9,
            ownerName: "Johnny Young"))
        XCTAssertTrue(TurnEndpointPolicy.isTurnEndCandidate(
            channel: .system,
            text: "Cuéntanos del despliegue de la semana pasada.",
            confidence: 0.9,
            ownerName: "Johnny Young"))
    }

    // MARK: - Detection dedup (row identity + text growth)

    func testFirstDetectionOnARowAlwaysRuns() {
        XCTAssertTrue(TurnEndpointPolicy.shouldDetect(
            after: nil, rowID: UUID(), textCount: 40))
    }

    func testRealCloseWithUnchangedTextAddsNothing() {
        // The speculative detection already ran on this exact material; the
        // close must not burn a second classifier call.
        let rowID = UUID()
        let mark = SpeculativeTurnMark(rowID: rowID, textCount: 40)
        XCTAssertFalse(TurnEndpointPolicy.shouldDetect(
            after: mark, rowID: rowID, textCount: 40))
    }

    func testGrownTextIsAGenuinelyNewCandidate() {
        // The question was only half-spoken when the deadline fired; a late
        // delta completed it, so the close must re-detect.
        let rowID = UUID()
        let mark = SpeculativeTurnMark(rowID: rowID, textCount: 40)
        XCTAssertTrue(TurnEndpointPolicy.shouldDetect(
            after: mark, rowID: rowID, textCount: 62))
    }

    func testADifferentRowIsUnaffectedByThePreviousMark() {
        let mark = SpeculativeTurnMark(rowID: UUID(), textCount: 40)
        XCTAssertTrue(TurnEndpointPolicy.shouldDetect(
            after: mark, rowID: UUID(), textCount: 40))
    }

    // MARK: - The deadline constant is anchored to the pipeline's numbers

    func testSilenceDeadlineExceedsTheWorstCaseStructuralWindowLatency() {
        // Parakeet's live window is 1.0 s chunk + 0.4 s right context: a
        // delta can arrive up to 1.4 s after the words were spoken. Firing
        // earlier than that would speculate on rows that are still growing
        // in the normal case.
        let structuralWorstCase: TimeInterval = 1.4
        XCTAssertGreaterThan(
            TurnEndpointPolicy.silenceSeconds, structuralWorstCase,
            "the deadline must outwait the ASR window, not race it")
        XCTAssertLessThanOrEqual(
            TurnEndpointPolicy.silenceSeconds, 3.0,
            "much beyond this and the endpointer stops being an improvement")
    }
}
