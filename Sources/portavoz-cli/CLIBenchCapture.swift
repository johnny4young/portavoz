import AVFAudio
import AudioCaptureKit
import Darwin
import Foundation
import PortavozCore

/// `portavoz-cli bench-capture [--duration-seconds 10800]
///     [--chunk-frames 4800] [--source-commit <sha>] [--output checkpoint.json]`
///
/// Accelerated, synthetic dual-channel capture through the production
/// `RecordingSession`. The producer waits for post-persistence acknowledgement
/// after every chunk pair, so a multi-hour logical run never becomes an
/// unbounded AsyncStream or in-memory PCM benchmark.
enum BenchCaptureCommand {
    static func run(_ arguments: [String]) async {
        do {
            let options = try CaptureBenchmarkOptions(arguments: arguments)
            let report = try await CaptureBenchmark.run(options: options)
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
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: url.path)
                print("Long-capture checkpoint: \(url.path)")
            } else {
                FileHandle.standardOutput.write(data)
                FileHandle.standardOutput.write(Data("\n".utf8))
            }
        } catch {
            FileHandle.standardError.write(Data("bench-capture error: \(error)\n".utf8))
            Foundation.exit(64)
        }
    }
}

struct CaptureBenchmarkOptions: Equatable {
    static let canonicalDurationSeconds = 3 * 60 * 60
    static let sampleRate = 16_000

    var durationSeconds = canonicalDurationSeconds
    var chunkFrames = 4_800
    var sourceCommit: String?
    var output: String?

    init(arguments: [String]) throws {
        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--duration-seconds":
                index += 1
                guard arguments.indices.contains(index),
                      let value = Int(arguments[index]),
                      (1...Self.canonicalDurationSeconds).contains(value)
                else { throw CaptureBenchmarkError.invalidDuration }
                durationSeconds = value
            case "--chunk-frames":
                index += 1
                guard arguments.indices.contains(index),
                      let value = Int(arguments[index]),
                      (1...Self.sampleRate).contains(value)
                else { throw CaptureBenchmarkError.invalidChunkFrames }
                chunkFrames = value
            case "--output":
                index += 1
                guard arguments.indices.contains(index), !arguments[index].isEmpty
                else { throw CaptureBenchmarkError.missingOptionValue("--output") }
                output = arguments[index]
            case "--source-commit":
                index += 1
                guard arguments.indices.contains(index),
                      Self.isCommit(arguments[index])
                else { throw CaptureBenchmarkError.invalidSourceCommit }
                sourceCommit = arguments[index]
            default:
                throw CaptureBenchmarkError.unknownOption(arguments[index])
            }
            index += 1
        }
    }

    private static func isCommit(_ value: String) -> Bool {
        value.count == 40
            && value == value.lowercased()
            && value.allSatisfy(\.isHexDigit)
    }
}

enum CaptureBenchmarkError: Error, CustomStringConvertible, Equatable {
    case acceptedFrameMismatch(channel: AudioChannel, expected: Int64, actual: Int64)
    case captureTimedOut
    case durationMismatch(channel: AudioChannel)
    case fileFrameMismatch(channel: AudioChannel, expected: Int64, actual: Int64)
    case heapGrowthExceeded(limit: UInt64, actual: UInt64)
    case invalidChunkFrames
    case invalidDuration
    case invalidPublishedFormat(channel: AudioChannel)
    case invalidSourceCommit
    case missingOptionValue(String)
    case missingPublication(AudioChannel)
    case sourceNotRunning(AudioChannel)
    case streamTerminated(AudioChannel)
    case unexpectedCaptureError(AudioChannel)
    case unhealthyPublication(AudioChannel)
    case unknownOption(String)

    var description: String {
        switch self {
        case .acceptedFrameMismatch(let channel, let expected, let actual):
            "\(channel.rawValue) accepted \(actual) frames instead of \(expected)"
        case .captureTimedOut:
            "a synthetic chunk was not persisted before the bounded timeout"
        case .durationMismatch(let channel):
            "\(channel.rawValue) duration does not match its exact frame count"
        case .fileFrameMismatch(let channel, let expected, let actual):
            "\(channel.rawValue) published \(actual) frames instead of \(expected)"
        case .heapGrowthExceeded(let limit, let actual):
            "incremental heap grew to \(actual) bytes; limit is \(limit)"
        case .invalidChunkFrames:
            "--chunk-frames must be between 1 and 16000"
        case .invalidDuration:
            "--duration-seconds must be between 1 and 10800"
        case .invalidPublishedFormat(let channel):
            "\(channel.rawValue) publication is not mono 16 kHz PCM"
        case .invalidSourceCommit:
            "--source-commit must be one lowercase 40-character Git SHA"
        case .missingOptionValue(let option):
            "missing value after \(option)"
        case .missingPublication(let channel):
            "\(channel.rawValue) did not publish a capture file"
        case .sourceNotRunning(let channel):
            "\(channel.rawValue) synthetic source is not running"
        case .streamTerminated(let channel):
            "\(channel.rawValue) synthetic stream terminated before persistence"
        case .unexpectedCaptureError(let channel):
            "\(channel.rawValue) reported a capture or publication error"
        case .unhealthyPublication(let channel):
            "\(channel.rawValue) publication is not healthy"
        case .unknownOption(let option):
            "unknown option \(option)"
        }
    }
}

