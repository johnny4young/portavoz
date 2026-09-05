import ApplicationKit
import Foundation
import XCTest

@testable import portavoz_app

final class MeetingMemoryGraphQueryRunProbeTests: XCTestCase {
    func testConfigurationRequiresBoundedExplicitRunAndOutput() throws {
        XCTAssertNil(try BenchMemoryGraphQueryConfiguration.requested(
            arguments: ["portavoz-app"]))
        XCTAssertThrowsError(try BenchMemoryGraphQueryConfiguration.requested(
            arguments: ["portavoz-app", "--bench-graph-queries"])) {
                XCTAssertEqual(
                    $0 as? BenchMemoryGraphQueryError,
                    .missingOutput)
            }
        XCTAssertThrowsError(try BenchMemoryGraphQueryConfiguration.requested(
            arguments: [
                "portavoz-app",
                "--bench-graph-queries",
                "--bench-graph-output", "--bench-graph-run", "3",
            ])) {
                XCTAssertEqual(
                    $0 as? BenchMemoryGraphQueryError,
                    .missingOutput)
            }
        XCTAssertThrowsError(try BenchMemoryGraphQueryConfiguration.requested(
            arguments: [
                "portavoz-app",
                "--bench-graph-queries",
                "--bench-graph-output", "/tmp/graph.json",
            ])) {
                XCTAssertEqual(
                    $0 as? BenchMemoryGraphQueryError,
                    .invalidRun)
            }
        XCTAssertThrowsError(try BenchMemoryGraphQueryConfiguration.requested(
            arguments: [
                "portavoz-app",
                "--bench-graph-queries",
                "--bench-graph-output", "/tmp/graph.json",
                "--bench-graph-run", "0",
            ])) {
                XCTAssertEqual(
                    $0 as? BenchMemoryGraphQueryError,
                    .invalidRun)
            }
        XCTAssertThrowsError(try BenchMemoryGraphQueryConfiguration.requested(
            arguments: [
                "portavoz-app",
                "--bench-graph-queries",
                "--bench-graph-output", "/tmp/graph.json",
                "--bench-graph-run", "3",
                "--bench-graph-iterations", "4",
            ])) {
                XCTAssertEqual(
                    $0 as? BenchMemoryGraphQueryError,
                    .invalidIterations)
            }

        let configuration = try XCTUnwrap(
            BenchMemoryGraphQueryConfiguration.requested(arguments: [
                "portavoz-app",
                "--bench-graph-queries",
                "--bench-graph-output", "/tmp/graph.json",
                "--bench-graph-run", "3",
                "--bench-graph-iterations", "7",
            ]))
        XCTAssertEqual(configuration.outputURL.path, "/tmp/graph.json")
        XCTAssertEqual(configuration.run, 3)
        XCTAssertEqual(configuration.iterationsPerJob, 7)
    }

    func testReceiptKeepsStableTaxonomyAndNearestRankSummaries() throws {
        let clock = ProbeClockSequence(values: Self.clockValues())
        let probe = try MeetingMemoryGraphQueryRunProbe(
            run: 2,
            iterationsPerJob: 5,
            clock: clock.next)
        let traceToExclude = MeetingMemoryGraphQueryTrace(
            id: UUID(uuidString: "A1000000-0000-4000-8000-000000000001")!,
            job: .commitmentBlockers)
        Self.feed(
            probe,
            iterations: 5,
            firstTrace: traceToExclude)

        let receipt = try probe.makeReceipt(
            host: Self.validHost,
            fixtureGeneration: "public-synthetic-graph-product-v1")

        XCTAssertEqual(receipt.schemaVersion, 1)
        XCTAssertEqual(receipt.run, 2)
        XCTAssertEqual(receipt.iterationsPerJob, 5)
        XCTAssertEqual(
            receipt.jobs.map(\.job),
            MeetingMemoryGraphQueryJob.allCases.map(\.rawValue))
        XCTAssertTrue(receipt.jobs.allSatisfy {
            $0.outcome == MeetingMemoryGraphQueryOutcome.facts.rawValue
                && $0.sampleCount == 5
                && $0.wall.p50Milliseconds == 3
                && $0.wall.p95Milliseconds == 5
                && $0.wall.maximumMilliseconds == 5
        })

        let encoded = try JSONEncoder().encode(receipt)
        let text = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        XCTAssertFalse(text.contains(traceToExclude.id.uuidString))
        XCTAssertFalse(text.contains("Ana"))
        XCTAssertFalse(text.contains("Planning baseline"))
    }

