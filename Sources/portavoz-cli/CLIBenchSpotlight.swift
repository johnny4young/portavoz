import CoreSpotlight
import CryptoKit
import Darwin
import Foundation
import GRDB
import PortavozCore
import StorageKit
import UniformTypeIdentifiers

/// `portavoz-cli bench-spotlight --mode legacy|snapshot --meetings 100000
///     [--runs 3] [--delivery-items 1000] [--output checkpoint.json]`
///
/// Band 4G's isolated projection and delivery probe. Fixtures use the current
/// production schema in a throwaway directory. Optional Core Spotlight work
/// uses a unique protected named index, synthetic text only, and deletes the
/// benchmark domain before returning.
enum BenchSpotlightCommand {
    static func run(_ arguments: [String]) async {
        do {
            let options = try SpotlightBenchmarkOptions(arguments: arguments)
            let report = try await SpotlightBenchmark.run(options: options)
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
                print("Spotlight benchmark checkpoint: \(url.path)")
            } else {
                FileHandle.standardOutput.write(data)
                FileHandle.standardOutput.write(Data("\n".utf8))
            }
        } catch {
            FileHandle.standardError.write(Data("bench-spotlight error: \(error)\n".utf8))
            Foundation.exit(64)
        }
    }
}

private struct SpotlightBenchmarkOptions {
    var mode = SpotlightProjectionMode.snapshot
    var meetings = 100_000
    var runs = 3
    var deliveryItems = 0
    var output: String?

    init(arguments: [String]) throws {
        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--mode":
                index += 1
                guard arguments.indices.contains(index),
                      let value = SpotlightProjectionMode(rawValue: arguments[index])
                else { throw SpotlightBenchmarkError.invalidMode }
                mode = value
            case "--meetings":
                index += 1
                guard arguments.indices.contains(index),
                      let value = Int(arguments[index]), (1...100_000).contains(value)
                else { throw SpotlightBenchmarkError.invalidMeetings }
                meetings = value
            case "--runs":
                index += 1
                guard arguments.indices.contains(index),
                      let value = Int(arguments[index]), (3...20).contains(value)
                else { throw SpotlightBenchmarkError.invalidRuns }
                runs = value
            case "--delivery-items":
                index += 1
                guard arguments.indices.contains(index),
                      let value = Int(arguments[index]), (0...10_000).contains(value)
                else { throw SpotlightBenchmarkError.invalidDeliveryItems }
                deliveryItems = value
            case "--output":
                index += 1
                guard arguments.indices.contains(index), !arguments[index].isEmpty
                else { throw SpotlightBenchmarkError.missingOptionValue("--output") }
                output = arguments[index]
            default:
                throw SpotlightBenchmarkError.unknownOption(arguments[index])
            }
            index += 1
        }
    }
}

private enum SpotlightProjectionMode: String, Codable {
    case legacy
    case snapshot
}

private enum SpotlightBenchmarkError: Error, CustomStringConvertible {
    case invalidDeliveryItems
    case invalidMeetings
    case invalidMode
    case invalidRetentionEncoding
    case invalidRuns
    case missingOptionValue(String)
    case processUsageUnavailable
    case projectionCountMismatch(expected: Int, actual: Int)
    case unknownOption(String)

    var description: String {
        switch self {
        case .invalidDeliveryItems:
            "--delivery-items must be between 0 and 10000"
        case .invalidMeetings:
            "--meetings must be between 1 and 100000"
        case .invalidMode:
            "--mode must be legacy or snapshot"
        case .invalidRetentionEncoding:
            "could not encode the benchmark retention policy"
        case .invalidRuns:
            "--runs must be between 3 and 20"
        case .missingOptionValue(let option):
            "missing value after \(option)"
        case .processUsageUnavailable:
            "could not read process CPU and physical-footprint counters"
        case .projectionCountMismatch(let expected, let actual):
            "projection returned \(actual) documents for \(expected) live meetings"
        case .unknownOption(let option):
            "unknown option \(option)"
        }
    }
}

private struct SpotlightBenchmarkReport: Codable {
    let schemaVersion: Int
    let generatedAt: Date
    let buildConfiguration: String
    let host: Host
    let configuration: Configuration
    let checkpoint: Checkpoint

