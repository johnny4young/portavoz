import ApplicationKit
import Foundation
import PortavozCore
import XCTest

@testable import portavoz_app

final class MicrophoneSpeechGateTests: XCTestCase {
    func testSpeechNeedsAMomentToEnterAndAPauseLongerThanABreathToLeave() {
        var gate = MicrophoneSpeechGate()
        XCTAssertFalse(gate.observe(peak: 0.5, duration: 0.1), "a click is not speech")
        XCTAssertTrue(gate.observe(peak: 0.5, duration: 0.1))
        XCTAssertTrue(gate.observe(peak: 0.001, duration: 0.6), "a pause between words keeps speaking")
        XCTAssertTrue(gate.observe(peak: 0.3, duration: 0.05))
        XCTAssertTrue(gate.observe(peak: 0.001, duration: 1.1))
        XCTAssertFalse(gate.observe(peak: 0.001, duration: 0.2))
        XCTAssertFalse(gate.observe(peak: 0.5, duration: .nan), "invalid durations change nothing")
        XCTAssertFalse(gate.observe(peak: MicrophoneSpeechGate.threshold / 2, duration: 1), "below the floor is quiet")
    }

    func testTheLevelSnapshotCarriesTheGate() {
        var buffer = RecordingLevelBuffer()
        for index in 0..<4 {
            _ = buffer.submit(PersistedAudioLevel(
                channel: .microphone, peak: 0.2, rms: 0.05, timestamp: Double(index) / 10, duration: 0.1))
        }
        XCTAssertEqual(buffer.drain(generation: 0)?.microphoneIsSpeaking, true)
    }
}

@MainActor
final class RecordingLiveVoicesModelTests: XCTestCase {
    private let meetingID = MeetingID()

    private func source(rows: Int, youSpeaking: Bool = false) -> LiveVoiceSource {
        LiveVoiceSource(
            captions: (0..<rows).map {
                TranscriptSegment(
                    meetingID: meetingID, channel: $0.isMultiple(of: 2) ? .microphone : .system,
                    text: "row", startTime: Double($0) * 2, endTime: Double($0) * 2 + 1.5, isFinal: true)
            },
            labels: [:], latestTurn: nil, youSpeaking: youSpeaking, now: Double(rows) * 2)
    }

    func testRepeatedLevelDeliveriesAskForOneRefreshPerFlip() async {
        let sleeps = SleepLog()
        var reads = 0
        let model = RecordingLiveVoicesModel(sleep: { await sleeps.record($0) })
        model.connect {
            reads += 1
            return self.source(rows: 2, youSpeaking: model.youSpeaking)
        }

        for _ in 0..<200 { model.setYouSpeaking(false) }
        await Task.yield()
        XCTAssertEqual(reads, 0, "an unchanged gate is not a refresh")

        for _ in 0..<200 { model.setYouSpeaking(true) }
        await settle()
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(model.stage.current, LiveVoiceStage.youKey)
    }

    func testRequestsCoalesceAndStaySecondsApart() async {
        let sleeps = SleepLog()
        var reads = 0
        var rows = 1
        let model = RecordingLiveVoicesModel(sleep: { await sleeps.record($0) })
        model.connect {
            reads += 1
            return self.source(rows: rows)
        }

        model.requestRefresh()
        await settle()
        XCTAssertEqual(reads, 1)

        for _ in 0..<50 {
            rows += 1
            model.requestRefresh()
        }
        await settle()
        XCTAssertEqual(reads, 2, "a burst of captions is one refresh with the newest rows")
        XCTAssertEqual(model.stage.voices.map(\.talkSeconds).reduce(0, +), Double(rows) * 1.5)
        let delays = await sleeps.delays
        XCTAssertTrue(
            delays.contains { $0 > .milliseconds(900) && $0 <= RecordingLiveVoicesModel.minimumInterval },
            "the second refresh waits out the interval: \(delays)")
    }

    func testIntervalPolicy() async {
        let now = ContinuousClock.now
        XCTAssertEqual(RecordingLiveVoicesModel.delay(since: nil, now: now), .zero)
        XCTAssertEqual(RecordingLiveVoicesModel.delay(since: now - .seconds(5), now: now), .zero)
        XCTAssertEqual(RecordingLiveVoicesModel.delay(since: now - .milliseconds(250), now: now), .milliseconds(750))
    }

    func testResetDropsTheLiveStageForStop() async {
        let model = RecordingLiveVoicesModel(sleep: { _ in })
        model.connect { self.source(rows: 3, youSpeaking: true) }
        model.setYouSpeaking(true)
        await settle()
        XCTAssertFalse(model.stage.isEmpty)

        model.reset()
        XCTAssertEqual(model.stage, .empty)
        XCTAssertTrue(model.cast.voices.isEmpty)
        XCTAssertFalse(model.youSpeaking)
    }

    func testANewRecordingStartsWithoutLiveVoicesAndNoSourceWhileIdle() async {
        let controller = RecordingController(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        XCTAssertNil(controller.liveVoiceSource(), "nothing is live before a recording starts")
        XCTAssertEqual(controller.liveVoices.stage, .empty)
    }

    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }
}

private actor SleepLog {
    private(set) var delays: [Duration] = []

    func record(_ delay: Duration) {
        delays.append(delay)
    }
}