    func testDuplicateAndUnmatchedTracesFailClosed() throws {
        let duplicateClock = ProbeClockSequence(values: [
            .init(uptimeNanoseconds: 0, cpuAbsoluteTime: 0),
            .init(uptimeNanoseconds: 1, cpuAbsoluteTime: 1),
        ])
        let duplicateProbe = try MeetingMemoryGraphQueryRunProbe(
            run: 1,
            iterationsPerJob: 5,
            clock: duplicateClock.next)
        let trace = MeetingMemoryGraphQueryTrace(job: .decisionHistory)
        duplicateProbe.receive(.started(trace))
        duplicateProbe.receive(.started(trace))
        XCTAssertThrowsError(try duplicateProbe.makeReceipt(
            host: Self.validHost,
            fixtureGeneration: "public-synthetic-graph-product-v1")) {
                XCTAssertEqual(
                    $0 as? MeetingMemoryGraphQueryRunProbeError,
                    .duplicateTrace)
            }

        let unmatchedClock = ProbeClockSequence(values: [
            .init(uptimeNanoseconds: 0, cpuAbsoluteTime: 0),
        ])
        let unmatchedProbe = try MeetingMemoryGraphQueryRunProbe(
            run: 1,
            iterationsPerJob: 5,
            clock: unmatchedClock.next)
        unmatchedProbe.receive(.finished(
            MeetingMemoryGraphQueryTrace(job: .decisionHistory),
            outcome: .facts))
        XCTAssertThrowsError(try unmatchedProbe.makeReceipt(
            host: Self.validHost,
            fixtureGeneration: "public-synthetic-graph-product-v1")) {
                XCTAssertEqual(
                    $0 as? MeetingMemoryGraphQueryRunProbeError,
                    .unmatchedTrace)
            }
    }

    func testIncompleteUnexpectedAndMissingSamplesFailClosed() throws {
        let incompleteClock = ProbeClockSequence(values: [
            .init(uptimeNanoseconds: 0, cpuAbsoluteTime: 0),
        ])
        let incomplete = try MeetingMemoryGraphQueryRunProbe(
            run: 1,
            iterationsPerJob: 5,
            clock: incompleteClock.next)
        incomplete.receive(.started(MeetingMemoryGraphQueryTrace(
            job: .decisionHistory)))
        XCTAssertThrowsError(try incomplete.makeReceipt(
            host: Self.validHost,
            fixtureGeneration: "public-synthetic-graph-product-v1")) {
                XCTAssertEqual(
                    $0 as? MeetingMemoryGraphQueryRunProbeError,
                    .incompleteTrace)
            }

        let missingClock = ProbeClockSequence(values: Self.clockValues(
            jobCount: 1))
        let missing = try MeetingMemoryGraphQueryRunProbe(
            run: 1,
            iterationsPerJob: 5,
            clock: missingClock.next)
        for _ in 0..<5 {
            let trace = MeetingMemoryGraphQueryTrace(
                job: .commitmentBlockers)
            missing.receive(.started(trace))
            missing.receive(.finished(trace, outcome: .facts))
        }
        XCTAssertThrowsError(try missing.makeReceipt(
            host: Self.validHost,
            fixtureGeneration: "public-synthetic-graph-product-v1")) {
                XCTAssertEqual(
                    $0 as? MeetingMemoryGraphQueryRunProbeError,
                    .missingJob(.topicFirstDiscussion))
            }

        let failedClock = ProbeClockSequence(values: Self.clockValues())
        let failed = try MeetingMemoryGraphQueryRunProbe(
            run: 1,
            iterationsPerJob: 5,
            clock: failedClock.next)
        Self.feed(
            failed,
            iterations: 5,
            overrideOutcome: (.decisionConflicts, .failed))
        XCTAssertThrowsError(try failed.makeReceipt(
            host: Self.validHost,
            fixtureGeneration: "public-synthetic-graph-product-v1")) {
                XCTAssertEqual(
                    $0 as? MeetingMemoryGraphQueryRunProbeError,
                    .unexpectedOutcome(.decisionConflicts))
            }
    }

