import ApplicationKit
import XCTest

final class LocalDataLedgerTests: XCTestCase {
    func testLoadsEveryExactMetric() async throws {
        let snapshot = try await LoadLocalDataLedger(
            meetings: LedgerMeetingCounter(.value(4)),
            audio: LedgerAudioMeter(.value(1_024)),
            voices: LedgerVoiceCounter(.value(3)))(())

        XCTAssertEqual(snapshot, LocalDataLedgerSnapshot(
            audioBytes: 1_024,
            meetingCount: 4,
            voiceCount: 3))
    }

    func testOneUnavailableSourceDoesNotReplaceHealthyMetricsWithZero() async throws {
        let snapshot = try await LoadLocalDataLedger(
            meetings: LedgerMeetingCounter(.value(0)),
            audio: LedgerAudioMeter(.failure),
            voices: LedgerVoiceCounter(.value(0)))(())

        XCTAssertNil(snapshot.audioBytes)
        XCTAssertEqual(snapshot.meetingCount, 0)
        XCTAssertEqual(snapshot.voiceCount, 0)
    }

    func testCancellationRemainsCancellation() async {
        do {
            _ = try await LoadLocalDataLedger(
                meetings: LedgerMeetingCounter(.cancelled),
                audio: LedgerAudioMeter(.value(0)),
                voices: LedgerVoiceCounter(.value(0)))(())
            XCTFail("cancellation must propagate")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }
}

private enum LedgerMetric<Value: Sendable>: Sendable {
    case value(Value)
    case failure
    case cancelled

    func resolve() throws -> Value {
        switch self {
        case .value(let value): return value
        case .failure: throw LedgerFakeError.expected
        case .cancelled: throw CancellationError()
        }
    }
}

private struct LedgerMeetingCounter: LocalMeetingCounting {
    let metric: LedgerMetric<Int>
    init(_ metric: LedgerMetric<Int>) { self.metric = metric }
    func liveMeetingCount() throws -> Int { try metric.resolve() }
}

private struct LedgerAudioMeter: LocalAudioUsageMeasuring {
    let metric: LedgerMetric<Int64>
    init(_ metric: LedgerMetric<Int64>) { self.metric = metric }
    func localAudioBytes() throws -> Int64 { try metric.resolve() }
}

private struct LedgerVoiceCounter: LocalVoiceCounting {
    let metric: LedgerMetric<Int>
    init(_ metric: LedgerMetric<Int>) { self.metric = metric }
    func localVoiceCount() throws -> Int { try metric.resolve() }
}

private enum LedgerFakeError: Error {
    case expected
}
