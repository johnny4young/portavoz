import PortavozCore
import XCTest

final class CallEndDetectorTests: XCTestCase {
    private var detector = CallEndDetector()
    private var clock: TimeInterval = 0

    /// Feeds both channels in one-second chunks, as a live recording does.
    @discardableResult
    private func feed(
        seconds: Int,
        system: Float,
        microphone: Float = 0.002
    ) -> CallEndDetector.State {
        var state = detector.state
        for _ in 0..<seconds {
            state = detector.observe(level(.system, rms: system))
            state = detector.observe(level(.microphone, rms: microphone))
            clock += 1
        }
        return state
    }

    private func level(_ channel: AudioChannel, rms: Float) -> PersistedAudioLevel {
        PersistedAudioLevel(channel: channel, peak: rms * 4, rms: rms, timestamp: clock, duration: 1)
    }

    func testAsksThreeMinutesAfterTheCallGoesQuietThenStopsFiveMinutesLater() {
        feed(seconds: 60, system: 0.05)

        XCTAssertEqual(feed(seconds: 170, system: 0.0001), .listening)
        guard case .asking(let remaining) = feed(seconds: 15, system: 0.0001) else {
            return XCTFail("expected the call-ended question")
        }
        XCTAssertGreaterThan(remaining, 280)
        XCTAssertLessThanOrEqual(remaining, 300)
        XCTAssertEqual(feed(seconds: 300, system: 0.0001), .stopping)
    }

    func testRemoteSpeechWhileAskingKeepsRecording() {
        feed(seconds: 60, system: 0.05)
        feed(seconds: 200, system: 0.0001)

        XCTAssertEqual(feed(seconds: 5, system: 0.05), .listening)
        XCTAssertEqual(feed(seconds: 170, system: 0.0001), .listening)
    }

    func testTheUserTalkingInTheRoomKeepsRecording() {
        feed(seconds: 60, system: 0.05)
        feed(seconds: 200, system: 0.0001)

        XCTAssertEqual(feed(seconds: 5, system: 0.0001, microphone: 0.05), .listening)
    }

    func testAClickDoesNotCancelTheCountdown() {
        feed(seconds: 60, system: 0.05)
        feed(seconds: 200, system: 0.0001)
        detector.observe(PersistedAudioLevel(
            channel: .microphone, peak: 0.5, rms: 0.08, timestamp: clock, duration: 0.085))

        guard case .asking = feed(seconds: 1, system: 0.0001) else {
            return XCTFail("a click must not cancel the question")
        }
    }

    func testAMicrophoneOnlyMeetingNeverAsks() {
        feed(seconds: 60, system: 0.0001, microphone: 0.05)

        XCTAssertEqual(feed(seconds: 900, system: 0.0001), .listening)
    }

    func testKeepRecordingWaitsForTheRemoteSideToReturn() {
        feed(seconds: 60, system: 0.05)
        feed(seconds: 200, system: 0.0001)

        detector.keepRecording()

        XCTAssertEqual(detector.state, .listening)
        XCTAssertEqual(feed(seconds: 900, system: 0.0001), .listening)
        feed(seconds: 15, system: 0.05)
        guard case .asking = feed(seconds: 190, system: 0.0001) else {
            return XCTFail("a later quiet stretch asks again")
        }
    }

    func testInvalidChunksAreIgnored() {
        feed(seconds: 60, system: 0.05)
        let state = detector.observe(PersistedAudioLevel(
            channel: .system, peak: 0, rms: 0, timestamp: clock, duration: .infinity))

        XCTAssertEqual(state, .listening)
        XCTAssertEqual(feed(seconds: 170, system: 0.0001), .listening)
    }
}
