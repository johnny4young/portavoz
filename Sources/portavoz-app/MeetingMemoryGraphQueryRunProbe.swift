import ApplicationKit
import Darwin
import Foundation

struct MeetingMemoryGraphQueryProbeClock: Equatable, Sendable {
    let uptimeNanoseconds: UInt64
    let cpuAbsoluteTime: UInt64
}

struct MeetingMemoryGraphQueryDurationSummary: Codable, Equatable, Sendable {
    let p50Milliseconds: Double
    let p95Milliseconds: Double
    let maximumMilliseconds: Double
}

struct MeetingMemoryGraphQueryBenchmarkJob: Codable, Equatable, Sendable {
    let job: String
    let outcome: String
    let sampleCount: Int
    let wall: MeetingMemoryGraphQueryDurationSummary
    let cpu: MeetingMemoryGraphQueryDurationSummary
}

struct MeetingMemoryGraphQueryBenchmarkHost: Codable, Equatable, Sendable {
    let architecture: String
    let hardwareModel: String
    let operatingSystem: String
    let operatingSystemBuild: String
    let physicalMemoryBytes: UInt64
    let powerSource: String
    let thermalState: String
    let lowPowerModeEnabled: Bool
}

struct MeetingMemoryGraphQueryBenchmarkReceipt:
    Codable,
    Equatable,
    Sendable {
    let schemaVersion: Int
    let run: Int
    let fixtureGeneration: String
    let iterationsPerJob: Int
    let host: MeetingMemoryGraphQueryBenchmarkHost
    let jobs: [MeetingMemoryGraphQueryBenchmarkJob]
}

enum MeetingMemoryGraphQueryRunProbeError:
    Error,
    Equatable,
    LocalizedError {
    case duplicateTrace
    case eventAfterCompletion
    case incompleteTrace
    case invalidFixtureGeneration
    case invalidHost
    case invalidIterations
    case invalidRun
    case missingJob(MeetingMemoryGraphQueryJob)
    case outputAlreadyExists
    case processUsageUnavailable
    case receiptAlreadyCreated
    case unexpectedOutcome(MeetingMemoryGraphQueryJob)
    case unexpectedSampleCount(MeetingMemoryGraphQueryJob)
    case unmatchedTrace

    var errorDescription: String? {
        switch self {
        case .duplicateTrace:
            "Graph query benchmark observed a duplicate trace"
        case .eventAfterCompletion:
            "Graph query benchmark observed an event after completion"
        case .incompleteTrace:
            "Graph query benchmark has an unfinished trace"
        case .invalidFixtureGeneration:
            "Graph query benchmark fixture generation is invalid"
        case .invalidHost:
            "Graph query benchmark host evidence is invalid"
        case .invalidIterations:
            "Graph query benchmark iterations are invalid"
        case .invalidRun:
            "Graph query benchmark run is invalid"
        case .missingJob(let job):
            "Graph query benchmark did not observe \(job.rawValue)"
        case .outputAlreadyExists:
            "Graph query benchmark output already exists"
        case .processUsageUnavailable:
            "Graph query benchmark process CPU counters are unavailable"
        case .receiptAlreadyCreated:
            "Graph query benchmark receipt was already created"
        case .unexpectedOutcome(let job):
            "Graph query benchmark \(job.rawValue) did not return facts"
        case .unexpectedSampleCount(let job):
            "Graph query benchmark \(job.rawValue) sample count is invalid"
        case .unmatchedTrace:
            "Graph query benchmark observed an unmatched trace"
        }
    }
}

/// Strict benchmark-only collector for the D367 content-free event boundary.
/// Trace UUIDs stay process-local and never enter the receipt.
final class MeetingMemoryGraphQueryRunProbe: @unchecked Sendable {
    typealias Clock = @Sendable () throws -> MeetingMemoryGraphQueryProbeClock

    private struct ActiveTrace {
        let trace: MeetingMemoryGraphQueryTrace
        let startedAt: MeetingMemoryGraphQueryProbeClock
    }

    private struct Sample {
        let job: MeetingMemoryGraphQueryJob
        let outcome: MeetingMemoryGraphQueryOutcome
        let wallMilliseconds: Double
        let cpuMilliseconds: Double
    }

    private let run: Int
    private let iterationsPerJob: Int
    private let clock: Clock
    private let lock = NSLock()
    private var active: [UUID: ActiveTrace] = [:]
    private var samples: [Sample] = []
    private var violation: MeetingMemoryGraphQueryRunProbeError?
    private var sealed = false

    init(
        run: Int,
        iterationsPerJob: Int,
        clock: @escaping Clock = {
            try MeetingMemoryGraphQueryRunProbe.currentClock()
        }
    ) throws {
        guard (1...100).contains(run) else {
            throw MeetingMemoryGraphQueryRunProbeError.invalidRun
        }
        guard (5...1_000).contains(iterationsPerJob) else {
            throw MeetingMemoryGraphQueryRunProbeError.invalidIterations
        }
        self.run = run
        self.iterationsPerJob = iterationsPerJob
        self.clock = clock
    }

    func receive(_ event: MeetingMemoryGraphQueryEvent) {
        lock.lock()
        defer { lock.unlock() }
        guard violation == nil else { return }
        guard !sealed else {
            violation = .eventAfterCompletion
            return
        }
        let snapshot: MeetingMemoryGraphQueryProbeClock
        do {
            snapshot = try clock()
        } catch {
            violation = .processUsageUnavailable
            return
        }

        switch event {
        case .started(let trace):
            guard active[trace.id] == nil else {
                violation = .duplicateTrace
                return
            }
            active[trace.id] = ActiveTrace(
                trace: trace,
                startedAt: snapshot)

        case .finished(let trace, let outcome):
            guard let started = active.removeValue(forKey: trace.id),
                  started.trace == trace
            else {
                violation = .unmatchedTrace
                return
            }
            samples.append(Sample(
                job: trace.job,
                outcome: outcome,
                wallMilliseconds: Self.milliseconds(
                    snapshot.uptimeNanoseconds.saturatingSubtract(
                        started.startedAt.uptimeNanoseconds)),
                cpuMilliseconds: Self.cpuMilliseconds(
                    snapshot.cpuAbsoluteTime.saturatingSubtract(
                        started.startedAt.cpuAbsoluteTime))))
        }
    }

