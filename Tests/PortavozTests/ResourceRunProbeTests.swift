import Foundation
import PortavozCore
import XCTest
@testable import portavoz_app

final class ResourceRunProbeTests: XCTestCase {
    func testResourceBenchmarksOwnTheirProcessStartup() {
        XCTAssertTrue(BenchMode.runsIsolatedResourceBenchmark(
            arguments: ["Portavoz", "--bench-record", "30"]))
        XCTAssertTrue(BenchMode.runsIsolatedResourceBenchmark(
            arguments: ["Portavoz", "--bench-resource-refine", "fixture.aiff"]))
        XCTAssertTrue(BenchMode.runsIsolatedResourceBenchmark(
            arguments: ["Portavoz", "--bench-resource-summary"]))
        XCTAssertTrue(BenchMode.runsIsolatedResourceBenchmark(
            arguments: ["Portavoz", "--bench-resource-ask"]))
        XCTAssertTrue(BenchMode.runsIsolatedResourceBenchmark(
            arguments: ["Portavoz", "--bench-resource-indexing"]))
        XCTAssertFalse(BenchMode.runsIsolatedResourceBenchmark(
            arguments: ["Portavoz", "-use-temp-store", "-seed-demo"]))
    }

    func testRefineResourceConfigurationBoundsTimeout() throws {
        let configuration = try XCTUnwrap(
            BenchRefineResourceConfiguration.requested(arguments: [
                "Portavoz",
                "--bench-resource-refine", "/tmp/refine.aiff",
                "--bench-resource-timeout", "1200",
            ]))
        XCTAssertEqual(configuration.fixtureURL.path, "/tmp/refine.aiff")
        XCTAssertEqual(configuration.timeoutSeconds, 1_200)

        XCTAssertThrowsError(
            try BenchRefineResourceConfiguration.requested(arguments: [
                "Portavoz",
                "--bench-resource-refine", "/tmp/refine.aiff",
                "--bench-resource-timeout", "59",
            ])
        ) {
            XCTAssertEqual(
                $0 as? BenchRefineResourceError,
                .invalidTimeout)
        }
    }

    func testSummaryResourceConfigurationBoundsTimeout() throws {
        let configuration = try XCTUnwrap(
            BenchSummaryResourceConfiguration.requested(arguments: [
                "Portavoz",
                "--bench-resource-summary",
                "--bench-resource-timeout", "600",
            ]))
        XCTAssertEqual(configuration.timeoutSeconds, 600)

        XCTAssertThrowsError(
            try BenchSummaryResourceConfiguration.requested(arguments: [
                "Portavoz",
                "--bench-resource-summary",
                "--bench-resource-timeout", "3601",
            ])
        ) {
            XCTAssertEqual(
                $0 as? BenchSummaryResourceError,
                .invalidTimeout)
        }
    }

    func testAskResourceConfigurationBoundsTimeout() throws {
        let configuration = try XCTUnwrap(
            BenchAskResourceConfiguration.requested(arguments: [
                "Portavoz",
                "--bench-resource-ask",
                "--bench-resource-timeout", "480",
            ]))
        XCTAssertEqual(configuration.timeoutSeconds, 480)

        XCTAssertThrowsError(
            try BenchAskResourceConfiguration.requested(arguments: [
                "Portavoz",
                "--bench-resource-ask",
                "--bench-resource-timeout", "59",
            ])
        ) {
            XCTAssertEqual(
                $0 as? BenchAskResourceError,
                .invalidTimeout)
        }
    }

    func testIndexingResourceConfigurationBoundsTimeout() throws {
        let configuration = try XCTUnwrap(
            BenchIndexingResourceConfiguration.requested(arguments: [
                "Portavoz",
                "--bench-resource-indexing",
                "--bench-resource-timeout", "360",
            ]))
        XCTAssertEqual(configuration.timeoutSeconds, 360)

        XCTAssertThrowsError(
            try BenchIndexingResourceConfiguration.requested(arguments: [
                "Portavoz",
                "--bench-resource-indexing",
                "--bench-resource-timeout", "3_601",
            ])
        ) {
            XCTAssertEqual(
                $0 as? BenchIndexingResourceError,
                .invalidTimeout)
        }
    }