    struct Host: Codable {
        let operatingSystem: String
        let architecture: String
        let processorCount: Int
        let physicalMemoryBytes: UInt64
    }

    struct Configuration: Codable {
        let mode: SpotlightProjectionMode
        let measurementRuns: Int
        let segmentsPerMeeting: Int
        let summariesEvery: Int
        let indexedSegmentLimit: Int
        let descriptionCharacterLimit: Int
        let deliveryBatchSize: Int
    }

    struct Checkpoint: Codable {
        let meetingCount: Int
        let segmentCount: Int
        let summaryCount: Int
        let seedMilliseconds: Double
        let databaseBytes: Int64
        let documentCount: Int
        let descriptionCharacterCount: Int
        let resultFingerprint: String
        let projection: SpotlightResourceMeasurement
        let delivery: SpotlightDeliveryMeasurement?
    }
}

private struct SpotlightResourceMeasurement: Codable {
    let wallTime: SpotlightMillisecondDistribution
    let processCPUTime: SpotlightMillisecondDistribution
    let baselinePhysicalFootprint: SpotlightByteDistribution
    let peakPhysicalFootprint: SpotlightByteDistribution
    let incrementalPeakPhysicalFootprint: SpotlightByteDistribution
    let endingPhysicalFootprint: SpotlightByteDistribution
}

private struct SpotlightDeliveryMeasurement: Codable {
    let status: String
    let syntheticItemCount: Int
    let namedIndex: Bool
    let protection: String
    let contentSource: String
    let indexMilliseconds: Double?
    let cleanupMilliseconds: Double?
    let cleanupSucceeded: Bool
}

private struct SpotlightMillisecondDistribution: Codable {
    let sampleCount: Int
    let p50Milliseconds: Double
    let p95Milliseconds: Double
    let maximumMilliseconds: Double

    init(_ samples: [Double]) {
        let ordered = samples.sorted()
        sampleCount = ordered.count
        p50Milliseconds = ordered[Self.index(0.50, count: ordered.count)]
        p95Milliseconds = ordered[Self.index(0.95, count: ordered.count)]
        maximumMilliseconds = ordered.last ?? 0
    }

    private static func index(_ percentile: Double, count: Int) -> Int {
        min(count - 1, max(0, Int(ceil(Double(count) * percentile)) - 1))
    }
}

private struct SpotlightByteDistribution: Codable {
    let sampleCount: Int
    let p50Bytes: UInt64
    let p95Bytes: UInt64
    let maximumBytes: UInt64

    init(_ samples: [UInt64]) {
        let ordered = samples.sorted()
        sampleCount = ordered.count
        p50Bytes = ordered[Self.index(0.50, count: ordered.count)]
        p95Bytes = ordered[Self.index(0.95, count: ordered.count)]
        maximumBytes = ordered.last ?? 0
    }

    private static func index(_ percentile: Double, count: Int) -> Int {
        min(count - 1, max(0, Int(ceil(Double(count) * percentile)) - 1))
    }
}

private enum SpotlightBenchmark {
    private static let summariesEvery = 2
    private static let indexedSegmentLimit = 40
    private static let descriptionCharacterLimit = 4_000
    private static let deliveryBatchSize = 500

