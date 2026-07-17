import ApplicationKit
import Foundation
import IntelligenceKit
import PortavozCore
import StorageKit

/// `portavoz-cli bench-scale [--library-sizes 1000,10000,50000,100000]
///     [--meeting-minutes 30,120,480] [--runs 20] [--output report.json]`
///
/// Band 4's scale baseline. Every fixture lives in a throwaway directory and
/// uses the production schema/read paths. Run the release binary: Debug timing
/// is useful for smoke only and must never enter the measured evidence file.
enum BenchScaleCommand {
    static func run(_ arguments: [String]) async {
        do {
            let options = try ScaleBenchmarkOptions(arguments: arguments)
            let report = try await ScaleBenchmark.run(options: options)
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
                print("Scale benchmark evidence: \(url.path)")
            } else {
                FileHandle.standardOutput.write(data)
                FileHandle.standardOutput.write(Data("\n".utf8))
            }
        } catch {
            FileHandle.standardError.write(Data("bench-scale error: \(error)\n".utf8))
            Foundation.exit(64)
        }
    }
}

private struct ScaleBenchmarkOptions {
    var librarySizes = [1_000, 10_000, 50_000, 100_000]
    var meetingMinutes = [30, 120, 480]
    var runs = 20
    var output: String?

    // Development-only CLI parser; one branch per supported flag.
    init(arguments: [String]) throws {
        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--library-sizes":
                index += 1
                librarySizes = try Self.csvIntegers(arguments, index: index)
            case "--meeting-minutes":
                index += 1
                meetingMinutes = try Self.csvIntegers(arguments, index: index)
            case "--runs":
                index += 1
                guard arguments.indices.contains(index),
                    let value = Int(arguments[index]), (3...100).contains(value)
                else { throw ScaleBenchmarkError.invalidRuns }
                runs = value
            case "--output":
                index += 1
                guard arguments.indices.contains(index), !arguments[index].isEmpty
                else { throw ScaleBenchmarkError.missingOptionValue("--output") }
                output = arguments[index]
            default:
                throw ScaleBenchmarkError.unknownOption(arguments[index])
            }
            index += 1
        }
        librarySizes = Array(Set(librarySizes)).sorted()
        meetingMinutes = Array(Set(meetingMinutes)).sorted()
        guard librarySizes.allSatisfy({ (1...1_000_000).contains($0) }),
              meetingMinutes.allSatisfy({ (1...24 * 60).contains($0) })
        else { throw ScaleBenchmarkError.invalidMatrix }
    }

    private static func csvIntegers(_ arguments: [String], index: Int) throws -> [Int] {
        guard arguments.indices.contains(index) else {
            throw ScaleBenchmarkError.missingOptionValue("matrix")
        }
        let values = try arguments[index]
            .split(separator: ",", omittingEmptySubsequences: false)
            .map { component -> Int in
                guard let value = Int(component.trimmingCharacters(in: .whitespaces)) else {
                    throw ScaleBenchmarkError.invalidMatrix
                }
                return value
            }
        guard !values.isEmpty else { throw ScaleBenchmarkError.invalidMatrix }
        return values
    }
}

private enum ScaleBenchmarkError: Error, CustomStringConvertible {
    case invalidMatrix
    case invalidRuns
    case missingOptionValue(String)
    case missingDetail(MeetingID)
    case unknownOption(String)

    var description: String {
        switch self {
        case .invalidMatrix:
            "matrix values must be positive, bounded comma-separated integers"
        case .invalidRuns:
            "--runs must be between 3 and 100"
        case .missingOptionValue(let option):
            "missing value after \(option)"
        case .missingDetail(let id):
            "benchmark detail did not load for \(id.rawValue.uuidString)"
        case .unknownOption(let option):
            "unknown option \(option)"
        }
    }
}

private struct ScaleBenchmarkReport: Codable {
    let schemaVersion: Int
    let generatedAt: Date
    let buildConfiguration: String
    let host: Host
    let configuration: Configuration
    let library: [LibraryCheckpoint]
    let longMeetings: [LongMeeting]

    struct Host: Codable {
        let operatingSystem: String
        let architecture: String
        let processorCount: Int
        let physicalMemoryBytes: UInt64
    }

    struct Configuration: Codable {
        let measurementRuns: Int
        let algorithmRuns: Int
        let segmentsPerLibraryMeeting: Int
        let detailSegmentsPerTwoHours: Int
    }

    struct LibraryCheckpoint: Codable {
        let totalSegments: Int
        let meetingCount: Int
        let cumulativeSeedMilliseconds: Double
        let databaseBytes: Int64
        let exactSearch: Distribution
        let questionRetrieval: Distribution
    }

    struct LongMeeting: Codable {
        let durationMinutes: Int
        let segmentCount: Int
        let seedMilliseconds: Double
        let databaseBytes: Int64
        let detailInitialObservation: Distribution
        let chapterExtraction: Distribution
        let meetingHealth: Distribution
        let chapterCount: Int
        let healthSpeakerCount: Int
    }
}