    @MainActor
    func testTimedResourceOperationReturnsFirstSuccessfulValue() async throws {
        let value = try await BenchResourceTimedOperation.run(
            timeout: .seconds(1)
        ) {
            42
        }

        XCTAssertEqual(value, 42)
    }

    @MainActor
    func testTimedResourceOperationPreservesFailureAsContentFreeText() async {
        do {
            let _: Int = try await BenchResourceTimedOperation.run(
                timeout: .seconds(1)
            ) {
                throw BenchSummaryResourceError.modelsNotReady
            }
            XCTFail("Expected the operation to fail")
        } catch {
            XCTAssertEqual(
                error as? BenchResourceTimedOperationError,
                .operationFailed(
                    BenchSummaryResourceError.modelsNotReady.localizedDescription))
        }
    }

    @MainActor
    func testTimedResourceOperationDoesNotAwaitCancelledWork() async {
        let startedAt = ContinuousClock.now
        do {
            let _: Int = try await BenchResourceTimedOperation.run(
                timeout: .milliseconds(20)
            ) {
                try await Task.sleep(for: .seconds(5))
                return 42
            }
            XCTFail("Expected the operation to time out")
        } catch {
            XCTAssertEqual(
                error as? BenchResourceTimedOperationError,
                .timedOut)
        }
        XCTAssertLessThan(
            startedAt.duration(to: .now),
            .seconds(1))
    }

    @MainActor
    func testSingleScenarioProbeWritesOneExactSample() async throws {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(
            "BenchResourceScenarioProbe-\(UUID().uuidString)",
            isDirectory: true)
        defer { try? FileManager.default.removeItem(at: output) }
        let probe = try BenchResourceScenarioProbe(arguments: [
            "Portavoz",
            "--bench-resource-output", output.path,
            "--bench-resource-run", "3",
        ])

        let value = try await probe.measure(scenario: "refine") {
            try await Task.sleep(for: .milliseconds(10))
            return 42
        }

        XCTAssertEqual(value, 42)
        let sampleURL = output.appendingPathComponent("refine-3.json")
        let sample = try JSONDecoder().decode(
            ResourceProbeSample.self,
            from: Data(contentsOf: sampleURL))
        XCTAssertEqual(sample.run, 3)
        XCTAssertGreaterThan(sample.wallDurationMilliseconds, 0)
        XCTAssertTrue(sample.workloads.isEmpty)
        let attributes = try FileManager.default.attributesOfItem(
            atPath: sampleURL.path)
        XCTAssertEqual(
            (attributes[.posixPermissions] as? NSNumber)?.intValue,
            0o600)
    }

    @MainActor
    func testSingleScenarioProbeFailurePublishesNoPartialSample() async throws {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(
            "BenchResourceScenarioProbeFailure-\(UUID().uuidString)",
            isDirectory: true)
        defer { try? FileManager.default.removeItem(at: output) }
        let probe = try BenchResourceScenarioProbe(arguments: [
            "Portavoz",
            "--bench-resource-output", output.path,
            "--bench-resource-run", "4",
        ])

        do {
            let _: Int = try await probe.measure(scenario: "refine") {
                throw BenchRefineResourceError.operationFailed("expected")
            }
            XCTFail("Expected the measured operation to fail")
        } catch {
            XCTAssertEqual(
                error as? BenchRefineResourceError,
                .operationFailed("expected"))
        }

        XCTAssertFalse(FileManager.default.fileExists(
            atPath: output.appendingPathComponent("refine-4.json").path))
    }