struct CaptureBenchmarkReport: Codable, Equatable {
    let schemaVersion: Int
    let generatedAt: Date
    let buildConfiguration: String
    let sourceCommit: String?
    let contentSource: String
    let host: Host
    let configuration: Configuration
    let channels: [Channel]
    let result: Result

    struct Host: Codable, Equatable {
        let operatingSystem: String
        let architecture: String
        let physicalMemoryBytes: UInt64
    }

    struct Configuration: Codable, Equatable {
        let requestedDurationSeconds: Int
        let sampleRate: Int
        let chunkFrames: Int
        let expectedFramesPerChannel: Int64
        let logicalChunksPerChannel: Int
        let canonicalThreeHourRun: Bool
    }

    struct Channel: Codable, Equatable {
        let id: String
        let expectedFrames: Int64
        let acceptedFrames: Int64
        let publishedFrames: Int64
        let durationSeconds: Double
        let byteCount: Int64
        let healthStatus: String
    }

    struct Result: Codable, Equatable {
        let passed: Bool
        let driftFrames: Int64
        let captureWallDurationMilliseconds: Double
        let stopWallDurationMilliseconds: Double
        let baselineHeapBytesInUse: UInt64
        let peakHeapBytesInUse: UInt64
        let incrementalPeakHeapBytesInUse: UInt64
        let maximumIncrementalHeapBytesInUse: UInt64
        let endingHeapBytesInUse: UInt64
    }
}

enum CaptureBenchmark {
    private static let channels: [AudioChannel] = [.microphone, .system]
    private static let persistenceTimeout: DispatchTimeInterval = .seconds(30)
    static let maximumIncrementalHeapBytesInUse: UInt64 = 16 * 1_024 * 1_024

    private struct Execution {
        let summary: RecordingSession.Summary
        let expectedFrames: Int64
        let logicalChunks: Int
        let captureMilliseconds: Double
        let stopMilliseconds: Double
        let baselineHeap: UInt64
        let peakHeap: UInt64
        let incrementalPeakHeap: UInt64
        let endingHeap: UInt64
    }

    static func run(options: CaptureBenchmarkOptions) async throws -> CaptureBenchmarkReport {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let execution = try await execute(options: options, directory: directory)
        guard execution.incrementalPeakHeap <= maximumIncrementalHeapBytesInUse else {
            throw CaptureBenchmarkError.heapGrowthExceeded(
                limit: maximumIncrementalHeapBytesInUse,
                actual: execution.incrementalPeakHeap)
        }
        let channelReports = try channels.map { channel in
            try validate(
                channel: channel,
                expectedFrames: execution.expectedFrames,
                summary: execution.summary)
        }
        return makeReport(
            options: options,
            execution: execution,
            channels: channelReports)
    }

    private static func execute(
        options: CaptureBenchmarkOptions,
        directory: URL
    ) async throws -> Execution {
        let sources = channels.map { SyntheticCaptureSource(channel: $0) }
        let barrier = CapturePersistenceBarrier()
        let session = RecordingSession(outputDirectory: directory)
        let baselineHeap = heapBytesInUse()
        var peakHeap = baselineHeap
        let captureStart = ContinuousClock.now

        try await session.start(
            sources: sources,
            onChunk: { barrier.record($0.channel) })
        let expectedFrames = Int64(options.durationSeconds)
            * Int64(CaptureBenchmarkOptions.sampleRate)
        let chunkIndex: Int
        do {
            chunkIndex = try produceChunks(
                options: options,
                expectedFrames: expectedFrames,
                sources: sources,
                barrier: barrier,
                peakHeap: &peakHeap)
        } catch {
            _ = await session.stop()
            throw error
        }
        peakHeap = max(peakHeap, heapBytesInUse())
        let captureMilliseconds = milliseconds(since: captureStart)
        let stopStart = ContinuousClock.now
        let summary = await session.stop()
        let stopMilliseconds = milliseconds(since: stopStart)
        let endingHeap = heapBytesInUse()
        peakHeap = max(peakHeap, endingHeap)
        let incrementalPeakHeap = peakHeap > baselineHeap ? peakHeap - baselineHeap : 0
        return Execution(
            summary: summary,
            expectedFrames: expectedFrames,
            logicalChunks: chunkIndex,
            captureMilliseconds: captureMilliseconds,
            stopMilliseconds: stopMilliseconds,
            baselineHeap: baselineHeap,
            peakHeap: peakHeap,
            incrementalPeakHeap: incrementalPeakHeap,
            endingHeap: endingHeap)
    }

