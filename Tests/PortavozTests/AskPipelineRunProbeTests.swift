import ApplicationKit
import Foundation
import PortavozCore
import XCTest
@testable import portavoz_app

final class AskPipelineRunProbeTests: XCTestCase {
    func testProbePublishesEveryClosedStageAndObservableBoundary() throws {
        let probe = try makeCompletedProbe(run: 3)

        let sample = try probe.makeSample(
            corpus: Self.corpus,
            citations: Self.citations)

        XCTAssertEqual(sample.schemaVersion, 1)
        XCTAssertEqual(sample.run, 3)
        XCTAssertEqual(sample.operation, "answer")
        XCTAssertEqual(sample.outcome, "completed")
        XCTAssertEqual(
            sample.total.wallDurationMilliseconds,
            170,
            accuracy: 0.001)
        XCTAssertEqual(
            sample.firstEvidence.wallDurationMilliseconds,
            150,
            accuracy: 0.001)
        XCTAssertEqual(
            sample.firstToken.wallDurationMilliseconds,
            160,
            accuracy: 0.001)
        XCTAssertGreaterThan(sample.total.cpuTimeMilliseconds, 0)
        XCTAssertEqual(
            sample.stages.map(\.stage),
            AskPipelineStage.allCases.map(\.rawValue))
        XCTAssertTrue(sample.stages.allSatisfy {
            $0.outcome == ResourceWorkloadOutcome.completed.rawValue
                && abs($0.wallDurationMilliseconds - 10) < 0.001
        })
        XCTAssertEqual(sample.corpus.checksum, String(repeating: "c", count: 64))
        XCTAssertEqual(sample.citations.digest, String(repeating: "d", count: 64))
    }

    func testProbeRejectsARepeatedStage() throws {
        let cpu = LockedUInt64Sequence(step: 1_000_000)
        let uptime = LockedUInt64Sequence(step: 1_000_000)
        let probe = try AskPipelineRunProbe(
            run: 1,
            cpuProvider: cpu.next,
            uptimeProvider: uptime.next)
        let trace = AskPipelineTraceIdentity(operation: .answer)
        probe.receive(.started(trace))
        probe.receive(.stageStarted(AskPipelineStageSpan(
            trace: trace,
            stage: .expansion)))
        probe.receive(.stageStarted(AskPipelineStageSpan(
            trace: trace,
            stage: .expansion)))

        XCTAssertThrowsError(try probe.makeSample(
            corpus: Self.corpus,
            citations: Self.citations)
        ) {
            XCTAssertEqual(
                $0 as? AskPipelineRunProbeError,
                .duplicateStage(.expansion))
        }
    }

    func testProbeRejectsMissingFirstToken() throws {
        let cpu = LockedUInt64Sequence(step: 1_000_000)
        let uptime = LockedUInt64Sequence(step: 1_000_000)
        let probe = try AskPipelineRunProbe(
            run: 1,
            cpuProvider: cpu.next,
            uptimeProvider: uptime.next)
        let trace = AskPipelineTraceIdentity(operation: .answer)
        probe.receive(.started(trace))
        for stage in AskPipelineStage.allCases {
            let span = AskPipelineStageSpan(trace: trace, stage: stage)
            probe.receive(.stageStarted(span))
            probe.receive(.stageFinished(span, outcome: .completed))
        }
        probe.receive(.reached(trace, milestone: .firstEvidence))
        probe.receive(.finished(trace, outcome: .completed))

        XCTAssertThrowsError(try probe.makeSample(
            corpus: Self.corpus,
            citations: Self.citations)
        ) {
            XCTAssertEqual(
                $0 as? AskPipelineRunProbeError,
                .missingMilestone(.firstToken))
        }
    }

