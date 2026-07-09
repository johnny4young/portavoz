import Foundation
import XCTest

@testable import PortavozCore
@testable import TranscriptionKit

final class CaptionCoalescerTests: XCTestCase {
    private let meetingID = MeetingID()
    private let coalescer = CaptionCoalescer()

    private func segment(
        _ text: String,
        channel: AudioChannel = .system,
        start: TimeInterval,
        end: TimeInterval,
        isFinal: Bool = false
    ) -> TranscriptSegment {
        TranscriptSegment(
            meetingID: meetingID, channel: channel, text: text,
            startTime: start, endTime: end, isFinal: isFinal)
    }

    func testMidSentenceDeltasMergeIntoOneRow() {
        var captions: [TranscriptSegment] = []
        coalescer.apply(segment("over the usual agenda", start: 0, end: 1.2), to: &captions)
        coalescer.apply(segment("pop submetric", start: 1.3, end: 2.0), to: &captions)
        coalescer.apply(segment("for our three main topics", start: 2.1, end: 3.4), to: &captions)

        XCTAssertEqual(captions.count, 1)
        XCTAssertEqual(
            captions[0].text, "over the usual agenda pop submetric for our three main topics")
        XCTAssertEqual(captions[0].startTime, 0)
        XCTAssertEqual(captions[0].endTime, 3.4)
    }

    func testRowIdentityIsStableWhileGrowing() {
        var captions: [TranscriptSegment] = []
        coalescer.apply(segment("hello", start: 0, end: 0.5), to: &captions)
        let id = captions[0].id
        coalescer.apply(segment("there", start: 0.6, end: 1.0), to: &captions)
        XCTAssertEqual(captions[0].id, id)
    }

    func testChannelChangeStartsNewRow() {
        var captions: [TranscriptSegment] = []
        coalescer.apply(segment("their turn", channel: .system, start: 0, end: 1), to: &captions)
        coalescer.apply(segment("my turn", channel: .microphone, start: 1.1, end: 2), to: &captions)

        XCTAssertEqual(captions.count, 2)
        XCTAssertEqual(captions[0].channel, .system)
        XCTAssertEqual(captions[1].channel, .microphone)
    }

    func testPausedSpeakerStaysOnOneRowUntilSentenceCloses() {
        var captions: [TranscriptSegment] = []
        // 4 s pause mid-sentence: still the same intervention.
        coalescer.apply(segment("and the numbers show", start: 0, end: 1), to: &captions)
        coalescer.apply(segment("a clear regression.", start: 5, end: 6.5), to: &captions)
        XCTAssertEqual(captions.count, 1)

        // Sentence closed + 3 s pause: new intervention.
        coalescer.apply(segment("Moving on.", start: 9.5, end: 10.4), to: &captions)
        XCTAssertEqual(captions.count, 2)
    }

    func testQuickMicrophoneFollowUpAfterSentenceKeepsFlowing() {
        var captions: [TranscriptSegment] = []
        coalescer.apply(
            segment("it's around.", channel: .microphone, start: 0, end: 1),
            to: &captions)
        coalescer.apply(
            segment("10:40 PM.", channel: .microphone, start: 1.4, end: 2.2),
            to: &captions)
        XCTAssertEqual(captions.count, 1)
        XCTAssertEqual(captions[0].text, "it's around. 10:40 PM.")
    }

    func testSystemSentencePauseStartsNewOthersRow() {
        var captions: [TranscriptSegment] = []
        coalescer.apply(segment("That answered the question.", start: 0, end: 1), to: &captions)
        coalescer.apply(segment("Another point from the next speaker.", start: 1.8, end: 2.8), to: &captions)

        XCTAssertEqual(captions.count, 2)
        XCTAssertEqual(captions.map(\.channel), [.system, .system])
    }

    func testLongSilenceStartsNewRowEvenMidSentence() {
        var captions: [TranscriptSegment] = []
        coalescer.apply(segment("and then we", start: 0, end: 1), to: &captions)
        coalescer.apply(segment("resumed after the break", start: 9, end: 10.5), to: &captions)
        XCTAssertEqual(captions.count, 2)
    }

    func testOverlongRowClosesAtNextDelta() {
        var captions: [TranscriptSegment] = []
        let long = String(repeating: "palabra ", count: 40)  // > 280 chars
        coalescer.apply(segment(long, start: 0, end: 5), to: &captions)
        coalescer.apply(segment("continues", start: 5.2, end: 6), to: &captions)
        XCTAssertEqual(captions.count, 2)
    }

    func testPunctuationDeltaGluesWithoutSpace() {
        var captions: [TranscriptSegment] = []
        coalescer.apply(segment("which I think is normal", start: 0, end: 1.5), to: &captions)
        coalescer.apply(segment(". And there's one spike", start: 1.6, end: 3), to: &captions)
        XCTAssertEqual(captions[0].text, "which I think is normal. And there's one spike")
    }

    func testEmptyOrWhitespaceDeltasAreDropped() {
        var captions: [TranscriptSegment] = []
        coalescer.apply(segment("   ", start: 0, end: 0.5), to: &captions)
        XCTAssertTrue(captions.isEmpty)
    }

    func testStandalonePunctuationDeltasAreDropped() {
        var captions: [TranscriptSegment] = []
        coalescer.apply(segment(".", channel: .microphone, start: 0, end: 0.2), to: &captions)
        XCTAssertTrue(captions.isEmpty)
    }

    func testPunctuationOnlyDeltaCompletesCurrentRow() {
        var captions: [TranscriptSegment] = []
        coalescer.apply(segment("the number looks normal", start: 0, end: 1), to: &captions)
        coalescer.apply(segment(".", start: 1.1, end: 1.2), to: &captions)

        XCTAssertEqual(captions.count, 1)
        XCTAssertEqual(captions[0].text, "the number looks normal.")
    }

    func testIsFinalTracksNewestDelta() {
        var captions: [TranscriptSegment] = []
        coalescer.apply(segment("draft text", start: 0, end: 1, isFinal: false), to: &captions)
        coalescer.apply(segment("confirmed", start: 1.1, end: 2, isFinal: true), to: &captions)
        XCTAssertTrue(captions[0].isFinal)
    }
}
