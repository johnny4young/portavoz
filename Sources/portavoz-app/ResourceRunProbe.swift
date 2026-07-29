import Darwin
import Foundation
import IOKit.ps
import PortavozCore

enum ResourceProbeThermalState: String, Codable, Sendable {
    case nominal
    case fair
    case serious
    case critical

    var rank: Int {
        switch self {
        case .nominal: 0
        case .fair: 1
        case .serious: 2
        case .critical: 3
        }
    }
}

enum ResourceProbePowerSource: String, Codable, Sendable {
    case ac
    case battery
    case unknown
}

struct ResourceProbeUsage: Equatable, Sendable {
    let cpuAbsoluteTime: UInt64
    let physicalFootprintBytes: UInt64
    let energyNanojoules: UInt64
    let diskReadBytes: UInt64
    let diskWrittenBytes: UInt64
    let availableDiskBytes: UInt64
    let thermalState: ResourceProbeThermalState
    let powerSource: ResourceProbePowerSource
    let lowPowerModeEnabled: Bool

    static func current() throws -> ResourceProbeUsage {
        var usage = rusage_info_current()
        let result = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(
                to: rusage_info_t?.self,
                capacity: 1
            ) { reboundPointer in
                proc_pid_rusage(
                    getpid(),
                    RUSAGE_INFO_CURRENT,
                    reboundPointer)
            }
        }
        guard result == 0 else {
            throw ResourceRunProbeError.processUsageUnavailable
        }
        let diskValues = try URL(fileURLWithPath: "/").resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let availableDisk = diskValues.volumeAvailableCapacityForImportantUsage,
              availableDisk >= 0
        else {
            throw ResourceRunProbeError.diskCapacityUnavailable
        }
        return ResourceProbeUsage(
            cpuAbsoluteTime: usage.ri_user_time + usage.ri_system_time,
            physicalFootprintBytes: usage.ri_phys_footprint,
            energyNanojoules: usage.ri_energy_nj,
            diskReadBytes: usage.ri_diskio_bytesread,
            diskWrittenBytes: usage.ri_diskio_byteswritten,
            availableDiskBytes: UInt64(availableDisk),
            thermalState: ProcessInfo.processInfo.resourceProbeThermalState,
            powerSource: resourceProbePowerSource(),
            lowPowerModeEnabled: ProcessInfo.processInfo.isLowPowerModeEnabled)
    }
}

struct ResourceProbeDurationSummary: Codable, Equatable, Sendable {
    let p50: Double
    let p95: Double
    let maximum: Double
}

struct ResourceProbeWorkloadSummary: Codable, Equatable, Sendable {
    let workloadClass: String
    let kind: String
    let operation: String
    let outcome: String
    let count: Int
    let durationMilliseconds: ResourceProbeDurationSummary
}

struct ResourceProbeSample: Codable, Equatable, Sendable {
    let run: Int
    let wallDurationMilliseconds: Double
    let cpuTimeMilliseconds: Double
    let peakPhysicalFootprintBytes: UInt64
    let energyNanojoules: UInt64
    let diskReadBytes: UInt64
    let diskWrittenBytes: UInt64
    let minimumAvailableDiskBytes: UInt64
    let maximumThermalState: String
    let powerSource: String
    let lowPowerModeEnabled: Bool
    let workloads: [ResourceProbeWorkloadSummary]
}

enum ResourceRunProbeError: Error, Equatable, LocalizedError {
    case diskCapacityUnavailable
    case invalidRun
    case measurementAlreadyStopped
    case measurementStillRunning
    case outputAlreadyExists
    case powerSourceChanged
    case processUsageUnavailable

    var errorDescription: String? {
        switch self {
        case .diskCapacityUnavailable:
            "available disk capacity could not be measured"
        case .invalidRun:
            "resource probe run must be greater than zero"
        case .measurementAlreadyStopped:
            "resource probe measurement already stopped"
        case .measurementStillRunning:
            "resource probe measurement must stop before export"
        case .outputAlreadyExists:
            "resource probe output already exists"
        case .powerSourceChanged:
            "power source changed during the measurement"
        case .processUsageUnavailable:
            "process resource counters could not be measured"
        }
    }
}

/// A hidden benchmark-only probe over the real app process. It records only
/// aggregate process counters and the closed workload descriptors from Core.
/// No meeting, transcript, path, model, span, or error identity enters output.
final class ResourceRunProbe: @unchecked Sendable {
    typealias UsageProvider = @Sendable () throws -> ResourceProbeUsage
    typealias UptimeProvider = @Sendable () -> UInt64

