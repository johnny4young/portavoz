import IntelligenceKit
import PortavozCore
import XCTest

final class LiveTalkTimePolicyTests: XCTestCase {
    private func row(
        channel: AudioChannel, start: TimeInterval, end: TimeInterval
    ) -> TranscriptSegment {
        TranscriptSegment(
            meetingID: MeetingID(),
            channel: channel,
            text: "Una intervencion con contenido.",
            startTime: start,
            endTime: end,
            isFinal: true)
    }

    func testBalanceSplitsByChannelOverClosedRowsOnly() {
        let captions = [
            row(channel: .microphone, start: 0, end: 30),
            row(channel: .system, start: 30, end: 40),
            // The still-growing newest row never counts.
            row(channel: .microphone, start: 40, end: 400)
        ]
        let balance = LiveTalkTimePolicy.balance(captions)
        XCTAssertEqual(balance?.meFraction ?? 0, 0.75, accuracy: 0.001)
        XCTAssertEqual(balance?.speechSeconds ?? 0, 40, accuracy: 0.001)
    }

    func testCueWithholdsJudgmentWithoutEnoughEvidence() {
        // 75% me, but under the speech minimum: visible, never notable.
        let early = LiveTalkTimePolicy.balance([
            row(channel: .microphone, start: 0, end: 30),
            row(channel: .system, start: 30, end: 40),
            row(channel: .system, start: 40, end: 41)
        ])
        XCTAssertEqual(early?.isNotable, false)

        // Same shape with real volume: now the emphasis earns itself.
        let sustained = LiveTalkTimePolicy.balance([
            row(channel: .microphone, start: 0, end: 60),
            row(channel: .system, start: 60, end: 80),
            row(channel: .system, start: 80, end: 81)
        ])
        XCTAssertEqual(sustained?.isNotable, true)
        XCTAssertEqual(sustained?.meFraction ?? 0, 0.75, accuracy: 0.001)
    }

    func testWindowDropsOldHistoryAndEmptyInputStaysNil() {
        let balance = LiveTalkTimePolicy.balance([
            row(channel: .microphone, start: 0, end: 100),
            row(channel: .system, start: 500, end: 520),
            row(channel: .system, start: 520, end: 521)
        ])
        // The 100 s mic monologue is outside the 300 s window ending at 520.
        XCTAssertEqual(balance?.meFraction ?? 1, 0, accuracy: 0.001)

        XCTAssertNil(LiveTalkTimePolicy.balance([]))
        XCTAssertNil(
            LiveTalkTimePolicy.balance([
                row(channel: .microphone, start: 0, end: 5)
            ]),
            "one open row and nothing closed means no evidence at all")
    }
}
