import Foundation
import PortavozCore
import XCTest
@testable import portavoz_app

final class ResourceRunProbeTests: XCTestCase {
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
