import AudioPlaybackKit
import AVFoundation
import Darwin
import Foundation

/// `portavoz-cli bench-waveform [--mic <audio>] [--system <audio>]
///     [--buckets 600] [--runs 20] [--output report.json]`
///
/// Band 4's waveform probe. Inputs are copied to a throwaway directory before
/// measurement; reports contain format/size/duration only, never source paths
/// or meeting content. The first generation and same-process repeat path are
/// reported separately so a future cache proposal must first prove a budget
/// miss that stateless generation cannot solve.
enum BenchWaveformCommand {
    static func run(_ arguments: [String]) async {
        do {
            let options = try WaveformBenchmarkOptions(arguments: arguments)
            let report = try await WaveformBenchmark.run(options: options)
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
                print("Waveform benchmark evidence: \(url.path)")
            } else {
                FileHandle.standardOutput.write(data)
                FileHandle.standardOutput.write(Data("\n".utf8))
            }
        } catch {
            FileHandle.standardError.write(Data("bench-waveform error: \(error)\n".utf8))
            Foundation.exit(64)
        }
    }
}

private struct WaveformBenchmarkOptions {
    var micFile: URL?
    var systemFile: URL?
    var buckets = 600
    var runs = 20
    var output: String?

    init(arguments: [String]) throws {
        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--mic":
                index += 1
                micFile = try Self.fileURL(arguments, index: index, option: "--mic")
            case "--system":
                index += 1
                systemFile = try Self.fileURL(arguments, index: index, option: "--system")
            case "--buckets":
                index += 1
                guard arguments.indices.contains(index),
                      let value = Int(arguments[index]), (1...10_000).contains(value)
                else { throw WaveformBenchmarkError.invalidBuckets }
                buckets = value
            case "--runs":
                index += 1
                guard arguments.indices.contains(index),
                      let value = Int(arguments[index]), (3...100).contains(value)
                else { throw WaveformBenchmarkError.invalidRuns }
                runs = value
            case "--output":
                index += 1
                guard arguments.indices.contains(index), !arguments[index].isEmpty
                else { throw WaveformBenchmarkError.missingOptionValue("--output") }
                output = arguments[index]
            default:
                throw WaveformBenchmarkError.unknownOption(arguments[index])
            }
            index += 1
        }
        guard micFile != nil || systemFile != nil else {
            throw WaveformBenchmarkError.missingAudio
        }
    }

    private static func fileURL(
        _ arguments: [String],
        index: Int,
        option: String
    ) throws -> URL {
        guard arguments.indices.contains(index), !arguments[index].isEmpty else {
            throw WaveformBenchmarkError.missingOptionValue(option)
        }
        let url = URL(fileURLWithPath: arguments[index]).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue
        else { throw WaveformBenchmarkError.unreadableAudio(option) }
        return url
    }
}

private enum WaveformBenchmarkError: Error, CustomStringConvertible {
    case inconsistentResult
    case invalidBuckets
    case invalidRuns
    case missingAudio
    case missingOptionValue(String)
    case processUsageUnavailable
    case sourceReplacementDidNotInvalidate
    case unknownOption(String)
    case unreadableAudio(String)

    var description: String {
        switch self {
        case .inconsistentResult:
            "waveform generation did not return one stable bucket set"
        case .invalidBuckets:
            "--buckets must be between 1 and 10000"
        case .invalidRuns:
            "--runs must be between 3 and 100"
        case .missingAudio:
            "provide --mic, --system, or both"
        case .missingOptionValue(let option):
            "missing value after \(option)"
        case .processUsageUnavailable:
            "could not read process CPU and physical-footprint counters"
        case .sourceReplacementDidNotInvalidate:
            "replacement audio returned the prior waveform fingerprint"
        case .unknownOption(let option):
            "unknown option \(option)"
        case .unreadableAudio(let option):
            "\(option) does not point to a readable file"
        }
    }
}

private struct WaveformBenchmarkReport: Codable {
    let schemaVersion: Int
    let generatedAt: Date
    let buildConfiguration: String
    let host: Host
    let configuration: Configuration
    let source: Source
    let firstGeneration: Generation
    let repeatedGeneration: RepeatedGeneration
    let invalidation: Invalidation

