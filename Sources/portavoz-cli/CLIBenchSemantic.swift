import Darwin
import Foundation
import IntelligenceKit
import PortavozCore
import StorageKit

/// `portavoz-cli bench-semantic --segments 100000 [--runs 20]
///     [--output checkpoint.json]`
///
/// Band 4's isolated semantic-search probe. The wrapper script launches one
/// release process per corpus size so latency, CPU time, and physical-footprint
/// evidence cannot inherit allocator state from an earlier checkpoint.
enum BenchSemanticCommand {
    static func run(_ arguments: [String]) async {
        do {
            let options = try SemanticBenchmarkOptions(arguments: arguments)
            let report = try await SemanticBenchmark.run(options: options)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(report)
            if let output = options.output {
                let url = URL(fileURLWithPath: output)
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
                print("Semantic benchmark checkpoint: \(url.path)")
            } else {
                FileHandle.standardOutput.write(data)
                FileHandle.standardOutput.write(Data("\n".utf8))
            }
        } catch {
            FileHandle.standardError.write(Data("bench-semantic error: \(error)\n".utf8))
            Foundation.exit(64)
        }
    }
}

private struct SemanticBenchmarkOptions {
    var segments = 100_000
    var runs = 20
    var output: String?

    init(arguments: [String]) throws {
        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--segments":
                index += 1
                guard arguments.indices.contains(index),
                    let value = Int(arguments[index]), (1...1_000_000).contains(value)
                else { throw SemanticBenchmarkError.invalidSegments }
                segments = value
            case "--runs":
                index += 1
                guard arguments.indices.contains(index),
                    let value = Int(arguments[index]), (3...100).contains(value)
                else { throw SemanticBenchmarkError.invalidRuns }
                runs = value
            case "--output":
                index += 1
                guard arguments.indices.contains(index), !arguments[index].isEmpty
                else { throw SemanticBenchmarkError.missingOptionValue("--output") }
                output = arguments[index]
            default:
                throw SemanticBenchmarkError.unknownOption(arguments[index])
            }
            index += 1
        }
    }
}

private enum SemanticBenchmarkError: Error, CustomStringConvertible {
    case invalidRuns
    case invalidSegments
    case missingOptionValue(String)
    case processUsageUnavailable
    case unexpectedTopResult
    case unknownOption(String)

    var description: String {
        switch self {
        case .invalidRuns:
            "--runs must be between 3 and 100"
        case .invalidSegments:
            "--segments must be between 1 and 1000000"
        case .missingOptionValue(let option):
            "missing value after \(option)"
        case .processUsageUnavailable:
            "could not read process CPU and physical-footprint counters"
        case .unexpectedTopResult:
            "semantic search did not return the exact fixture vector first"
        case .unknownOption(let option):
            "unknown option \(option)"
        }
    }
}

private struct SemanticBenchmarkReport: Codable {
    let schemaVersion: Int
    let generatedAt: Date
    let buildConfiguration: String
    let host: Host
    let configuration: Configuration
    let checkpoint: Checkpoint

    struct Host: Codable, Equatable {
        let operatingSystem: String
        let architecture: String
        let processorCount: Int
        let physicalMemoryBytes: UInt64
    }

    struct Configuration: Codable {
        let measurementRuns: Int
        let warmupRuns: Int
        let embeddingDimension: Int
        let resultLimit: Int
        let segmentsPerMeeting: Int
    }

    struct Checkpoint: Codable {
        let totalSegments: Int
        let meetingCount: Int
        let seedMilliseconds: Double
        let databaseBytes: Int64
        let rawEmbeddingBytes: Int64
        let resultCount: Int
        let wallTime: MillisecondDistribution
        let processCPUTime: MillisecondDistribution
        let baselinePhysicalFootprint: ByteDistribution
        let peakPhysicalFootprint: ByteDistribution
        let incrementalPeakPhysicalFootprint: ByteDistribution
        let endingPhysicalFootprint: ByteDistribution
    }
}

private struct MillisecondDistribution: Codable {
    let sampleCount: Int
    let p50Milliseconds: Double
    let p95Milliseconds: Double
    let maximumMilliseconds: Double

    init(_ samples: [Double]) {
        let ordered = samples.sorted()
        sampleCount = ordered.count
        p50Milliseconds = ordered[Self.index(for: 0.50, count: ordered.count)]
        p95Milliseconds = ordered[Self.index(for: 0.95, count: ordered.count)]
        maximumMilliseconds = ordered.last ?? 0
    }

    private static func index(for percentile: Double, count: Int) -> Int {
        min(count - 1, max(0, Int(ceil(Double(count) * percentile)) - 1))
    }
}