private struct Distribution: Codable {
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

private enum ScaleBenchmark {
    private static let librarySegmentsPerMeeting = 200
    private static let detailSegmentsPerTwoHours = 5_000
    private static let topics = [
        "presupuesto", "transcripción", "deadline", "integración", "Zephyr",
        "roadmap", "deploy", "cliente", "action", "items", "review", "pipeline",
        "modelo", "local", "resumen", "reunión", "proyecto", "equipo", "sprint",
        "release", "bug", "diarización", "audio", "calendario", "notas"
    ]

    static func run(options: ScaleBenchmarkOptions) async throws -> ScaleBenchmarkReport {
        let algorithmRuns = min(3, options.runs)
        #if DEBUG
        let buildConfiguration = "debug"
        #else
        let buildConfiguration = "release"
        #endif
        return try await withTemporaryDirectory(prefix: "portavoz-bench-scale") { root in
            let library = try await libraryMatrix(root: root, options: options)
            let meetings = try await longMeetingMatrix(
                root: root,
                minutes: options.meetingMinutes,
                runs: options.runs,
                algorithmRuns: algorithmRuns)
            return ScaleBenchmarkReport(
                schemaVersion: 1,
                generatedAt: Date(),
                buildConfiguration: buildConfiguration,
                host: .init(
                    operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
                    architecture: ProcessInfo.processInfo.machineArchitecture,
                    processorCount: ProcessInfo.processInfo.processorCount,
                    physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory),
                configuration: .init(
                    measurementRuns: options.runs,
                    algorithmRuns: algorithmRuns,
                    segmentsPerLibraryMeeting: librarySegmentsPerMeeting,
                    detailSegmentsPerTwoHours: detailSegmentsPerTwoHours),
                library: library,
                longMeetings: meetings)
        }
    }

    private static func libraryMatrix(
        root: URL,
        options: ScaleBenchmarkOptions
    ) async throws -> [ScaleBenchmarkReport.LibraryCheckpoint] {
        let directory = root.appendingPathComponent("library", isDirectory: true)
        let store = try MeetingStore(databaseURL: directory.appendingPathComponent("bench.sqlite"))
        var seededSegments = 0
        var meetingIndex = 0
        var cumulativeSeedMilliseconds = 0.0
        var checkpoints: [ScaleBenchmarkReport.LibraryCheckpoint] = []

        for target in options.librarySizes {
            let seedStart = ContinuousClock.now
            while seededSegments < target {
                let count = min(librarySegmentsPerMeeting, target - seededSegments)
                try await seedLibraryMeeting(
                    store: store,
                    meetingIndex: meetingIndex,
                    segmentCount: count)
                meetingIndex += 1
                seededSegments += count
            }
            cumulativeSeedMilliseconds += milliseconds(since: seedStart)
            checkpoints.append(try await ScaleBenchmarkReport.LibraryCheckpoint(
                totalSegments: target,
                meetingCount: meetingIndex,
                cumulativeSeedMilliseconds: cumulativeSeedMilliseconds,
                databaseBytes: try FileManager.default.allocatedSizeOfDirectory(at: directory),
                exactSearch: measureAsync(runs: options.runs) {
                    _ = try await store.search("presupuesto transcripción", requireAll: true)
                },
                questionRetrieval: measureAsync(runs: options.runs) {
                    _ = try await store.search(
                        "qué acordamos sobre el presupuesto del proyecto",
                        requireAll: false)
                }))
        }
        return checkpoints
    }

    private static func longMeetingMatrix(
        root: URL,
        minutes: [Int],
        runs: Int,
        algorithmRuns: Int
    ) async throws -> [ScaleBenchmarkReport.LongMeeting] {
        var results: [ScaleBenchmarkReport.LongMeeting] = []
        for durationMinutes in minutes {
            let directory = root.appendingPathComponent(
                "meeting-\(durationMinutes)m",
                isDirectory: true)
            let store = try MeetingStore(
                databaseURL: directory.appendingPathComponent("bench.sqlite"))
            let segmentCount = max(
                1,
                Int((Double(durationMinutes) / 120 * Double(detailSegmentsPerTwoHours)).rounded()))
            let seedStart = ContinuousClock.now
            let meetingID = try await seedLongMeeting(
                store: store,
                durationMinutes: durationMinutes,
                segmentCount: segmentCount)
            let seedMilliseconds = milliseconds(since: seedStart)

            for _ in 0..<2 { _ = try await loadCore(store: store, meetingID: meetingID) }
            let detail = try await measureAsyncReturning(runs: runs) {
                try await loadCore(store: store, meetingID: meetingID)
            }
            let core = detail.value
            let chapters = measureSyncReturning(runs: algorithmRuns) {
                ChapterExtractor.chapters(from: core.segments)
            }
            let health = measureSyncReturning(runs: algorithmRuns) {
                MeetingHealth.compute(segments: core.segments)
            }
            results.append(.init(
                durationMinutes: durationMinutes,
                segmentCount: segmentCount,
                seedMilliseconds: seedMilliseconds,
                databaseBytes: try FileManager.default.allocatedSizeOfDirectory(at: directory),
                detailInitialObservation: detail.distribution,
                chapterExtraction: chapters.distribution,
                meetingHealth: health.distribution,
                chapterCount: chapters.value.count,
                healthSpeakerCount: health.value.stats.count))
        }
        return results
    }