    static func run(options: SpotlightBenchmarkOptions) async throws -> SpotlightBenchmarkReport {
        #if DEBUG
        let buildConfiguration = "debug"
        #else
        let buildConfiguration = "release"
        #endif

        return try await withSpotlightTemporaryDirectory { directory in
            let databaseURL = directory.appendingPathComponent("spotlight.sqlite")
            let seedStart = ContinuousClock.now
            try seed(databaseURL: databaseURL, meetingCount: options.meetings)
            let seedMilliseconds = spotlightMilliseconds(since: seedStart)
            let store = try MeetingStore(databaseURL: databaseURL)
            let measurement = try await measure(runs: options.runs) {
                switch options.mode {
                case .legacy:
                    try await legacyDocuments(store: store)
                case .snapshot:
                    try await store.spotlightDocuments()
                }
            }
            guard measurement.documents.count == options.meetings else {
                throw SpotlightBenchmarkError.projectionCountMismatch(
                    expected: options.meetings,
                    actual: measurement.documents.count)
            }
            let delivery = try await measureSyntheticDelivery(itemCount: options.deliveryItems)

            return SpotlightBenchmarkReport(
                schemaVersion: 1,
                generatedAt: Date(),
                buildConfiguration: buildConfiguration,
                host: .init(
                    operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
                    architecture: ProcessInfo.processInfo.spotlightMachineArchitecture,
                    processorCount: ProcessInfo.processInfo.processorCount,
                    physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory),
                configuration: .init(
                    mode: options.mode,
                    measurementRuns: options.runs,
                    segmentsPerMeeting: 1,
                    summariesEvery: summariesEvery,
                    indexedSegmentLimit: indexedSegmentLimit,
                    descriptionCharacterLimit: descriptionCharacterLimit,
                    deliveryBatchSize: deliveryBatchSize),
                checkpoint: .init(
                    meetingCount: options.meetings,
                    segmentCount: options.meetings,
                    summaryCount: Int(ceil(Double(options.meetings) / Double(summariesEvery))),
                    seedMilliseconds: seedMilliseconds,
                    databaseBytes: try FileManager.default.allocatedSizeOfDirectory(at: directory),
                    documentCount: measurement.documents.count,
                    descriptionCharacterCount: measurement.documents.reduce(0) {
                        $0 + $1.contentDescription.count
                    },
                    resultFingerprint: fingerprint(measurement.documents),
                    projection: measurement.resources,
                    delivery: delivery))
        }
    }

    private static func seed(databaseURL: URL, meetingCount: Int) throws {
        do {
            let migrationStore = try MeetingStore(databaseURL: databaseURL)
            withExtendedLifetime(migrationStore) {}
        }
        let database = try DatabaseQueue(path: databaseURL.path)
        let retentionData = try JSONEncoder().encode(AudioRetentionPolicy.keep)
        guard let retention = String(data: retentionData, encoding: .utf8) else {
            throw SpotlightBenchmarkError.invalidRetentionEncoding
        }
        try database.write { db in
            let meeting = try db.makeStatement(sql: """
                    INSERT INTO meeting (
                        id, title, startedAt, endedAt, language, audioDirectory,
                        retention, visibility, lifecycleState, transcriptRevision,
                        lastProcessingError, createdAt, updatedAt, deletedAt
                    ) VALUES (?, ?, ?, NULL, 'en', NULL, ?, 'private', 'ready', 0, NULL, ?, ?, NULL)
                    """)
            let segment = try db.makeStatement(sql: """
                    INSERT INTO segment (
                        id, meetingID, speakerID, channel, text, language,
                        startTime, endTime, confidence, isFinal, generationRunID,
                        createdAt, updatedAt, deletedAt, embedding
                    ) VALUES (?, ?, NULL, 'system', ?, 'en', 0, 4, 0.95, 1, NULL, ?, ?, NULL, NULL)
                    """)
            let summary = try db.makeStatement(sql: """
                    INSERT INTO summary (
                        id, meetingID, recipeID, language, markdown, version,
                        fingerprint, generationRunID, createdAt, deletedAt
                    ) VALUES (?, ?, ?, 'en', ?, 1, NULL, NULL, ?, NULL)
                    """)
            let base = Date(timeIntervalSince1970: 1_700_000_000)
            for index in 0..<meetingCount {
                let meetingID = spotlightUUID(namespace: 0x1000_0000, index: index)
                let timestamp = base.addingTimeInterval(Double(index * 60))
                try meeting.execute(arguments: [
                    meetingID,
                    "Spotlight benchmark meeting \(index)",
                    timestamp,
                    retention,
                    timestamp,
                    timestamp
                ])
                try segment.execute(arguments: [
                    spotlightUUID(namespace: 0x2000_0000, index: index),
                    meetingID,
                    "Synthetic transcript turn \(index)",
                    timestamp,
                    timestamp
                ])
                if index.isMultiple(of: summariesEvery) {
                    try summary.execute(arguments: [
                        spotlightUUID(namespace: 0x3000_0000, index: index),
                        meetingID,
                        Recipe.general.id,
                        "Synthetic summary \(index)",
                        timestamp
                    ])
                }
            }
        }
    }