private struct ByteDistribution: Codable {
    let sampleCount: Int
    let p50Bytes: UInt64
    let p95Bytes: UInt64
    let maximumBytes: UInt64

    init(_ samples: [UInt64]) {
        let ordered = samples.sorted()
        sampleCount = ordered.count
        p50Bytes = ordered[Self.index(for: 0.50, count: ordered.count)]
        p95Bytes = ordered[Self.index(for: 0.95, count: ordered.count)]
        maximumBytes = ordered.last ?? 0
    }

    private static func index(for percentile: Double, count: Int) -> Int {
        min(count - 1, max(0, Int(ceil(Double(count) * percentile)) - 1))
    }
}

private enum SemanticBenchmark {
    private static let segmentsPerMeeting = 200
    private static let resultLimit = 12
    private static let warmupRuns = 2

    static func run(options: SemanticBenchmarkOptions) async throws -> SemanticBenchmarkReport {
        #if DEBUG
        let buildConfiguration = "debug"
        #else
        let buildConfiguration = "release"
        #endif
        let embedder = try SentenceEmbedder()
        let dimension = await embedder.dimension

        return try await withSemanticTemporaryDirectory { directory in
            let databaseURL = directory.appendingPathComponent("semantic.sqlite")
            let store = try MeetingStore(databaseURL: databaseURL)
            let seedStart = ContinuousClock.now
            try await seed(
                store: store,
                totalSegments: options.segments,
                dimension: dimension)
            let seedMilliseconds = semanticMilliseconds(since: seedStart)

            // Query a vector that is present in the corpus. This keeps result
            // validation meaningful while every persisted vector still varies.
            let queryIndex = options.segments / 2
            let query = vector(index: queryIndex, dimension: dimension)
            let expectedText = "Semantic benchmark transcript segment \(queryIndex)"
            for _ in 0..<warmupRuns {
                let hits = try await store.searchSemantic(query, limit: resultLimit)
                guard hits.first?.text == expectedText else {
                    throw SemanticBenchmarkError.unexpectedTopResult
                }
            }
            malloc_zone_pressure_relief(nil, 0)
            let measurement = try await measure(
                runs: options.runs,
                store: store,
                query: query,
                expectedText: expectedText)

            return SemanticBenchmarkReport(
                schemaVersion: 1,
                generatedAt: Date(),
                buildConfiguration: buildConfiguration,
                host: .init(
                    operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
                    architecture: ProcessInfo.processInfo.semanticMachineArchitecture,
                    processorCount: ProcessInfo.processInfo.processorCount,
                    physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory),
                configuration: .init(
                    measurementRuns: options.runs,
                    warmupRuns: warmupRuns,
                    embeddingDimension: dimension,
                    resultLimit: resultLimit,
                    segmentsPerMeeting: segmentsPerMeeting),
                checkpoint: .init(
                    totalSegments: options.segments,
                    meetingCount: Int(ceil(Double(options.segments) / Double(segmentsPerMeeting))),
                    seedMilliseconds: seedMilliseconds,
                    databaseBytes: try FileManager.default.allocatedSizeOfDirectory(at: directory),
                    rawEmbeddingBytes: Int64(options.segments * dimension * MemoryLayout<Float>.size),
                    resultCount: measurement.resultCount,
                    wallTime: .init(measurement.wallMilliseconds),
                    processCPUTime: .init(measurement.cpuMilliseconds),
                    baselinePhysicalFootprint: .init(measurement.baselineBytes),
                    peakPhysicalFootprint: .init(measurement.peakBytes),
                    incrementalPeakPhysicalFootprint: .init(measurement.incrementalPeakBytes),
                    endingPhysicalFootprint: .init(measurement.endingBytes)))
        }
    }