    private static func seedLibraryMeeting(
        store: MeetingStore,
        meetingIndex: Int,
        segmentCount: Int
    ) async throws {
        let meeting = Meeting(
            title: "Library scale meeting \(meetingIndex)",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(meetingIndex * 3_600)))
        let speaker = Speaker(meetingID: meeting.id, label: "S1")
        try await store.save(meeting)
        try await store.save([speaker])
        try await store.save(makeSegments(
            meetingID: meeting.id,
            speakers: [speaker],
            count: segmentCount,
            durationSeconds: Double(segmentCount * 8),
            salt: meetingIndex))
    }

    private static func seedLongMeeting(
        store: MeetingStore,
        durationMinutes: Int,
        segmentCount: Int
    ) async throws -> MeetingID {
        let duration = Double(durationMinutes * 60)
        let meeting = Meeting(
            title: "Long meeting baseline \(durationMinutes)m",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            endedAt: Date(timeIntervalSince1970: 1_700_000_000 + duration),
            language: "es")
        let speakers = (0..<4).map {
            Speaker(meetingID: meeting.id, label: "S\($0 + 1)", displayName: "Person \($0 + 1)")
        }
        try await store.save(meeting)
        try await store.save(speakers)
        try await store.save(makeSegments(
            meetingID: meeting.id,
            speakers: speakers,
            count: segmentCount,
            durationSeconds: duration,
            salt: durationMinutes))
        return meeting.id
    }

    private static func makeSegments(
        meetingID: MeetingID,
        speakers: [Speaker],
        count: Int,
        durationSeconds: Double,
        salt: Int
    ) -> [TranscriptSegment] {
        let stride = durationSeconds / Double(count)
        return (0..<count).map { index in
            let base = (salt * 31 + index * 7) % topics.count
            let words = (0..<8).map { topics[(base + $0) % topics.count] }
            let start = Double(index) * stride
            return TranscriptSegment(
                meetingID: meetingID,
                speakerID: speakers[index % speakers.count].id,
                channel: index.isMultiple(of: 5) ? .microphone : .system,
                text: "Hablamos de \(words.joined(separator: " ")) en el punto \(index).",
                startTime: start,
                endTime: min(durationSeconds, start + stride * 0.82),
                confidence: 0.94,
                isFinal: true)
        }
    }

    private static func loadCore(
        store: MeetingStore,
        meetingID: MeetingID
    ) async throws -> MeetingStore.MeetingReviewCore {
        var iterator = store.observeMeetingReviewCore(meetingID).makeAsyncIterator()
        guard let emission = try await iterator.next(), let core = emission else {
            throw ScaleBenchmarkError.missingDetail(meetingID)
        }
        return core
    }
}

private func measureAsync(
    runs: Int,
    operation: () async throws -> Void
) async rethrows -> Distribution {
    var samples: [Double] = []
    samples.reserveCapacity(runs)
    for _ in 0..<runs {
        let start = ContinuousClock.now
        try await operation()
        samples.append(milliseconds(since: start))
    }
    return Distribution(samples)
}

private func measureAsyncReturning<Value>(
    runs: Int,
    operation: () async throws -> Value
) async rethrows -> (distribution: Distribution, value: Value) {
    var value = try await operation()
    var samples: [Double] = []
    samples.reserveCapacity(runs)
    for _ in 0..<runs {
        let start = ContinuousClock.now
        value = try await operation()
        samples.append(milliseconds(since: start))
    }
    return (Distribution(samples), value)
}

private func measureSyncReturning<Value>(
    runs: Int,
    operation: () -> Value
) -> (distribution: Distribution, value: Value) {
    var value = operation()
    var samples: [Double] = []
    samples.reserveCapacity(runs)
    for _ in 0..<runs {
        let start = ContinuousClock.now
        value = operation()
        withExtendedLifetime(value) {}
        samples.append(milliseconds(since: start))
    }
    return (Distribution(samples), value)
}

private func milliseconds(since start: ContinuousClock.Instant) -> Double {
    let duration = start.duration(to: .now)
    let components = duration.components
    return Double(components.seconds) * 1_000
        + Double(components.attoseconds) / 1_000_000_000_000_000
}

private func withTemporaryDirectory<Value>(
    prefix: String,
    operation: (URL) async throws -> Value
) async throws -> Value {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    return try await operation(directory)
}

private extension ProcessInfo {
    var machineArchitecture: String {
        var system = utsname()
        uname(&system)
        return withUnsafePointer(to: &system.machine) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: 1) {
                String(cString: $0)
            }
        }
    }
}