    func testBenchResourceArgumentsBoundIdleDuration() throws {
        let output = FileManager.default.temporaryDirectory.path
        let probes = try XCTUnwrap(BenchRecordResourceProbes.requested(
            arguments: [
                "Portavoz", "--bench-resource-output", output,
                "--bench-resource-run", "4",
                "--bench-resource-idle-duration", "45",
            ]))
        XCTAssertEqual(probes.idleDurationSeconds, 45)

        XCTAssertThrowsError(try BenchRecordResourceProbes.requested(
            arguments: [
                "Portavoz", "--bench-resource-output", output,
                "--bench-resource-run", "4",
                "--bench-resource-idle-duration", "9",
            ])) {
            XCTAssertEqual(
                $0 as? BenchRecordResourceProbeError,
                .invalidIdleDuration)
        }
    }

    func testRecordingIndexingProbeBoundsTimeout() throws {
        let output = FileManager.default.temporaryDirectory.path
        let probe = try XCTUnwrap(
            BenchConcurrentRecordingResourceProbe
                .recordingIndexingRequested(arguments: [
                    "Portavoz",
                    "--bench-resource-recording-indexing",
                    "--bench-resource-output", output,
                    "--bench-resource-run", "4",
                    "--bench-resource-timeout", "480",
                ]))
        XCTAssertEqual(probe.timeoutSeconds, 480)

        XCTAssertThrowsError(
            try BenchConcurrentRecordingResourceProbe
                .recordingIndexingRequested(arguments: [
                    "Portavoz",
                    "--bench-resource-recording-indexing",
                    "--bench-resource-output", output,
                    "--bench-resource-run", "4",
                    "--bench-resource-timeout", "59",
                ])
        ) {
            XCTAssertEqual(
                $0 as? BenchConcurrentProbeError,
                .invalidTimeout)
        }
    }

    func testRecordingIndexingProbeFreezesBeforeStopAndRetainsLiveFinish() throws {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(
            "BenchRecordingIndexingProbe-\(UUID().uuidString)",
            isDirectory: true)
        defer { try? FileManager.default.removeItem(at: output) }
        let probe = try XCTUnwrap(
            BenchConcurrentRecordingResourceProbe
                .recordingIndexingRequested(arguments: [
                    "Portavoz",
                    "--bench-resource-recording-indexing",
                    "--bench-resource-output", output.path,
                    "--bench-resource-run", "7",
                ]))
        let telemetry = AppResourceWorkloadTelemetry.shared.telemetry

        try probe.begin()
        defer { probe.cancel() }
        let capture = telemetry.begin(ResourceWorkloadDescriptor(
            workloadClass: .recordingCritical,
            kind: .audioCapture,
            operation: .execute))
        telemetry.finish(capture, outcome: .completed)
        let live = telemetry.begin(ResourceWorkloadDescriptor(
            workloadClass: .liveInteractive,
            kind: .liveTranscription,
            operation: .execute))
        let indexing = telemetry.begin(ResourceWorkloadDescriptor(
            workloadClass: .maintenance,
            kind: .searchIndex,
            operation: .execute))
        telemetry.finish(indexing, outcome: .completed)
        try probe.freezeBeforeStop()
        telemetry.finish(live, outcome: .completed)
        let stopOnly = telemetry.begin(ResourceWorkloadDescriptor(
            workloadClass: .recordingCritical,
            kind: .audioCapture,
            operation: .release))
        telemetry.finish(stopOnly, outcome: .completed)
        try probe.finishAfterStopAndWrite()

        let sample = try JSONDecoder().decode(
            ResourceProbeSample.self,
            from: Data(contentsOf: output.appendingPathComponent(
                "recording-indexing-7.json")))
        XCTAssertEqual(sample.run, 7)
        XCTAssertEqual(
            Set(sample.workloads.map {
                "\($0.workloadClass)/\($0.kind)/\($0.operation)"
            }),
            Set([
                "recordingCritical/audioCapture/execute",
                "liveInteractive/liveTranscription/execute",
                "maintenance/searchIndex/execute",
            ]))
    }