    struct Host: Codable {
        let operatingSystem: String
        let architecture: String
        let processorCount: Int
        let physicalMemoryBytes: UInt64
    }

    struct Configuration: Codable {
        let repeatedRuns: Int
        let bucketCount: Int
    }

    struct Source: Codable {
        let copiedToScratch: Bool
        let channelCount: Int
        let totalBytes: Int64
        let durationSeconds: Double
        let channels: [Channel]
    }

    struct Channel: Codable {
        let role: String
        let container: String
        let byteCount: Int64
        let durationSeconds: Double
        let sampleRate: Double
        let audioChannelCount: Int
    }

    struct Generation: Codable {
        let resultCount: Int
        let resultFingerprint: String
        let wallMilliseconds: Double
        let processCPUMilliseconds: Double
        let baselinePhysicalFootprintBytes: UInt64
        let peakPhysicalFootprintBytes: UInt64
        let incrementalPeakPhysicalFootprintBytes: UInt64
        let endingPhysicalFootprintBytes: UInt64
    }

    struct RepeatedGeneration: Codable {
        let resultCount: Int
        let resultFingerprint: String
        let wallTime: WaveformMillisecondDistribution
        let processCPUTime: WaveformMillisecondDistribution
        let baselinePhysicalFootprint: WaveformByteDistribution
        let peakPhysicalFootprint: WaveformByteDistribution
        let incrementalPeakPhysicalFootprint: WaveformByteDistribution
        let endingPhysicalFootprint: WaveformByteDistribution
    }

    struct Invalidation: Codable {
        let replacementUsesRealAudioFile: Bool
        let resultChanged: Bool
        let replacementResultCount: Int
        let replacementFingerprint: String
    }
}

private struct WaveformMillisecondDistribution: Codable {
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

private struct WaveformByteDistribution: Codable {
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

private enum WaveformBenchmark {
    private struct ScratchSource {
        let micFile: URL?
        let systemFile: URL?
        let report: WaveformBenchmarkReport.Source
    }

    private struct GenerationSample {
        let buckets: [Waveform.Bucket]
        let fingerprint: String
        let wallMilliseconds: Double
        let processCPUMilliseconds: Double
        let baselineBytes: UInt64
        let peakBytes: UInt64
        let incrementalPeakBytes: UInt64
        let endingBytes: UInt64
    }

    private struct Measurement {
        let first: GenerationSample
        let repeats: [GenerationSample]
        let replacementBuckets: [Waveform.Bucket]
        let replacementFingerprint: String
    }

    static func run(options: WaveformBenchmarkOptions) async throws -> WaveformBenchmarkReport {
        #if DEBUG
        let buildConfiguration = "debug"
        #else
        let buildConfiguration = "release"
        #endif
        return try await withWaveformTemporaryDirectory { directory in
            let source = try copySource(options: options, to: directory)
            let measurement = try await measureSource(
                source, options: options, directory: directory)
            return makeReport(
                source: source.report,
                measurement: measurement,
                options: options,
                buildConfiguration: buildConfiguration)
        }
    }

    private static func measureSource(
        _ source: ScratchSource,
        options: WaveformBenchmarkOptions,
        directory: URL
    ) async throws -> Measurement {
        malloc_zone_pressure_relief(nil, 0)
        let first = try await measure(
            micFile: source.micFile,
            systemFile: source.systemFile,
            buckets: options.buckets)
        guard first.buckets.count == options.buckets else {
            throw WaveformBenchmarkError.inconsistentResult
        }

        var repeats: [GenerationSample] = []
        repeats.reserveCapacity(options.runs)
        for _ in 0..<options.runs {
            let sample = try await measure(
                micFile: source.micFile,
                systemFile: source.systemFile,
                buckets: options.buckets)
            guard sample.buckets == first.buckets,
                  sample.fingerprint == first.fingerprint
            else { throw WaveformBenchmarkError.inconsistentResult }
            repeats.append(sample)
        }

        let replacement = try writeReplacementAudio(in: directory)
        let replacementBuckets = Waveform.generate(
            micFile: replacement.mic,
            systemFile: replacement.system,
            buckets: options.buckets)
        let replacementFingerprint = fingerprint(of: replacementBuckets)
        guard replacementBuckets.count == options.buckets,
              replacementFingerprint != first.fingerprint
        else { throw WaveformBenchmarkError.sourceReplacementDidNotInvalidate }
        return Measurement(
            first: first,
            repeats: repeats,
            replacementBuckets: replacementBuckets,
            replacementFingerprint: replacementFingerprint)
    }

