import Foundation
import PortavozCore
import XCTest

@testable import portavoz_app

final class RecordingLevelBufferTests: XCTestCase {
    func testBurstKeepsOnePendingSnapshotAndSchedulesOneDrain() throws {
        var buffer = RecordingLevelBuffer()
        let generation = try XCTUnwrap(buffer.submit(
            sample(channel: .microphone, peak: 0.1)))

        for index in 1..<100 {
            XCTAssertNil(buffer.submit(sample(
                channel: .microphone,
                peak: Float(index) / 100)))
        }

        XCTAssertEqual(buffer.pendingValueCount, 1)
        XCTAssertTrue(buffer.isDeliveryScheduled)
        let snapshot = try XCTUnwrap(buffer.drain(generation: generation))
        XCTAssertEqual(snapshot.microphoneLevel ?? 0, 0.99, accuracy: 0.0001)
        XCTAssertEqual(buffer.pendingValueCount, 0)
        XCTAssertFalse(buffer.isDeliveryScheduled)
    }

    func testDiagnosticsStillIngestEveryCoalescedRawSample() throws {
        var buffer = RecordingLevelBuffer()
        let generation = try XCTUnwrap(buffer.submit(
            sample(channel: .microphone, peak: 0.01)))
        for _ in 1...150 {
            _ = buffer.submit(sample(channel: .microphone, peak: 0.01))
        }
        for _ in 0...500 {
            _ = buffer.submit(sample(channel: .system, rms: 0))
        }

        let snapshot = try XCTUnwrap(buffer.drain(generation: generation))
        XCTAssertTrue(snapshot.microphoneIsLow)
        XCTAssertTrue(snapshot.hasSystemSamples)
        XCTAssertTrue(snapshot.systemAudioIsMissing)
    }

    func testCancelFencesScheduledAndFutureDelivery() throws {
        var buffer = RecordingLevelBuffer()
        let staleGeneration = try XCTUnwrap(buffer.submit(
            sample(channel: .microphone, peak: 0.4)))

        buffer.cancel()

        XCTAssertFalse(buffer.acceptsSubmissions)
        XCTAssertNil(buffer.drain(generation: staleGeneration))
        XCTAssertNil(buffer.submit(sample(channel: .microphone, peak: 0.8)))
        XCTAssertEqual(buffer.pendingValueCount, 0)
    }

    private func sample(
        channel: AudioChannel,
        peak: Float = 0,
        rms: Float = 0
    ) -> PersistedAudioLevel {
        PersistedAudioLevel(
            channel: channel,
            peak: peak,
            rms: rms,
            timestamp: 0)
    }
}

@MainActor
final class RecordingLevelRelayTests: XCTestCase {
    func testRelayPublishesOneLatestSnapshotPerCadenceWindow() async throws {
        let probe = RecordingLevelDeliveryProbe()
        let relay = RecordingLevelRelay(cadence: .milliseconds(10)) {
            probe.record($0)
        }

        for index in 0..<100 {
            relay.submit(PersistedAudioLevel(
                channel: .microphone,
                peak: Float(index) / 100,
                rms: 0,
                timestamp: TimeInterval(index)))
        }
        try await Task.sleep(for: .milliseconds(40))

        XCTAssertEqual(probe.snapshots.count, 1)
        XCTAssertEqual(
            probe.snapshots.first?.microphoneLevel ?? 0,
            0.99,
            accuracy: 0.0001)

        relay.submit(PersistedAudioLevel(
            channel: .microphone,
            peak: 0.5,
            rms: 0,
            timestamp: 100))
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(probe.snapshots.count, 2)
    }
}

@MainActor
private final class RecordingLevelDeliveryProbe {
    private(set) var snapshots: [RecordingLevelSnapshot] = []

    func record(_ snapshot: RecordingLevelSnapshot) {
        snapshots.append(snapshot)
    }
}