    func testProbeRejectsFirstTokenBeforeEvidence() throws {
        let cpu = LockedUInt64Sequence(step: 1_000_000)
        let uptime = LockedUInt64Sequence(step: 1_000_000)
        let probe = try AskPipelineRunProbe(
            run: 1,
            cpuProvider: cpu.next,
            uptimeProvider: uptime.next)
        let trace = AskPipelineTraceIdentity(operation: .answer)
        probe.receive(.started(trace))
        for stage in AskPipelineStage.allCases {
            let span = AskPipelineStageSpan(trace: trace, stage: stage)
            probe.receive(.stageStarted(span))
            probe.receive(.stageFinished(span, outcome: .completed))
        }
        probe.receive(.reached(trace, milestone: .firstToken))
        probe.receive(.reached(trace, milestone: .firstEvidence))
        probe.receive(.finished(trace, outcome: .completed))

        XCTAssertThrowsError(try probe.makeSample(
            corpus: Self.corpus,
            citations: Self.citations)
        ) {
            XCTAssertEqual(
                $0 as? AskPipelineRunProbeError,
                .invalidMilestoneOrder)
        }
    }

    func testProbeRejectsNonSHA256Digest() throws {
        let probe = try makeCompletedProbe(run: 1)

        XCTAssertThrowsError(try probe.makeSample(
            corpus: Self.corpus,
            citations: AskPipelineCitationEvidence(
                count: 3,
                digest: String(repeating: "z", count: 64),
                valid: true))
        ) {
            XCTAssertEqual(
                $0 as? AskPipelineRunProbeError,
                .invalidDigest)
        }
    }

    func testProbeWritesOwnerOnlyAndNeverOverwrites() throws {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(
            "AskPipelineRunProbe-\(UUID().uuidString)/ask-pipeline-2.json")
        defer {
            try? FileManager.default.removeItem(
                at: output.deletingLastPathComponent())
        }
        let probe = try makeCompletedProbe(run: 2)

        try probe.writeSample(
            to: output,
            corpus: Self.corpus,
            citations: Self.citations)

        let sample = try JSONDecoder().decode(
            AskPipelineBenchmarkSample.self,
            from: Data(contentsOf: output))
        XCTAssertEqual(sample.run, 2)
        let attributes = try FileManager.default.attributesOfItem(
            atPath: output.path)
        XCTAssertEqual(
            (attributes[.posixPermissions] as? NSNumber)?.intValue,
            0o600)
        XCTAssertThrowsError(try probe.writeSample(
            to: output,
            corpus: Self.corpus,
            citations: Self.citations)
        ) {
            XCTAssertEqual(
                $0 as? AskPipelineRunProbeError,
                .outputAlreadyExists)
        }
    }

    private func makeCompletedProbe(run: Int) throws -> AskPipelineRunProbe {
        let cpu = LockedUInt64Sequence(step: 1_000_000)
        let uptime = LockedUInt64Sequence(step: 10_000_000)
        let probe = try AskPipelineRunProbe(
            run: run,
            cpuProvider: cpu.next,
            uptimeProvider: uptime.next)
        let trace = AskPipelineTraceIdentity(operation: .answer)
        probe.receive(.started(trace))
        for stage in AskPipelineStage.allCases {
            let span = AskPipelineStageSpan(trace: trace, stage: stage)
            probe.receive(.stageStarted(span))
            probe.receive(.stageFinished(span, outcome: .completed))
        }
        probe.receive(.reached(trace, milestone: .firstEvidence))
        probe.receive(.reached(trace, milestone: .firstToken))
        probe.receive(.finished(trace, outcome: .completed))
        return probe
    }

    private static let corpus = AskPipelineCorpusEvidence(
        generation: "ask-resource-v1",
        checksum: String(repeating: "c", count: 64),
        fixtureSegmentCount: 10,
        pendingBefore: 10,
        pendingAfter: 0,
        readyBefore: false,
        readyAfter: true,
        warmup: "cold")

    private static let citations = AskPipelineCitationEvidence(
        count: 3,
        digest: String(repeating: "d", count: 64),
        valid: true)
}

private final class LockedUInt64Sequence: @unchecked Sendable {
    private let lock = NSLock()
    private let step: UInt64
    private var value: UInt64 = 0

    init(step: UInt64) {
        self.step = step
    }

    func next() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        let result = value
        value += step
        return result
    }
}