    private struct ActiveWorkload {
        let descriptor: ResourceWorkloadDescriptor
        let startedAt: UInt64
    }

    private struct WorkloadKey: Hashable {
        let workloadClass: String
        let kind: String
        let operation: String
        let outcome: String
    }

    private let run: Int
    private let usageProvider: UsageProvider
    private let uptimeProvider: UptimeProvider
    private let lock = NSLock()
    private let startedAt: UInt64
    private let initialUsage: ResourceProbeUsage
    private var finalUsage: ResourceProbeUsage?
    private var finishedAt: UInt64?
    private var peakPhysicalFootprintBytes: UInt64
    private var minimumAvailableDiskBytes: UInt64
    private var maximumThermalState: ResourceProbeThermalState
    private var observedPowerSources: Set<ResourceProbePowerSource>
    private var lowPowerModeObserved: Bool
    private var acceptsNewWorkloads = true
    private var activeWorkloads: [UUID: ActiveWorkload] = [:]
    private var workloadDurations: [WorkloadKey: [Double]] = [:]
    private var sampler: Task<Void, Never>?

    init(
        run: Int,
        usageProvider: @escaping UsageProvider = ResourceProbeUsage.current,
        uptimeProvider: @escaping UptimeProvider = {
            DispatchTime.now().uptimeNanoseconds
        }
    ) throws {
        guard run > 0 else { throw ResourceRunProbeError.invalidRun }
        let usage = try usageProvider()
        self.run = run
        self.usageProvider = usageProvider
        self.uptimeProvider = uptimeProvider
        startedAt = uptimeProvider()
        initialUsage = usage
        peakPhysicalFootprintBytes = usage.physicalFootprintBytes
        minimumAvailableDiskBytes = usage.availableDiskBytes
        maximumThermalState = usage.thermalState
        observedPowerSources = [usage.powerSource]
        lowPowerModeObserved = usage.lowPowerModeEnabled
    }

    deinit {
        sampler?.cancel()
    }