    func testProbeAggregatesProcessMetricsAndNearestRankWorkloads() throws {
        let usage = UsageSequence([
            makeUsage(
                cpu: 1_000,
                footprint: 500,
                energy: 100,
                read: 200,
                written: 300,
                disk: 10_000,
                thermal: .nominal),
            makeUsage(
                cpu: 2_000,
                footprint: 700,
                energy: 160,
                read: 240,
                written: 390,
                disk: 9_000,
                thermal: .serious,
                lowPower: true),
        ])
        let uptime = UptimeSequence(milliseconds: [
            0, 10, 20, 30, 50, 60, 90, 100,
        ])
        let probe = try ResourceRunProbe(
            run: 3,
            usageProvider: usage.next,
            uptimeProvider: uptime.next)
        let descriptor = ResourceWorkloadDescriptor(
            workloadClass: .liveInteractive,
            kind: .liveTranscription,
            operation: .execute)
        for _ in 0..<3 {
            let span = ResourceWorkloadSpan(descriptor: descriptor)
            probe.receive(.started(span))
            probe.receive(.finished(span, outcome: .completed))
        }

        try probe.stopMeasurement()
        let sample = try probe.makeSample()

        XCTAssertEqual(sample.run, 3)
        XCTAssertEqual(sample.wallDurationMilliseconds, 100, accuracy: 0.001)
        XCTAssertEqual(sample.peakPhysicalFootprintBytes, 700)
        XCTAssertEqual(sample.energyNanojoules, 60)
        XCTAssertEqual(sample.diskReadBytes, 40)
        XCTAssertEqual(sample.diskWrittenBytes, 90)
        XCTAssertEqual(sample.minimumAvailableDiskBytes, 9_000)
        XCTAssertEqual(sample.maximumThermalState, "serious")
        XCTAssertEqual(sample.powerSource, "ac")
        XCTAssertTrue(sample.lowPowerModeEnabled)
        XCTAssertEqual(sample.workloads.count, 1)
        XCTAssertEqual(sample.workloads[0].count, 3)
        XCTAssertEqual(
            sample.workloads[0].durationMilliseconds,
            ResourceProbeDurationSummary(
                p50: 20,
                p95: 30,
                maximum: 30))
    }

    func testMetricFreezeAllowsExistingSpanToDrainAndIgnoresStopWork() throws {
        let usage = UsageSequence([
            makeUsage(cpu: 1, footprint: 100),
            makeUsage(cpu: 2, footprint: 120),
        ])
        let uptime = UptimeSequence(milliseconds: [0, 10, 20, 30, 40, 50])
        let probe = try ResourceRunProbe(
            run: 1,
            usageProvider: usage.next,
            uptimeProvider: uptime.next)
        let live = ResourceWorkloadSpan(descriptor: .init(
            workloadClass: .liveInteractive,
            kind: .liveTranscription,
            operation: .execute))
        probe.receive(.started(live))
        try probe.stopMeasurement()

        let stop = ResourceWorkloadSpan(descriptor: .init(
            workloadClass: .recordingCritical,
            kind: .audioCapture,
            operation: .execute))
        probe.receive(.started(stop))
        probe.receive(.finished(stop, outcome: .completed))
        probe.receive(.finished(live, outcome: .cancelled))

        let workloads = try probe.makeSample().workloads
        XCTAssertEqual(workloads.count, 1)
        XCTAssertEqual(workloads[0].kind, "liveTranscription")
        XCTAssertEqual(workloads[0].outcome, "cancelled")
        XCTAssertEqual(workloads[0].durationMilliseconds.maximum, 40)
    }

    func testPowerSourceChangeFailsClosed() throws {
        let usage = UsageSequence([
            makeUsage(cpu: 1, footprint: 100, power: .ac),
            makeUsage(cpu: 2, footprint: 100, power: .battery),
        ])
        let uptime = UptimeSequence(milliseconds: [0, 10])
        let probe = try ResourceRunProbe(
            run: 1,
            usageProvider: usage.next,
            uptimeProvider: uptime.next)

        try probe.stopMeasurement()

        XCTAssertThrowsError(try probe.makeSample()) {
            XCTAssertEqual(
                $0 as? ResourceRunProbeError,
                .powerSourceChanged)
        }
    }

