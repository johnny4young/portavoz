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

    func testOlderLongOverlapSurvivesANewerEndedSegment() {
        let health = MeetingHealth.compute(segments: [
            segment(ana, "explicación larga", 0, 10),
            segment(ana, "aclaración breve", 5, 6),
            // The nearest prior segment ended, but the older one still spans
            // Luis's turn. An early exit must consider the whole prior prefix.
            segment(luis, "quiero interrumpir", 7, 8),
        ])

        XCTAssertEqual(health.interruptionsTotal, 1)
        XCTAssertEqual(health.stats.first { $0.speakerID == luis }?.interruptionsMade, 1)
    }

    func testPrefixBoundMatchesExhaustiveReferenceAcrossDenseTimelines() {
        let speakers = [ana, luis, SpeakerID(), SpeakerID()]
        var state: UInt64 = 0x504F_5254_4156_4F5A
        func nextUnit() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1
            return Double(state >> 11) / Double(UInt64.max >> 11)
        }

        for caseIndex in 0..<200 {
            let segments = (0..<80).map { index in
                let start = nextUnit() * 300
                // Regular short turns plus deterministic long spans exercise
                // dense overlap and the hidden-older-segment edge repeatedly.
                let duration = index.isMultiple(of: 13)
                    ? 30 + nextUnit() * 90
                    : 0.1 + nextUnit() * 12
                return segment(
                    speakers[Int(nextUnit() * Double(speakers.count)) % speakers.count],
                    "case \(caseIndex) segment \(index)",
                    start,
                    start + duration)
            }
            let expected = exhaustiveInterruptions(in: segments)
            let actual = MeetingHealth.compute(segments: segments)

            XCTAssertEqual(actual.interruptionsTotal, expected.values.reduce(0, +))
            for speaker in speakers {
                XCTAssertEqual(
                    actual.stats.first { $0.speakerID == speaker }?.interruptionsMade ?? 0,
                    expected[speaker] ?? 0,
                    "mismatch in deterministic overlap case \(caseIndex)")
            }
        }
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

    private func exhaustiveInterruptions(
        in segments: [TranscriptSegment]
    ) -> [SpeakerID: Int] {
        let attributed = segments
            .filter { $0.speakerID != nil && $0.endTime > $0.startTime }
            .sorted { $0.startTime < $1.startTime }
        var counts: [SpeakerID: Int] = [:]
        for (index, segment) in attributed.enumerated() {
            guard let interrupter = segment.speakerID else { continue }
            for previous in attributed[..<index].reversed() {
                if previous.endTime <= segment.startTime { continue }
                guard let interrupted = previous.speakerID, interrupted != interrupter else {
                    continue
                }
                if min(previous.endTime, segment.endTime) - segment.startTime >= 0.5 {
                    counts[interrupter, default: 0] += 1
                    break
                }
            }
        }
        return counts
    }
}
