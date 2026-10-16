import Foundation
import PortavozCore
import XCTest

@testable import TranscriptionKit

final class CaptionCoalescerTokenModeTests: XCTestCase {
    private let meetingID = MeetingID()

    private func token(
        _ text: String, _ mode: LiveTranscriptUpdateMode, start: TimeInterval, end: TimeInterval
    ) -> TranscriptSegment {
        TranscriptSegment(
            meetingID: meetingID, channel: .microphone, text: text,
            startTime: start, endTime: end, confidence: 0.9, isFinal: true, liveUpdateMode: mode)
    }

    func testSubwordContinuationExtendsAFullRowInsteadOfSplittingTheWord() {
        let coalescer = CaptionCoalescer()
        let words = String(repeating: "palabra ", count: 40) + "anal"
        var captions = [token(words, .tokenDelta, start: 0, end: 30)]
        XCTAssertGreaterThanOrEqual(captions[0].text.count, coalescer.maxRowCharacters)

        coalescer.apply(token("izando", .tokenContinuation, start: 30.1, end: 30.4), to: &captions)

        XCTAssertEqual(captions.count, 1, "A subword must never open its own row")
        XCTAssertTrue(captions[0].text.hasSuffix("analizando"))
    }

    func testSubwordContinuationAfterALongPauseStaysInTheWord() {
        let coalescer = CaptionCoalescer()
        var captions = [token("Estamos anal", .tokenDelta, start: 0, end: 1)]

        coalescer.apply(
            token("izando", .tokenContinuation, start: 1 + coalescer.maxGapSeconds + 1, end: 9),
            to: &captions)

        XCTAssertEqual(captions.map(\.text), ["Estamos analizando"])
    }

    func testCommittedPunctuationRunLongerThanThreeCharactersIsKept() {
        let coalescer = CaptionCoalescer()
        var captions = [token("¿De verdad", .tokenDelta, start: 0, end: 1)]

        coalescer.apply(token("?!»”", .tokenContinuation, start: 1, end: 1.1), to: &captions)

        XCTAssertEqual(captions.map(\.text), ["¿De verdad?!»”"])
    }
}