    private static func makeReport(
        source: WaveformBenchmarkReport.Source,
        measurement: Measurement,
        options: WaveformBenchmarkOptions,
        buildConfiguration: String
    ) -> WaveformBenchmarkReport {
        let first = measurement.first
        let repeats = measurement.repeats
        return WaveformBenchmarkReport(
            schemaVersion: 1,
            generatedAt: Date(),
            buildConfiguration: buildConfiguration,
            host: .init(
                operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
                architecture: ProcessInfo.processInfo.waveformMachineArchitecture,
                processorCount: ProcessInfo.processInfo.processorCount,
                physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory),
            configuration: .init(repeatedRuns: options.runs, bucketCount: options.buckets),
            source: source,
            firstGeneration: .init(
                resultCount: first.buckets.count,
                resultFingerprint: first.fingerprint,
                wallMilliseconds: first.wallMilliseconds,
                processCPUMilliseconds: first.processCPUMilliseconds,
                baselinePhysicalFootprintBytes: first.baselineBytes,
                peakPhysicalFootprintBytes: first.peakBytes,
                incrementalPeakPhysicalFootprintBytes: first.incrementalPeakBytes,
                endingPhysicalFootprintBytes: first.endingBytes),
            repeatedGeneration: .init(
                resultCount: first.buckets.count,
                resultFingerprint: first.fingerprint,
                wallTime: .init(repeats.map(\.wallMilliseconds)),
                processCPUTime: .init(repeats.map(\.processCPUMilliseconds)),
                baselinePhysicalFootprint: .init(repeats.map(\.baselineBytes)),
                peakPhysicalFootprint: .init(repeats.map(\.peakBytes)),
                incrementalPeakPhysicalFootprint: .init(repeats.map(\.incrementalPeakBytes)),
                endingPhysicalFootprint: .init(repeats.map(\.endingBytes))),
            invalidation: .init(
                replacementUsesRealAudioFile: true,
                resultChanged: true,
                replacementResultCount: measurement.replacementBuckets.count,
                replacementFingerprint: measurement.replacementFingerprint))
    }

    private static func copySource(
        options: WaveformBenchmarkOptions,
        to directory: URL
    ) throws -> ScratchSource {
        var channels: [WaveformBenchmarkReport.Channel] = []
        var totalBytes: Int64 = 0
        var duration: Double = 0

        func copy(_ source: URL?, role: String) throws -> URL? {
            guard let source else { return nil }
            let ext = source.pathExtension.lowercased()
            let destination = directory.appendingPathComponent("\(role).\(ext)")
            try FileManager.default.copyItem(at: source, to: destination)
            let audio = try AVAudioFile(forReading: destination)
            let sampleRate = audio.fileFormat.sampleRate
            let channelDuration = Double(audio.length) / sampleRate
            let byteCount = try destination.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            channels.append(.init(
                role: role,
                container: ext,
                byteCount: Int64(byteCount),
                durationSeconds: channelDuration,
                sampleRate: sampleRate,
                audioChannelCount: Int(audio.fileFormat.channelCount)))
            totalBytes += Int64(byteCount)
            duration = max(duration, channelDuration)
            return destination
        }

        let mic = try copy(options.micFile, role: "microphone")
        let system = try copy(options.systemFile, role: "system")
        return ScratchSource(
            micFile: mic,
            systemFile: system,
            report: .init(
                copiedToScratch: true,
                channelCount: channels.count,
                totalBytes: totalBytes,
                durationSeconds: duration,
                channels: channels.sorted { $0.role < $1.role }))
    }