    func startSampling(every interval: Duration = .milliseconds(100)) {
        lock.lock()
        guard sampler == nil, finalUsage == nil else {
            lock.unlock()
            return
        }
        let task = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: interval)
                    try self?.sampleUsage()
                } catch is CancellationError {
                    return
                } catch {
                    // A final synchronous sample decides whether the run is
                    // exportable; one periodic miss must not crash the app.
                }
            }
        }
        sampler = task
        lock.unlock()
    }

    func receive(_ event: ResourceWorkloadEvent) {
        let timestamp = uptimeProvider()
        lock.lock()
        defer { lock.unlock() }
        switch event {
        case .started(let span):
            guard acceptsNewWorkloads else { return }
            activeWorkloads[span.id] = ActiveWorkload(
                descriptor: span.descriptor,
                startedAt: timestamp)
        case .finished(let span, let outcome):
            guard let active = activeWorkloads.removeValue(forKey: span.id) else {
                return
            }
            let key = WorkloadKey(
                workloadClass: active.descriptor.workloadClass.rawValue,
                kind: active.descriptor.kind.rawValue,
                operation: active.descriptor.operation.rawValue,
                outcome: outcome.rawValue)
            workloadDurations[key, default: []].append(
                ResourceRunProbe.milliseconds(
                    fromNanoseconds: timestamp.saturatingSubtract(active.startedAt)))
        }
    }

    /// Freezes process metrics while allowing already-started workload spans
    /// to finish. New spans are ignored, so a Stop probe can begin without
    /// contaminating the active-recording sample.
    func stopMeasurement() throws {
        sampler?.cancel()
        let usage = try usageProvider()
        let timestamp = uptimeProvider()
        lock.lock()
        defer { lock.unlock() }
        guard finalUsage == nil else {
            throw ResourceRunProbeError.measurementAlreadyStopped
        }
        ingest(usage)
        finalUsage = usage
        finishedAt = timestamp
        acceptsNewWorkloads = false
    }

    func makeSample() throws -> ResourceProbeSample {
        lock.lock()
        defer { lock.unlock() }
        guard let finalUsage, let finishedAt else {
            throw ResourceRunProbeError.measurementStillRunning
        }
        guard observedPowerSources.count == 1,
              let powerSource = observedPowerSources.first
        else {
            throw ResourceRunProbeError.powerSourceChanged
        }
        let summaries = workloadDurations.map { key, durations in
            ResourceProbeWorkloadSummary(
                workloadClass: key.workloadClass,
                kind: key.kind,
                operation: key.operation,
                outcome: key.outcome,
                count: durations.count,
                durationMilliseconds: .init(
                    p50: Self.nearestRank(durations, percentile: 0.50),
                    p95: Self.nearestRank(durations, percentile: 0.95),
                    maximum: durations.max() ?? 0))
        }.sorted {
            (
                $0.workloadClass,
                $0.kind,
                $0.operation,
                $0.outcome
            ) < (
                $1.workloadClass,
                $1.kind,
                $1.operation,
                $1.outcome
            )
        }
        return ResourceProbeSample(
            run: run,
            wallDurationMilliseconds: Self.milliseconds(
                fromNanoseconds: finishedAt.saturatingSubtract(startedAt)),
            cpuTimeMilliseconds: Self.cpuMilliseconds(
                ticks: finalUsage.cpuAbsoluteTime.saturatingSubtract(
                    initialUsage.cpuAbsoluteTime)),
            peakPhysicalFootprintBytes: peakPhysicalFootprintBytes,
            energyNanojoules: finalUsage.energyNanojoules.saturatingSubtract(
                initialUsage.energyNanojoules),
            diskReadBytes: finalUsage.diskReadBytes.saturatingSubtract(
                initialUsage.diskReadBytes),
            diskWrittenBytes: finalUsage.diskWrittenBytes.saturatingSubtract(
                initialUsage.diskWrittenBytes),
            minimumAvailableDiskBytes: minimumAvailableDiskBytes,
            maximumThermalState: maximumThermalState.rawValue,
            powerSource: powerSource.rawValue,
            lowPowerModeEnabled: lowPowerModeObserved,
            workloads: summaries)
    }

    func writeSample(to output: URL) throws {
        let sample = try makeSample()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(sample)
        let directory = output.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path)
        guard !FileManager.default.fileExists(atPath: output.path) else {
            throw ResourceRunProbeError.outputAlreadyExists
        }
        let temporary = directory.appendingPathComponent(
            ".\(output.lastPathComponent).\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(
            atPath: temporary.path,
            contents: data + Data("\n".utf8),
            attributes: [.posixPermissions: 0o600])
        else {
            throw CocoaError(.fileWriteUnknown)
        }
        do {
            try FileManager.default.moveItem(at: temporary, to: output)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    private func sampleUsage() throws {
        let usage = try usageProvider()
        lock.lock()
        defer { lock.unlock() }
        guard finalUsage == nil else { return }
        ingest(usage)
    }

    private func ingest(_ usage: ResourceProbeUsage) {
        peakPhysicalFootprintBytes = max(
            peakPhysicalFootprintBytes,
            usage.physicalFootprintBytes)
        minimumAvailableDiskBytes = min(
            minimumAvailableDiskBytes,
            usage.availableDiskBytes)
        if usage.thermalState.rank > maximumThermalState.rank {
            maximumThermalState = usage.thermalState
        }
        observedPowerSources.insert(usage.powerSource)
        lowPowerModeObserved = lowPowerModeObserved || usage.lowPowerModeEnabled
    }

    private static func nearestRank(
        _ values: [Double],
        percentile: Double
    ) -> Double {
        let ordered = values.sorted()
        let rank = max(1, Int(ceil(percentile * Double(ordered.count))))
        return ordered[rank - 1]
    }

    private static func milliseconds(fromNanoseconds value: UInt64) -> Double {
        Double(value) / 1_000_000
    }

    private static func cpuMilliseconds(ticks: UInt64) -> Double {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        return Double(ticks) * Double(timebase.numer)
            / Double(timebase.denom) / 1_000_000
    }
}

private extension UInt64 {
    func saturatingSubtract(_ other: UInt64) -> UInt64 {
        self >= other ? self - other : 0
    }
}

private extension ProcessInfo {
    var resourceProbeThermalState: ResourceProbeThermalState {
        switch thermalState {
        case .nominal: .nominal
        case .fair: .fair
        case .serious: .serious
        case .critical: .critical
        @unknown default: .critical
        }
    }
}

private func resourceProbePowerSource() -> ResourceProbePowerSource {
    let snapshot = IOPSCopyPowerSourcesInfo().takeRetainedValue()
    let value = IOPSGetProvidingPowerSourceType(snapshot).takeUnretainedValue()
        as String
    switch value {
    case kIOPMACPowerKey:
        return .ac
    case kIOPMBatteryPowerKey:
        return .battery
    default:
        return .unknown
    }
}