    func testSampleExportIsOwnerOnlyAndNeverOverwritesEvidence() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let usage = UsageSequence([
            makeUsage(cpu: 1, footprint: 100),
            makeUsage(cpu: 2, footprint: 100),
        ])
        let uptime = UptimeSequence(milliseconds: [0, 10])
        let probe = try ResourceRunProbe(
            run: 1,
            usageProvider: usage.next,
            uptimeProvider: uptime.next)
        try probe.stopMeasurement()
        let output = root.appendingPathComponent("recording-1.json")

        try probe.writeSample(to: output)

        let attributes = try FileManager.default.attributesOfItem(
            atPath: output.path)
        XCTAssertEqual(
            (attributes[.posixPermissions] as? NSNumber)?.intValue,
            0o600)
        let document = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: output))
                as? [String: Any])
        XCTAssertEqual(
            Set(document.keys),
            Set([
                "run", "wallDurationMilliseconds", "cpuTimeMilliseconds",
                "peakPhysicalFootprintBytes", "energyNanojoules",
                "diskReadBytes", "diskWrittenBytes",
                "minimumAvailableDiskBytes", "maximumThermalState",
                "powerSource", "lowPowerModeEnabled", "workloads",
            ]))
        XCTAssertThrowsError(try probe.writeSample(to: output)) {
            XCTAssertEqual(
                $0 as? ResourceRunProbeError,
                .outputAlreadyExists)
        }
    }

    func testAppTelemetryObserverReplaysActiveSpanAndHasExplicitLifetime() {
        let recorder = ResourceProbeEventRecorder()
        let adapter = AppResourceWorkloadTelemetry.shared
        let telemetry = adapter.telemetry
        let descriptor = ResourceWorkloadDescriptor(
            workloadClass: .recordingCritical,
            kind: .audioCapture,
            operation: .execute)
        let first = telemetry.begin(descriptor)
        let observer = adapter.addObserver(
            replayingActive: true,
            recorder.receive)
        telemetry.finish(first, outcome: .completed)
        adapter.removeObserver(observer)
        let second = telemetry.begin(descriptor)
        telemetry.finish(second, outcome: .completed)

        XCTAssertEqual(recorder.count, 2)
    }

    private func makeUsage(
        cpu: UInt64,
        footprint: UInt64,
        energy: UInt64 = 0,
        read: UInt64 = 0,
        written: UInt64 = 0,
        disk: UInt64 = 1_000,
        thermal: ResourceProbeThermalState = .nominal,
        power: ResourceProbePowerSource = .ac,
        lowPower: Bool = false
    ) -> ResourceProbeUsage {
        ResourceProbeUsage(
            cpuAbsoluteTime: cpu,
            physicalFootprintBytes: footprint,
            energyNanojoules: energy,
            diskReadBytes: read,
            diskWrittenBytes: written,
            availableDiskBytes: disk,
            thermalState: thermal,
            powerSource: power,
            lowPowerModeEnabled: lowPower)
    }
}

private final class UsageSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [ResourceProbeUsage]

    init(_ values: [ResourceProbeUsage]) {
        self.values = values
    }

    func next() throws -> ResourceProbeUsage {
        lock.lock()
        defer { lock.unlock() }
        guard !values.isEmpty else {
            throw ResourceRunProbeError.processUsageUnavailable
        }
        return values.removeFirst()
    }
}

private final class UptimeSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UInt64]

    init(milliseconds: [UInt64]) {
        values = milliseconds.map { $0 * 1_000_000 }
    }

    func next() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return values.removeFirst()
    }
}

private final class ResourceProbeEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func receive(_ event: ResourceWorkloadEvent) {
        _ = event
        lock.lock()
        storage += 1
        lock.unlock()
    }
}