    private static func measure(
        micFile: URL?,
        systemFile: URL?,
        buckets: Int
    ) async throws -> GenerationSample {
        let before = try WaveformProcessUsage.current()
        let sampler = Task.detached(priority: .high) { () -> UInt64 in
            var peak = before.physicalFootprintBytes
            while !Task.isCancelled {
                if let usage = try? WaveformProcessUsage.current() {
                    peak = max(peak, usage.physicalFootprintBytes)
                }
                try? await Task.sleep(for: .milliseconds(1))
            }
            return peak
        }
        let start = ContinuousClock.now
        let result = Waveform.generate(
            micFile: micFile,
            systemFile: systemFile,
            buckets: buckets)
        let wall = waveformMilliseconds(since: start)
        let after = try WaveformProcessUsage.current()
        sampler.cancel()
        let peak = max(after.physicalFootprintBytes, await sampler.value)
        let cpuTicks = after.cpuAbsoluteTime
            - min(after.cpuAbsoluteTime, before.cpuAbsoluteTime)
        return GenerationSample(
            buckets: result,
            fingerprint: fingerprint(of: result),
            wallMilliseconds: wall,
            processCPUMilliseconds: waveformCPUMilliseconds(ticks: cpuTicks),
            baselineBytes: before.physicalFootprintBytes,
            peakBytes: peak,
            incrementalPeakBytes: peak - min(peak, before.physicalFootprintBytes),
            endingBytes: after.physicalFootprintBytes)
    }

    private static func fingerprint(of buckets: [Waveform.Bucket]) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for bucket in buckets {
            hash ^= UInt64(bucket.amplitude.bitPattern)
            hash &*= 1_099_511_628_211
            hash ^= bucket.micDominant ? 1 : 0
            hash &*= 1_099_511_628_211
        }
        return String(format: "%016llx", hash)
    }

    private static func writeReplacementAudio(
        in directory: URL
    ) throws -> (mic: URL, system: URL) {
        let sampleRate = 16_000.0
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false)!
        let frameCount = AVAudioFrameCount(sampleRate * 2)

        func write(role: String, amplitude: Float) throws -> URL {
            let url = directory.appendingPathComponent("replacement-\(role).wav")
            var writer: AVAudioFile? = try AVAudioFile(
                forWriting: url,
                settings: format.settings)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
            buffer.frameLength = frameCount
            let samples = buffer.floatChannelData![0]
            for index in 0..<Int(frameCount) {
                let envelope = Float(index) / Float(frameCount)
                samples[index] = amplitude * envelope
                    * Float(sin(2 * Double.pi * 440 * Double(index) / sampleRate))
            }
            try writer!.write(from: buffer)
            writer = nil
            return url
        }

        return (
            mic: try write(role: "microphone", amplitude: 0.9),
            system: try write(role: "system", amplitude: 0.1))
    }
}

private struct WaveformProcessUsage: Sendable {
    let cpuAbsoluteTime: UInt64
    let physicalFootprintBytes: UInt64

    static func current() throws -> WaveformProcessUsage {
        var usage = rusage_info_current()
        let result = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { reboundPointer in
                proc_pid_rusage(getpid(), RUSAGE_INFO_CURRENT, reboundPointer)
            }
        }
        guard result == 0 else { throw WaveformBenchmarkError.processUsageUnavailable }
        return WaveformProcessUsage(
            cpuAbsoluteTime: usage.ri_user_time + usage.ri_system_time,
            physicalFootprintBytes: usage.ri_phys_footprint)
    }
}

private func waveformCPUMilliseconds(ticks: UInt64) -> Double {
    var timebase = mach_timebase_info_data_t()
    mach_timebase_info(&timebase)
    return Double(ticks) * Double(timebase.numer) / Double(timebase.denom) / 1_000_000
}

private func waveformMilliseconds(since start: ContinuousClock.Instant) -> Double {
    let duration = start.duration(to: .now)
    let components = duration.components
    return Double(components.seconds) * 1_000
        + Double(components.attoseconds) / 1_000_000_000_000_000
}

private func withWaveformTemporaryDirectory<Value>(
    operation: (URL) async throws -> Value
) async throws -> Value {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("portavoz-bench-waveform-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    return try await operation(directory)
}

private extension ProcessInfo {
    var waveformMachineArchitecture: String {
        var system = utsname()
        uname(&system)
        return withUnsafePointer(to: &system.machine) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: 1) {
                String(cString: $0)
            }
        }
    }
}
