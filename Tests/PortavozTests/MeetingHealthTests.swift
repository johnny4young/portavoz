import Foundation
import IntelligenceKit
import PortavozCore
import XCTest

final class MeetingHealthTests: XCTestCase {
    private let meetingID = MeetingID()
    private let ana = SpeakerID()
    private let luis = SpeakerID()

    private func segment(
        _ speaker: SpeakerID?,
        _ text: String,
        _ start: TimeInterval,
        _ end: TimeInterval
    ) -> TranscriptSegment {
        TranscriptSegment(
            meetingID: meetingID,
            speakerID: speaker,
            channel: .system,
            text: text,
            startTime: start,
            endTime: end,
            isFinal: true)
    }

    func testTalkTimeShareAndOrdering() {
        let health = MeetingHealth.compute(segments: [
            segment(ana, "hablo bastante rato seguido", 0, 30),
            segment(luis, "yo poquito", 31, 41),
        ])

        XCTAssertEqual(health.stats.count, 2)
        XCTAssertEqual(health.stats[0].speakerID, ana, "longest talker first")
        XCTAssertEqual(health.stats[0].speechSeconds, 30, accuracy: 0.001)
        XCTAssertEqual(health.stats[0].share, 0.75, accuracy: 0.001)
        XCTAssertEqual(health.stats[1].share, 0.25, accuracy: 0.001)
        XCTAssertEqual(health.totalSpeechSeconds, 40, accuracy: 0.001)
    }

    func testQuestionsCountedForBothSpanishAndEnglishMarks() {
        let health = MeetingHealth.compute(segments: [
            segment(ana, "¿nos acompañas mañana?", 0, 3),
            segment(luis, "did that answer your question?", 4, 7),
            segment(ana, "sin pregunta aquí", 8, 10),
        ])

        XCTAssertEqual(health.questionsTotal, 2)
        XCTAssertEqual(health.stats.first { $0.speakerID == ana }?.questions, 1)
        XCTAssertEqual(health.stats.first { $0.speakerID == luis }?.questions, 1)
    }

    func testOverlapCountsAsInterruptionOnlyPastThreshold() {
        let health = MeetingHealth.compute(segments: [
            segment(ana, "estaba explicando el deploy completo", 0, 10),
            // Luis starts at 6 while Ana runs to 10 → 4 s overlap: interruption.
            segment(luis, "espera espera un momento", 6, 12),
            // Ana chimes 0.2 s over Luis's tail: backchannel, not interruption.
            segment(ana, "ajá", 11.9, 12.4),
        ])

        XCTAssertEqual(health.interruptionsTotal, 1)
        XCTAssertEqual(health.stats.first { $0.speakerID == luis }?.interruptionsMade, 1)
        XCTAssertEqual(health.stats.first { $0.speakerID == ana }?.interruptionsMade, 0)
    }

    func testLongestMonologueChainsCloseSegmentsOfSameSpeaker() {
        let health = MeetingHealth.compute(segments: [
            segment(ana, "primera parte", 0, 10),
            segment(ana, "sigue tras pausa corta", 11, 25),   // gap 1 s → chains: 0–25
            segment(luis, "interviene", 26, 30),
            segment(ana, "de nuevo pero corto", 31, 36),      // separate run: 5 s
        ])

        XCTAssertEqual(
            health.stats.first { $0.speakerID == ana }?.longestMonologue ?? 0,
            25, accuracy: 0.001)
    }

    func testUnattributedSegmentsAreExcluded() {
        let health = MeetingHealth.compute(segments: [
            segment(ana, "atribuido", 0, 10),
            segment(nil, "nadie sabe de quién", 11, 30),
        ])

        XCTAssertEqual(health.stats.count, 1)
        XCTAssertEqual(health.totalSpeechSeconds, 10, accuracy: 0.001)
    }

    func testEmptyTranscriptYieldsEmptyHealth() {
        let health = MeetingHealth.compute(segments: [])
        XCTAssertTrue(health.stats.isEmpty)
        XCTAssertEqual(health.totalSpeechSeconds, 0)
    }
}