    func makeReceipt(
        host: MeetingMemoryGraphQueryBenchmarkHost,
        fixtureGeneration: String
    ) throws -> MeetingMemoryGraphQueryBenchmarkReceipt {
        lock.lock()
        defer { lock.unlock() }
        if let violation { throw violation }
        guard !sealed else {
            throw MeetingMemoryGraphQueryRunProbeError.receiptAlreadyCreated
        }
        guard active.isEmpty else {
            throw MeetingMemoryGraphQueryRunProbeError.incompleteTrace
        }
        guard Self.valid(host: host) else {
            throw MeetingMemoryGraphQueryRunProbeError.invalidHost
        }
        guard fixtureGeneration == "public-synthetic-graph-product-v1" else {
            throw MeetingMemoryGraphQueryRunProbeError
                .invalidFixtureGeneration
        }

        var jobs: [MeetingMemoryGraphQueryBenchmarkJob] = []
        for job in MeetingMemoryGraphQueryJob.allCases {
            let matching = samples.filter { $0.job == job }
            guard !matching.isEmpty else {
                throw MeetingMemoryGraphQueryRunProbeError.missingJob(job)
            }
            guard matching.count == iterationsPerJob else {
                throw MeetingMemoryGraphQueryRunProbeError
                    .unexpectedSampleCount(job)
            }
            guard matching.allSatisfy({ $0.outcome == .facts }) else {
                throw MeetingMemoryGraphQueryRunProbeError
                    .unexpectedOutcome(job)
            }
            jobs.append(MeetingMemoryGraphQueryBenchmarkJob(
                job: job.rawValue,
                outcome: MeetingMemoryGraphQueryOutcome.facts.rawValue,
                sampleCount: matching.count,
                wall: Self.summary(matching.map(\.wallMilliseconds)),
                cpu: Self.summary(matching.map(\.cpuMilliseconds))))
        }
        sealed = true
        return MeetingMemoryGraphQueryBenchmarkReceipt(
            schemaVersion: 1,
            run: run,
            fixtureGeneration: fixtureGeneration,
            iterationsPerJob: iterationsPerJob,
            host: host,
            jobs: jobs)
    }

    func writeReceipt(
        to output: URL,
        host: MeetingMemoryGraphQueryBenchmarkHost,
        fixtureGeneration: String
    ) throws {
        let receipt = try makeReceipt(
            host: host,
            fixtureGeneration: fixtureGeneration)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(receipt) + Data("\n".utf8)
        let directory = output.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        guard !FileManager.default.fileExists(atPath: output.path) else {
            throw MeetingMemoryGraphQueryRunProbeError.outputAlreadyExists
        }
        let temporary = directory.appendingPathComponent(
            ".\(output.lastPathComponent).\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(
            atPath: temporary.path,
            contents: data,
            attributes: [.posixPermissions: 0o600])
        else {
            throw CocoaError(.fileWriteUnknown)
        }
        let linkResult = temporary.path.withCString { source in
            output.path.withCString { destination in
                Darwin.link(source, destination)
            }
        }
        let linkError = errno
        try? FileManager.default.removeItem(at: temporary)
        guard linkResult == 0 else {
            if linkError == EEXIST {
                throw MeetingMemoryGraphQueryRunProbeError
                    .outputAlreadyExists
            }
            throw POSIXError(
                POSIXErrorCode(rawValue: linkError) ?? .EIO)
        }
    }

    private static func valid(
        host: MeetingMemoryGraphQueryBenchmarkHost
    ) -> Bool {
        host.architecture == "arm64"
            && !host.hardwareModel.isEmpty
            && !host.operatingSystem.isEmpty
            && !host.operatingSystemBuild.isEmpty
            && host.physicalMemoryBytes > 0
            && host.powerSource == ResourceProbePowerSource.ac.rawValue
            && host.thermalState == ResourceProbeThermalState.nominal.rawValue
            && !host.lowPowerModeEnabled
    }

    private static func summary(
        _ values: [Double]
    ) -> MeetingMemoryGraphQueryDurationSummary {
        MeetingMemoryGraphQueryDurationSummary(
            p50Milliseconds: nearestRank(values, percentile: 0.50),
            p95Milliseconds: nearestRank(values, percentile: 0.95),
            maximumMilliseconds: values.max() ?? 0)
    }

    private static func nearestRank(
        _ values: [Double],
        percentile: Double
    ) -> Double {
        let ordered = values.sorted()
        let rank = max(1, Int(ceil(percentile * Double(ordered.count))))
        return ordered[rank - 1]
    }

    private static func currentClock() throws
        -> MeetingMemoryGraphQueryProbeClock {
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
            throw MeetingMemoryGraphQueryRunProbeError
                .processUsageUnavailable
        }
        return MeetingMemoryGraphQueryProbeClock(
            uptimeNanoseconds: DispatchTime.now().uptimeNanoseconds,
            cpuAbsoluteTime: usage.ri_user_time + usage.ri_system_time)
    }

    private static func milliseconds(_ nanoseconds: UInt64) -> Double {
        Double(nanoseconds) / 1_000_000
    }

    private static func cpuMilliseconds(_ ticks: UInt64) -> Double {
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
