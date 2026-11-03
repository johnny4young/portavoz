import Foundation
import PortavozCore
import XCTest
@testable import TranscriptionKit
@testable import portavoz_app

final class BenchLiveTranscriptionWorkProbeTests: XCTestCase {
    private func arguments(_ output: String = "/tmp/live-work") -> [String] {
        ["Portavoz", "-use-temp-store", "--bench-record", "60",
         "--bench-resource-synthetic-capture", "--bench-resource-live-work",
         "--bench-resource-output", output, "--bench-resource-run", "1"]
    }

    private func sample(
        _ channel: AudioChannel,
        frames: Int = 960_000,
        rate: Double = 16_000,
        outcome: ParakeetLiveWorkSample.Outcome = .completed,
        rejected: Bool = false
    ) throws -> ParakeetLiveWorkSample {
        let probe = ParakeetLiveWorkProbe()
        probe.begin(.feed)
        probe.input(frames: frames, sampleRate: rate, channel: channel, accepted: true)
        if rejected { probe.input(frames: 1, sampleRate: rate, channel: channel, accepted: false) }
        probe.update(tokens: 3, timings: 3, confirmed: true)
        probe.begin(.finish)
        probe.begin(.updateDrain)
        probe.begin(.cleanup)
        return try XCTUnwrap(probe.finish(outcome: outcome))
    }

    func testRequiresExplicitDisposableSyntheticUniqueBoundedRequest() throws {
        XCTAssertNil(try BenchLiveTranscriptionWorkProbe.requested(arguments: [], durationSeconds: 60))
        XCTAssertNil(try BenchLiveTranscriptionWorkProbe.requested(
            arguments: arguments().filter { $0 != "--bench-resource-live-work" }, durationSeconds: 60))
        for invalid in [
            arguments().filter { $0 != "-use-temp-store" },
            arguments().filter { $0 != "--bench-resource-synthetic-capture" },
            arguments("relative"), arguments() + ["--bench-resource-run", "2"],
            arguments() + ["--bench-resource-live-work"],
            arguments() + ["--bench-resource-recording-indexing", "--bench-resource-recording-batch"],
            arguments().map { $0 == "1" ? "101" : $0 }
        ] {
            XCTAssertThrowsError(try BenchLiveTranscriptionWorkProbe(arguments: invalid, durationSeconds: 60))
        }
        XCTAssertThrowsError(try BenchLiveTranscriptionWorkProbe(arguments: arguments(), durationSeconds: 30))
    }

    func testMissingDuplicateExtraAndInvalidTerminalsFailClosed() throws {
        let mic = try sample(.microphone)
        let system = try sample(.system)
        let incomplete = try BenchLiveTranscriptionWorkProbe(arguments: arguments(), durationSeconds: 60)
        XCTAssertThrowsError(try incomplete.document())
        for samples in [
            [mic], [mic, mic], [mic, system, system],
            [mic, try sample(.system, frames: 959_999)],
            [mic, try sample(.system, rate: 48_000)],
            [mic, try sample(.system, outcome: .cancelled)],
            [mic, try sample(.system, outcome: .failed)],
            [mic, try sample(.system, rejected: true)]
        ] {
            let probe = try BenchLiveTranscriptionWorkProbe(arguments: arguments(), durationSeconds: 60)
            for sample in samples { probe.receive(sample) }
            XCTAssertThrowsError(try probe.document())
        }
    }

    func testWritesExactTwoChannelSidecarWithoutOverwriting() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let probe = try BenchLiveTranscriptionWorkProbe(arguments: arguments(root.path), durationSeconds: 60)
        probe.receive(try sample(.system))
        probe.receive(try sample(.microphone))
        let document = try probe.document()
        XCTAssertEqual(document.samples.compactMap(\.channel), [.microphone, .system])
        XCTAssertFalse(document.backendAttemptCountsAvailable)
        XCTAssertTrue(document.observationComplete)
        XCTAssertFalse(document.overflowed)
        XCTAssertEqual(document.expectedInputFramesPerChannel, 960_000)
        try probe.write()
        let path = root.appendingPathComponent("recording-live-work-1.json")
        let original = try Data(contentsOf: path)
        XCTAssertThrowsError(try probe.write())
        XCTAssertEqual(try Data(contentsOf: path), original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [path.lastPathComponent])
        let permissions = try FileManager.default.attributesOfItem(atPath: path.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
        let decoded = try JSONDecoder().decode(BenchLiveTranscriptionWorkProbe.Document.self, from: original)
        XCTAssertEqual(decoded.samples, document.samples)
        XCTAssertEqual(decoded.kind, "parakeet-live-work")
        XCTAssertEqual(decoded.schemaVersion, 1)
    }

    func testIncompleteRunRetainsAdverseCountsWithoutAdmissionOrLaterRepair() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let probe = try BenchLiveTranscriptionWorkProbe(arguments: arguments(root.path), durationSeconds: 60)
        probe.receive(try sample(.microphone, frames: 123, outcome: .cancelled))
        XCTAssertThrowsError(try probe.write()) { error in
            XCTAssertEqual(error as? BenchLiveWorkError, .incompleteObservation)
        }
        let output = root.appendingPathComponent("recording-live-work-1.json")
        let adverse = root.appendingPathComponent("recording-live-work-1.adverse.json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        let data = try Data(contentsOf: adverse)
        let document = try JSONDecoder().decode(BenchLiveTranscriptionWorkProbe.Document.self, from: data)
        XCTAssertFalse(document.observationComplete)
        XCTAssertEqual(document.samples.count, 1)
        XCTAssertEqual(document.samples.first?.inputFrames, 123)
        XCTAssertEqual(document.samples.first?.outcome, .cancelled)
        let repair = try BenchLiveTranscriptionWorkProbe(arguments: arguments(root.path), durationSeconds: 60)
        repair.receive(try sample(.microphone))
        repair.receive(try sample(.system))
        XCTAssertThrowsError(try repair.write()) { error in
            XCTAssertEqual(error as? BenchLiveWorkError, .outputAlreadyExists)
        }
        XCTAssertEqual(try Data(contentsOf: adverse), data)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [adverse.lastPathComponent])
    }

    func testFailedOwnerCannotPublishCompleteEvidenceEvenWithHealthyStreamCounts() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let probe = try BenchLiveTranscriptionWorkProbe(arguments: arguments(root.path), durationSeconds: 60)
        probe.receive(try sample(.microphone))
        probe.receive(try sample(.system))
        XCTAssertThrowsError(try probe.write(ownerCompleted: false))
        let path = root.appendingPathComponent("recording-live-work-1.adverse.json")
        let document = try JSONDecoder().decode(
            BenchLiveTranscriptionWorkProbe.Document.self, from: Data(contentsOf: path))
        XCTAssertFalse(document.ownerCompleted)
        XCTAssertFalse(document.observationComplete)
        XCTAssertEqual(document.samples.count, 2)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("recording-live-work-1.json").path))
    }

    func testScenarioFamiliesRemainSeparate() throws {
        for (flag, scenario) in [
            ("--bench-resource-recording-indexing", "recording-plus-indexing"),
            ("--bench-resource-recording-batch", "recording-plus-batch")
        ] {
            let probe = try BenchLiveTranscriptionWorkProbe(
                arguments: arguments() + [flag], durationSeconds: 60)
            probe.receive(try sample(.microphone))
            probe.receive(try sample(.system))
            XCTAssertEqual(try probe.document().scenario, scenario)
        }
    }
}