    /// Preserves the pre-4G data path for a comparable baseline: one list
    /// read, then full detail plus General-summary reads for every meeting.
    private static func legacyDocuments(store: MeetingStore) async throws -> [SpotlightDocument] {
        let meetings = try await store.meetings()
        var documents: [SpotlightDocument] = []
        documents.reserveCapacity(meetings.count)
        for meeting in meetings {
            var body = ""
            if let detail = try? await store.detail(meeting.id) {
                let summary = (try? await store.summary(meeting.id))?.draft.markdown
                let transcript = detail.segments.prefix(indexedSegmentLimit)
                    .map(\.text)
                    .joined(separator: " ")
                body = [summary, transcript].compactMap { $0 }.joined(separator: "\n")
            }
            documents.append(SpotlightDocument(
                meetingID: meeting.id,
                title: meeting.title,
                startedAt: meeting.startedAt,
                contentDescription: String(body.prefix(descriptionCharacterLimit))))
        }
        return documents
    }

    private struct Measurement {
        let documents: [SpotlightDocument]
        let resources: SpotlightResourceMeasurement
    }

    private static func measure(
        runs: Int,
        operation: () async throws -> [SpotlightDocument]
    ) async throws -> Measurement {
        var wall: [Double] = []
        var cpu: [Double] = []
        var baseline: [UInt64] = []
        var peak: [UInt64] = []
        var incremental: [UInt64] = []
        var ending: [UInt64] = []
        var documents: [SpotlightDocument] = []
        for _ in 0..<runs {
            malloc_zone_pressure_relief(nil, 0)
            let before = try SpotlightProcessUsage.current()
            let sampler = Task.detached(priority: .high) { () -> UInt64 in
                var maximum = before.physicalFootprintBytes
                while !Task.isCancelled {
                    if let usage = try? SpotlightProcessUsage.current() {
                        maximum = max(maximum, usage.physicalFootprintBytes)
                    }
                    try? await Task.sleep(for: .milliseconds(1))
                }
                return maximum
            }
            let start = ContinuousClock.now
            documents = try await operation()
            let elapsed = spotlightMilliseconds(since: start)
            let after = try SpotlightProcessUsage.current()
            sampler.cancel()
            let maximum = max(after.physicalFootprintBytes, await sampler.value)
            wall.append(elapsed)
            let ticks = after.cpuAbsoluteTime - min(after.cpuAbsoluteTime, before.cpuAbsoluteTime)
            cpu.append(spotlightCPUMilliseconds(ticks: ticks))
            baseline.append(before.physicalFootprintBytes)
            peak.append(maximum)
            incremental.append(maximum - min(maximum, before.physicalFootprintBytes))
            ending.append(after.physicalFootprintBytes)
        }
        return Measurement(
            documents: documents,
            resources: SpotlightResourceMeasurement(
                wallTime: .init(wall),
                processCPUTime: .init(cpu),
                baselinePhysicalFootprint: .init(baseline),
                peakPhysicalFootprint: .init(peak),
                incrementalPeakPhysicalFootprint: .init(incremental),
                endingPhysicalFootprint: .init(ending)))
    }