    private static func produceChunks(
        options: CaptureBenchmarkOptions,
        expectedFrames: Int64,
        sources: [SyntheticCaptureSource],
        barrier: CapturePersistenceBarrier,
        peakHeap: inout UInt64
    ) throws -> Int {
        let fullSamples = syntheticSamples(count: options.chunkFrames)
        var producedFrames: Int64 = 0
        var chunkIndex = 0
        while producedFrames < expectedFrames {
            let remaining = expectedFrames - producedFrames
            let frameCount = min(options.chunkFrames, Int(remaining))
            let samples = frameCount == fullSamples.count
                ? fullSamples
                : syntheticSamples(count: frameCount)
            let timestamp = Double(producedFrames)
                / Double(CaptureBenchmarkOptions.sampleRate)
            for source in sources {
                try source.yield(
                    samples: samples,
                    sampleRate: Double(CaptureBenchmarkOptions.sampleRate),
                    timestamp: timestamp)
            }
            let expectedChunks = chunkIndex + 1
            try barrier.wait(
                for: channels,
                count: expectedChunks,
                timeout: persistenceTimeout)
            producedFrames += Int64(frameCount)
            chunkIndex = expectedChunks
            if chunkIndex.isMultiple(of: 64) {
                peakHeap = max(peakHeap, heapBytesInUse())
            }
        }
        return chunkIndex
    }

    private static func makeReport(
        options: CaptureBenchmarkOptions,
        execution: Execution,
        channels: [CaptureBenchmarkReport.Channel]
    ) -> CaptureBenchmarkReport {
        let micFrames = execution.summary.framesWritten[.microphone] ?? 0
        let systemFrames = execution.summary.framesWritten[.system] ?? 0
        return CaptureBenchmarkReport(
            schemaVersion: 1,
            generatedAt: Date(),
            buildConfiguration: currentBuildConfiguration,
            sourceCommit: options.sourceCommit,
            contentSource: "synthetic-only",
            host: .init(
                operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
                architecture: ProcessInfo.processInfo.captureMachineArchitecture,
                physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory),
            configuration: .init(
                requestedDurationSeconds: options.durationSeconds,
                sampleRate: CaptureBenchmarkOptions.sampleRate,
                chunkFrames: options.chunkFrames,
                expectedFramesPerChannel: execution.expectedFrames,
                logicalChunksPerChannel: execution.logicalChunks,
                canonicalThreeHourRun:
                    options.durationSeconds == CaptureBenchmarkOptions.canonicalDurationSeconds),
            channels: channels,
            result: .init(
                passed: true,
                driftFrames: abs(micFrames - systemFrames),
                captureWallDurationMilliseconds: execution.captureMilliseconds,
                stopWallDurationMilliseconds: execution.stopMilliseconds,
                baselineHeapBytesInUse: execution.baselineHeap,
                peakHeapBytesInUse: execution.peakHeap,
                incrementalPeakHeapBytesInUse: execution.incrementalPeakHeap,
                maximumIncrementalHeapBytesInUse: maximumIncrementalHeapBytesInUse,
                endingHeapBytesInUse: execution.endingHeap))
    }

    private static var currentBuildConfiguration: String {
        #if DEBUG
        "debug"
        #else
        "release"
        #endif
    }