    func testReceiptRejectsUnsupportedHostAndFixtureClaims() throws {
        let invalidHostProbe = try Self.populatedProbe()
        let invalidHost = MeetingMemoryGraphQueryBenchmarkHost(
            architecture: "arm64",
            hardwareModel: "Mac16,6",
            operatingSystem: "26.5.2",
            operatingSystemBuild: "25F84",
            physicalMemoryBytes: 36_000_000_000,
            powerSource: ResourceProbePowerSource.battery.rawValue,
            thermalState: ResourceProbeThermalState.nominal.rawValue,
            lowPowerModeEnabled: false)
        XCTAssertThrowsError(try invalidHostProbe.makeReceipt(
            host: invalidHost,
            fixtureGeneration: "public-synthetic-graph-product-v1")) {
                XCTAssertEqual(
                    $0 as? MeetingMemoryGraphQueryRunProbeError,
                    .invalidHost)
            }

        let invalidFixtureProbe = try Self.populatedProbe()
        XCTAssertThrowsError(try invalidFixtureProbe.makeReceipt(
            host: Self.validHost,
            fixtureGeneration: "private-library")) {
                XCTAssertEqual(
                    $0 as? MeetingMemoryGraphQueryRunProbeError,
                    .invalidFixtureGeneration)
            }
    }

    func testWriteIsPrivateAtomicAndNonReplacing() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "MeetingMemoryGraphQueryRunProbeTests-\(UUID().uuidString)",
            isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755])
        let output = root.appendingPathComponent("receipt.json")
        let probe = try Self.populatedProbe()
        try probe.writeReceipt(
            to: output,
            host: Self.validHost,
            fixtureGeneration: "public-synthetic-graph-product-v1")

        let attributes = try FileManager.default.attributesOfItem(
            atPath: output.path)
        let permissions = try XCTUnwrap(
            attributes[.posixPermissions] as? NSNumber)
        XCTAssertEqual(permissions.intValue & 0o777, 0o600)
        let directoryAttributes = try FileManager.default.attributesOfItem(
            atPath: root.path)
        let directoryPermissions = try XCTUnwrap(
            directoryAttributes[.posixPermissions] as? NSNumber)
        XCTAssertEqual(directoryPermissions.intValue & 0o777, 0o755)
        XCTAssertEqual(
            try JSONDecoder().decode(
                MeetingMemoryGraphQueryBenchmarkReceipt.self,
                from: Data(contentsOf: output)).jobs.count,
            MeetingMemoryGraphQueryJob.allCases.count)

        let replacement = try Self.populatedProbe()
        XCTAssertThrowsError(try replacement.writeReceipt(
            to: output,
            host: Self.validHost,
            fixtureGeneration: "public-synthetic-graph-product-v1")) {
                XCTAssertEqual(
                    $0 as? MeetingMemoryGraphQueryRunProbeError,
                    .outputAlreadyExists)
            }
    }

    func testEventsAfterReceiptCompletionFailClosed() throws {
        let repeated = try Self.populatedProbe()
        _ = try repeated.makeReceipt(
            host: Self.validHost,
            fixtureGeneration: "public-synthetic-graph-product-v1")
        XCTAssertThrowsError(try repeated.makeReceipt(
            host: Self.validHost,
            fixtureGeneration: "public-synthetic-graph-product-v1")) {
                XCTAssertEqual(
                    $0 as? MeetingMemoryGraphQueryRunProbeError,
                    .receiptAlreadyCreated)
            }

        let probe = try Self.populatedProbe(extraClockValues: 1)
        _ = try probe.makeReceipt(
            host: Self.validHost,
            fixtureGeneration: "public-synthetic-graph-product-v1")
        probe.receive(.started(MeetingMemoryGraphQueryTrace(
            job: .decisionHistory)))
        XCTAssertThrowsError(try probe.makeReceipt(
            host: Self.validHost,
            fixtureGeneration: "public-synthetic-graph-product-v1")) {
                XCTAssertEqual(
                    $0 as? MeetingMemoryGraphQueryRunProbeError,
                    .eventAfterCompletion)
            }
    }
}