    private static func measureSyntheticDelivery(
        itemCount: Int
    ) async throws -> SpotlightDeliveryMeasurement? {
        guard itemCount > 0 else { return nil }
        guard CSSearchableIndex.isIndexingAvailable() else {
            return SpotlightDeliveryMeasurement(
                status: "unavailable",
                syntheticItemCount: itemCount,
                namedIndex: true,
                protection: "complete",
                contentSource: "synthetic-only",
                indexMilliseconds: nil,
                cleanupMilliseconds: nil,
                cleanupSucceeded: false)
        }
        let token = UUID().uuidString
        let domain = "app.portavoz.benchmark.\(token)"
        let index = CSSearchableIndex(
            name: "app.portavoz.benchmark.\(token)",
            protectionClass: .complete)
        let items = (0..<itemCount).map { itemIndex -> CSSearchableItem in
            let attributes = CSSearchableItemAttributeSet(contentType: .content)
            attributes.title = "Portavoz synthetic benchmark \(itemIndex)"
            attributes.contentDescription = "Synthetic local indexing fixture"
            return CSSearchableItem(
                uniqueIdentifier: "\(token)-\(itemIndex)",
                domainIdentifier: domain,
                attributeSet: attributes)
        }
        let indexStart = ContinuousClock.now
        index.beginBatch()
        do {
            try await index.deleteSearchableItems(withDomainIdentifiers: [domain])
            for start in stride(from: 0, to: items.count, by: deliveryBatchSize) {
                let end = min(start + deliveryBatchSize, items.count)
                try await index.indexSearchableItems(Array(items[start..<end]))
            }
        } catch {
            try? await index.endBatch(withClientState: Data("incomplete".utf8))
            throw error
        }
        try await index.endBatch(withClientState: Data("v1:\(itemCount)".utf8))
        let indexMilliseconds = spotlightMilliseconds(since: indexStart)
        let cleanupStart = ContinuousClock.now
        try await index.deleteSearchableItems(withDomainIdentifiers: [domain])
        let cleanupMilliseconds = spotlightMilliseconds(since: cleanupStart)
        return SpotlightDeliveryMeasurement(
            status: "completed",
            syntheticItemCount: itemCount,
            namedIndex: true,
            protection: "complete",
            contentSource: "synthetic-only",
            indexMilliseconds: indexMilliseconds,
            cleanupMilliseconds: cleanupMilliseconds,
            cleanupSucceeded: true)
    }

    private static func fingerprint(_ documents: [SpotlightDocument]) -> String {
        var hasher = SHA256()
        for document in documents {
            spotlightHash(&hasher, document.meetingID.rawValue.uuidString)
            spotlightHash(&hasher, document.title)
            var startedAt = document.startedAt.timeIntervalSinceReferenceDate.bitPattern.littleEndian
            withUnsafeBytes(of: &startedAt) { hasher.update(bufferPointer: $0) }
            spotlightHash(&hasher, document.contentDescription)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

private struct SpotlightProcessUsage: Sendable {
    let cpuAbsoluteTime: UInt64
    let physicalFootprintBytes: UInt64

    static func current() throws -> SpotlightProcessUsage {
        var usage = rusage_info_current()
        let result = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(getpid(), RUSAGE_INFO_CURRENT, $0)
            }
        }
        guard result == 0 else { throw SpotlightBenchmarkError.processUsageUnavailable }
        return SpotlightProcessUsage(
            cpuAbsoluteTime: usage.ri_user_time + usage.ri_system_time,
            physicalFootprintBytes: usage.ri_phys_footprint)
    }
}

private func spotlightUUID(namespace: UInt32, index: Int) -> String {
    String(format: "%08X-0000-4000-8000-%012llX", namespace, UInt64(index))
}

private func spotlightHash(_ hasher: inout SHA256, _ string: String) {
    let data = Data(string.utf8)
    var count = UInt64(data.count).littleEndian
    withUnsafeBytes(of: &count) { hasher.update(bufferPointer: $0) }
    hasher.update(data: data)
}

private func spotlightCPUMilliseconds(ticks: UInt64) -> Double {
    var timebase = mach_timebase_info_data_t()
    mach_timebase_info(&timebase)
    return Double(ticks) * Double(timebase.numer) / Double(timebase.denom) / 1_000_000
}

private func spotlightMilliseconds(since start: ContinuousClock.Instant) -> Double {
    let duration = start.duration(to: .now)
    let components = duration.components
    return Double(components.seconds) * 1_000
        + Double(components.attoseconds) / 1_000_000_000_000_000
}

private func withSpotlightTemporaryDirectory<Value>(
    operation: (URL) async throws -> Value
) async throws -> Value {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("portavoz-bench-spotlight-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    return try await operation(directory)
}

private extension ProcessInfo {
    var spotlightMachineArchitecture: String {
        var system = utsname()
        uname(&system)
        return withUnsafePointer(to: &system.machine) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: 1) {
                String(cString: $0)
            }
        }
    }
}