    private static func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "portavoz-bench-capture-\(UUID().uuidString)",
                isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true)
        return directory
    }

    private static func validate(
        channel: AudioChannel,
        expectedFrames: Int64,
        summary: RecordingSession.Summary
    ) throws -> CaptureBenchmarkReport.Channel {
        if summary.errors[channel] != nil {
            throw CaptureBenchmarkError.unexpectedCaptureError(channel)
        }
        let acceptedFrames = summary.framesWritten[channel] ?? 0
        guard acceptedFrames == expectedFrames else {
            throw CaptureBenchmarkError.acceptedFrameMismatch(
                channel: channel,
                expected: expectedFrames,
                actual: acceptedFrames)
        }
        guard let publication = summary.publishedFiles[channel] else {
            throw CaptureBenchmarkError.missingPublication(channel)
        }
        guard publication.healthStatus == .healthy else {
            throw CaptureBenchmarkError.unhealthyPublication(channel)
        }

        let fileEvidence = try autoreleasepool { () throws -> (Int64, Double) in
            let file = try AVAudioFile(forReading: publication.url)
            guard file.fileFormat.commonFormat == .pcmFormatInt16,
                  file.fileFormat.channelCount == 1,
                  file.fileFormat.sampleRate == Double(CaptureBenchmarkOptions.sampleRate)
            else { throw CaptureBenchmarkError.invalidPublishedFormat(channel: channel) }
            return (Int64(file.length), file.fileFormat.sampleRate)
        }
        guard fileEvidence.0 == expectedFrames else {
            throw CaptureBenchmarkError.fileFrameMismatch(
                channel: channel,
                expected: expectedFrames,
                actual: fileEvidence.0)
        }
        let expectedDuration = Double(expectedFrames) / fileEvidence.1
        guard abs(publication.durationSeconds - expectedDuration) <= 0.5 / fileEvidence.1,
              abs((summary.secondsWritten[channel] ?? 0) - expectedDuration)
                <= 0.5 / fileEvidence.1
        else { throw CaptureBenchmarkError.durationMismatch(channel: channel) }

        return .init(
            id: channel.rawValue,
            expectedFrames: expectedFrames,
            acceptedFrames: acceptedFrames,
            publishedFrames: fileEvidence.0,
            durationSeconds: publication.durationSeconds,
            byteCount: publication.byteCount,
            healthStatus: publication.healthStatus.rawValue)
    }

    private static func syntheticSamples(count: Int) -> [Float] {
        (0..<count).map { index in
            index.isMultiple(of: 2) ? 0.125 : -0.125
        }
    }

    private static func heapBytesInUse() -> UInt64 {
        var statistics = malloc_statistics_t()
        malloc_zone_statistics(malloc_default_zone(), &statistics)
        return UInt64(statistics.size_in_use)
    }

    private static func milliseconds(since start: ContinuousClock.Instant) -> Double {
        let components = start.duration(to: .now).components
        return Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1_000_000_000_000_000
    }
}

private final class SyntheticCaptureSource: AudioCaptureSource, @unchecked Sendable {
    let channel: AudioChannel
    private let lock = NSLock()
    private var continuation: AsyncThrowingStream<AudioChunk, Error>.Continuation?

    init(channel: AudioChannel) {
        self.channel = channel
    }

    func start() async throws -> AsyncThrowingStream<AudioChunk, Error> {
        let (stream, continuation) = AsyncThrowingStream<AudioChunk, Error>.makeStream()
        lock.withLock { self.continuation = continuation }
        return stream
    }

    func yield(
        samples: [Float],
        sampleRate: Double,
        timestamp: TimeInterval
    ) throws {
        let result = lock.withLock {
            continuation?.yield(AudioChunk(
                channel: channel,
                samples: samples,
                sampleRate: sampleRate,
                timestamp: timestamp))
        }
        guard let result else { throw CaptureBenchmarkError.sourceNotRunning(channel) }
        switch result {
        case .enqueued:
            return
        case .dropped, .terminated:
            throw CaptureBenchmarkError.streamTerminated(channel)
        @unknown default:
            throw CaptureBenchmarkError.streamTerminated(channel)
        }
    }

    func stop() async {
        let current = lock.withLock {
            let value = continuation
            continuation = nil
            return value
        }
        current?.finish()
    }
}

private final class CapturePersistenceBarrier: @unchecked Sendable {
    private let condition = NSCondition()
    private var counts: [AudioChannel: Int] = [:]

    func record(_ channel: AudioChannel) {
        condition.lock()
        counts[channel, default: 0] += 1
        condition.broadcast()
        condition.unlock()
    }

    func wait(
        for channels: [AudioChannel],
        count: Int,
        timeout: DispatchTimeInterval
    ) throws {
        let seconds: TimeInterval = switch timeout {
        case .seconds(let value): Double(value)
        case .milliseconds(let value): Double(value) / 1_000
        case .microseconds(let value): Double(value) / 1_000_000
        case .nanoseconds(let value): Double(value) / 1_000_000_000
        case .never: 30
        @unknown default: 30
        }
        let deadline = Date().addingTimeInterval(seconds)
        condition.lock()
        defer { condition.unlock() }
        while channels.contains(where: { counts[$0, default: 0] < count }) {
            guard condition.wait(until: deadline) else {
                throw CaptureBenchmarkError.captureTimedOut
            }
        }
    }
}

private extension ProcessInfo {
    var captureMachineArchitecture: String {
        var system = utsname()
        uname(&system)
        return withUnsafePointer(to: &system.machine) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: 1) {
                String(cString: $0)
            }
        }
    }
}
