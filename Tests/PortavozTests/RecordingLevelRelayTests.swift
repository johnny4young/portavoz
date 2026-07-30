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

    func testOneCeilingPeakDoesNotReportClipping() throws {
        var buffer = RecordingLevelBuffer()
        let generation = try XCTUnwrap(buffer.submit(
            sample(channel: .system, peak: 1, rms: 0.4)))
        for _ in 1...300 {
            _ = buffer.submit(sample(channel: .system, peak: 0.8, rms: 0.4))
        }

        let snapshot = try XCTUnwrap(buffer.drain(generation: generation))
        XCTAssertFalse(snapshot.systemAudioIsClipping)
    }

    func testSustainedCeilingReportsClippingAndCleanAudioRecovers() throws {
        var buffer = RecordingLevelBuffer()
        let generation = try XCTUnwrap(buffer.submit(
            sample(channel: .system, peak: 1, rms: 0.4)))
        for _ in 1..<200 {
            _ = buffer.submit(sample(channel: .system, peak: 1, rms: 0.4))
        }

        var snapshot = try XCTUnwrap(buffer.drain(generation: generation))
        XCTAssertTrue(snapshot.systemAudioIsClipping)

        let recoveryGeneration = try XCTUnwrap(buffer.submit(
            sample(channel: .system, peak: 0.8, rms: 0.4)))
        for _ in 1...400 {
            _ = buffer.submit(sample(channel: .system, peak: 0.8, rms: 0.4))
        }
        snapshot = try XCTUnwrap(buffer.drain(generation: recoveryGeneration))
        XCTAssertFalse(snapshot.systemAudioIsClipping)
    }

    func testCeilingPolicyUsesCapturedTimeAcrossCallbackSizes() {
        for duration in [0.005, 0.02, 0.2] {
            var detector = SustainedCeilingDetector()
            let count = Int(ceil(
                SustainedCeilingDetector.minimumObservedDuration / duration))
            for _ in 0..<count {
                _ = detector.observe(peak: 1, duration: duration)
            }
            XCTAssertTrue(
                detector.isClipping,
                "callback duration \(duration) must not change the threshold")
        }
    }

    func testInvalidDurationDoesNotAdvanceCeilingPolicy() {
        var detector = SustainedCeilingDetector()
        let invalidDurations: [TimeInterval] = [
            0, -.infinity, .infinity, .nan,
        ]
        for duration in invalidDurations {
            XCTAssertFalse(detector.observe(peak: 1, duration: duration))
        }
        XCTAssertFalse(detector.isClipping)
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
        rms: Float = 0,
        duration: TimeInterval = 0.01
    ) -> PersistedAudioLevel {
        PersistedAudioLevel(
            channel: channel,
            peak: peak,
            rms: rms,
            timestamp: 0,
            duration: duration)
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
                timestamp: TimeInterval(index),
                duration: 0.01))
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
            timestamp: 100,
            duration: 0.01))
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