private extension MeetingMemoryGraphQueryRunProbeTests {
    static let validHost = MeetingMemoryGraphQueryBenchmarkHost(
        architecture: "arm64",
        hardwareModel: "Mac16,6",
        operatingSystem: "26.5.2",
        operatingSystemBuild: "25F84",
        physicalMemoryBytes: 36_000_000_000,
        powerSource: ResourceProbePowerSource.ac.rawValue,
        thermalState: ResourceProbeThermalState.nominal.rawValue,
        lowPowerModeEnabled: false)

    static func populatedProbe(
        extraClockValues: Int = 0
    ) throws -> MeetingMemoryGraphQueryRunProbe {
        let clock = ProbeClockSequence(values:
            clockValues()
                + Array(repeating: MeetingMemoryGraphQueryProbeClock(
                    uptimeNanoseconds: 1_000_000_000,
                    cpuAbsoluteTime: 1_000_000_000),
                count: extraClockValues))
        let probe = try MeetingMemoryGraphQueryRunProbe(
            run: 1,
            iterationsPerJob: 5,
            clock: clock.next)
        feed(probe, iterations: 5)
        return probe
    }

    static func feed(
        _ probe: MeetingMemoryGraphQueryRunProbe,
        iterations: Int,
        firstTrace: MeetingMemoryGraphQueryTrace? = nil,
        overrideOutcome: (
            MeetingMemoryGraphQueryJob,
            MeetingMemoryGraphQueryOutcome
        )? = nil
    ) {
        var usedFirstTrace = false
        for job in MeetingMemoryGraphQueryJob.allCases {
            for _ in 0..<iterations {
                let trace: MeetingMemoryGraphQueryTrace
                if !usedFirstTrace,
                   let firstTrace,
                   firstTrace.job == job {
                    trace = firstTrace
                    usedFirstTrace = true
                } else {
                    trace = MeetingMemoryGraphQueryTrace(job: job)
                }
                probe.receive(.started(trace))
                let outcome = overrideOutcome?.0 == job
                    ? overrideOutcome?.1 ?? .facts
                    : .facts
                probe.receive(.finished(trace, outcome: outcome))
            }
        }
    }

    static func clockValues(
        jobCount: Int = MeetingMemoryGraphQueryJob.allCases.count
    ) -> [MeetingMemoryGraphQueryProbeClock] {
        var values: [MeetingMemoryGraphQueryProbeClock] = []
        var cursor: UInt64 = 1_000_000
        for _ in 0..<jobCount {
            for duration in 1...5 {
                values.append(MeetingMemoryGraphQueryProbeClock(
                    uptimeNanoseconds: cursor,
                    cpuAbsoluteTime: cursor))
                cursor += UInt64(duration) * 1_000_000
                values.append(MeetingMemoryGraphQueryProbeClock(
                    uptimeNanoseconds: cursor,
                    cpuAbsoluteTime: cursor))
                cursor += 1_000_000
            }
        }
        return values
    }
}

private final class ProbeClockSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [MeetingMemoryGraphQueryProbeClock]

    init(values: [MeetingMemoryGraphQueryProbeClock]) {
        self.values = values
    }

    func next() throws -> MeetingMemoryGraphQueryProbeClock {
        lock.lock()
        defer { lock.unlock() }
        guard !values.isEmpty else { throw ProbeClockSequenceError.empty }
        return values.removeFirst()
    }
}

private enum ProbeClockSequenceError: Error {
    case empty
}