    private static func seed(
        store: MeetingStore,
        totalSegments: Int,
        dimension: Int
    ) async throws {
        var seeded = 0
        var meetingIndex = 0
        while seeded < totalSegments {
            let count = min(segmentsPerMeeting, totalSegments - seeded)
            let meeting = Meeting(
                title: "Semantic scale meeting \(meetingIndex)",
                startedAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(meetingIndex * 3_600)))
            let speaker = Speaker(meetingID: meeting.id, label: "S1")
            let segments = (0..<count).map { localIndex in
                let index = seeded + localIndex
                return TranscriptSegment(
                    meetingID: meeting.id,
                    speakerID: speaker.id,
                    channel: index.isMultiple(of: 5) ? .microphone : .system,
                    text: "Semantic benchmark transcript segment \(index)",
                    startTime: Double(localIndex * 8),
                    endTime: Double(localIndex * 8 + 6),
                    isFinal: true)
            }
            try await store.save(meeting)
            try await store.save([speaker])
            try await store.save(segments)
            let embeddings = Dictionary(uniqueKeysWithValues:
                segments.enumerated().map { localIndex, segment in
                    (segment.id, vector(index: seeded + localIndex, dimension: dimension))
                })
            try await store.storeEmbeddings(embeddings)
            seeded += count
            meetingIndex += 1
        }
    }

    private static func vector(index: Int, dimension: Int) -> [Float] {
        var state = UInt64(truncatingIfNeeded: index + 1) &* 0x9E37_79B9_7F4A_7C15
        var values = [Float](repeating: 0, count: dimension)
        var normSquared: Float = 0
        for offset in values.indices {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let unit = Float(state >> 40) / Float(1 << 24)
            let value = unit * 2 - 1
            values[offset] = value
            normSquared += value * value
        }
        let norm = sqrt(normSquared)
        guard norm > 0 else { return values }
        for offset in values.indices { values[offset] /= norm }
        return values
    }

    private struct Measurement {
        var wallMilliseconds: [Double] = []
        var cpuMilliseconds: [Double] = []
        var baselineBytes: [UInt64] = []
        var peakBytes: [UInt64] = []
        var incrementalPeakBytes: [UInt64] = []
        var endingBytes: [UInt64] = []
        var resultCount = 0
    }

    private static func measure(
        runs: Int,
        store: MeetingStore,
        query: [Float],
        expectedText: String
    ) async throws -> Measurement {
        var measurement = Measurement()
        for _ in 0..<runs {
            let before = try ProcessUsage.current()
            let sampler = Task.detached(priority: .high) { () -> UInt64 in
                var peak = before.physicalFootprintBytes
                while !Task.isCancelled {
                    if let usage = try? ProcessUsage.current() {
                        peak = max(peak, usage.physicalFootprintBytes)
                    }
                    try? await Task.sleep(for: .milliseconds(1))
                }
                return peak
            }
            let start = ContinuousClock.now
            let hits = try await store.searchSemantic(query, limit: resultLimit)
            let wall = semanticMilliseconds(since: start)
            let after = try ProcessUsage.current()
            sampler.cancel()
            let peak = max(after.physicalFootprintBytes, await sampler.value)
            guard hits.first?.text == expectedText else {
                throw SemanticBenchmarkError.unexpectedTopResult
            }

            measurement.wallMilliseconds.append(wall)
            let cpuTicks = after.cpuAbsoluteTime
                - min(after.cpuAbsoluteTime, before.cpuAbsoluteTime)
            measurement.cpuMilliseconds.append(semanticCPUMilliseconds(ticks: cpuTicks))
            measurement.baselineBytes.append(before.physicalFootprintBytes)
            measurement.peakBytes.append(peak)
            measurement.incrementalPeakBytes.append(
                peak - min(peak, before.physicalFootprintBytes))
            measurement.endingBytes.append(after.physicalFootprintBytes)
            measurement.resultCount = hits.count
        }
        return measurement
    }
}

private struct ProcessUsage: Sendable {
    let cpuAbsoluteTime: UInt64
    let physicalFootprintBytes: UInt64

    static func current() throws -> ProcessUsage {
        var usage = rusage_info_current()
        let result = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { reboundPointer in
                proc_pid_rusage(getpid(), RUSAGE_INFO_CURRENT, reboundPointer)
            }
        }
        guard result == 0 else { throw SemanticBenchmarkError.processUsageUnavailable }
        return ProcessUsage(
            cpuAbsoluteTime: usage.ri_user_time + usage.ri_system_time,
            physicalFootprintBytes: usage.ri_phys_footprint)
    }
}

private func semanticCPUMilliseconds(ticks: UInt64) -> Double {
    var timebase = mach_timebase_info_data_t()
    mach_timebase_info(&timebase)
    return Double(ticks) * Double(timebase.numer) / Double(timebase.denom) / 1_000_000
}

private func semanticMilliseconds(since start: ContinuousClock.Instant) -> Double {
    let duration = start.duration(to: .now)
    let components = duration.components
    return Double(components.seconds) * 1_000
        + Double(components.attoseconds) / 1_000_000_000_000_000
}

private func withSemanticTemporaryDirectory<Value>(
    operation: (URL) async throws -> Value
) async throws -> Value {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("portavoz-bench-semantic-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    return try await operation(directory)
}

private extension ProcessInfo {
    var semanticMachineArchitecture: String {
        var system = utsname()
        uname(&system)
        return withUnsafePointer(to: &system.machine) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: 1) {
                String(cString: $0)
            }
        }
    }
}
