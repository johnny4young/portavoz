import ApplicationKit
import Darwin
import Foundation
import PortavozCore
import SQLiteVecResearchKit
import StorageKit
import XCTest

final class ExactPathScaleBenchmarkTests: XCTestCase {
    func testEnvironmentRequiresCanonicalScaleAndBoundedRuns() throws {
        XCTAssertNil(try ExactPathScaleBenchmarkOptions.environmentOptions([:]))
        XCTAssertEqual(
            ExactPathScaleBenchmarkOptions.canonicalCorpusSizes,
            [1_000, 10_000, 50_000, 100_000])

        XCTAssertThrowsError(try ExactPathScaleBenchmarkOptions.environmentOptions([
            "PORTAVOZ_EXACT_PATH_BENCHMARK": "1",
            "PORTAVOZ_EXACT_PATH_SCALE": "999",
        ])) {
            XCTAssertEqual($0 as? ExactPathScaleBenchmarkError, .invalidCorpusSize)
        }
        XCTAssertThrowsError(try ExactPathScaleBenchmarkOptions.environmentOptions([
            "PORTAVOZ_EXACT_PATH_BENCHMARK": "1",
            "PORTAVOZ_EXACT_PATH_SCALE": "1000",
            "PORTAVOZ_EXACT_PATH_RUNS": "2",
        ])) {
            XCTAssertEqual($0 as? ExactPathScaleBenchmarkError, .invalidRuns)
        }

        let options = try XCTUnwrap(
            ExactPathScaleBenchmarkOptions.environmentOptions([
                "PORTAVOZ_EXACT_PATH_BENCHMARK": "1",
                "PORTAVOZ_EXACT_PATH_SCALE": "10000",
                "PORTAVOZ_EXACT_PATH_RUNS": "7",
            ]))
        XCTAssertEqual(options.corpusSize, 10_000)
        XCTAssertEqual(options.dimension, 512)
        XCTAssertEqual(options.queryCount, 8)
        XCTAssertEqual(options.runsPerQuery, 7)
        XCTAssertEqual(options.resultLimit, 10)
    }

    func testSmallHarnessSeparatesBuildAndQueryWithoutPayload() async throws {
        let report = try await ExactPathScaleBenchmark.run(options: .init(
            corpusSize: 48,
            dimension: 8,
            queryCount: 3,
            runsPerQuery: 2,
            resultLimit: 5))

        XCTAssertEqual(report.schemaVersion, 1)
        XCTAssertEqual(report.fixtureVersion, "synthetic-exact-path-v1")
        XCTAssertEqual(report.measurementPolicyVersion, "alternating-query-order-v1")
        XCTAssertEqual(report.configuration.corpusSize, 48)
        XCTAssertEqual(report.configuration.rawEmbeddingBytes, 1_536)
        XCTAssertGreaterThan(report.configuration.controlDatabaseBytes, 0)
        XCTAssertEqual(report.engines.map(\.engine), [.accelerateExact, .sqliteVecExact])
        XCTAssertTrue(report.engines.allSatisfy { $0.buildMilliseconds >= 0 })
        XCTAssertTrue(report.engines.allSatisfy {
            $0.queryWallMilliseconds.sampleCount == 6
        })
        XCTAssertEqual(report.agreement.comparisonCount, 6)
        XCTAssertEqual(report.agreement.topHitMatchCount, 6)
        XCTAssertEqual(report.agreement.expectedTopHitCount, 6)
        XCTAssertEqual(report.agreement.exactRankMatchCount, 6)
        XCTAssertEqual(report.agreement.overlapAtKCount, 30)

        let data = try JSONEncoder.exactPathBenchmark.encode(report)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        for forbidden in [
            "segmentID", "meetingID", "transcript", "queryVector",
            "modelIdentifier", "databasePath", "Synthetic exact-path benchmark",
        ] {
            XCTAssertFalse(json.contains(forbidden), "payload leaked: \(forbidden)")
        }
    }

    func testCanonicalExactPathBenchmarkFromEnvironment() async throws {
        guard let options = try ExactPathScaleBenchmarkOptions.environmentOptions(
            ProcessInfo.processInfo.environment)
        else {
            XCTAssertEqual(
                ExactPathScaleBenchmarkOptions.canonicalCorpusSizes.last,
                100_000)
            return
        }

        let report = try await ExactPathScaleBenchmark.run(options: options)
        let data = try JSONEncoder.exactPathBenchmark.encode(report)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        print("PORTAVOZ_EXACT_PATH_REPORT \(json)")
    }
}

private enum ExactPathScaleBenchmarkError: Error, Equatable {
    case invalidCorpusSize
    case invalidRuns
    case invalidConfiguration
    case fixturePublicationMismatch
    case invalidResultCount
    case unexpectedTopHit
}

private struct ExactPathScaleBenchmarkOptions: Equatable, Sendable {
    static let canonicalCorpusSizes = [1_000, 10_000, 50_000, 100_000]

    let corpusSize: Int
    let dimension: Int
    let queryCount: Int
    let runsPerQuery: Int
    let resultLimit: Int

    static func environmentOptions(
        _ environment: [String: String]
    ) throws -> ExactPathScaleBenchmarkOptions? {
        guard environment["PORTAVOZ_EXACT_PATH_BENCHMARK"] == "1" else {
            return nil
        }
        guard let rawCorpusSize = environment["PORTAVOZ_EXACT_PATH_SCALE"],
              let corpusSize = Int(rawCorpusSize),
              canonicalCorpusSizes.contains(corpusSize)
        else {
            throw ExactPathScaleBenchmarkError.invalidCorpusSize
        }
        let runs = environment["PORTAVOZ_EXACT_PATH_RUNS"].flatMap(Int.init) ?? 5
        guard (3...50).contains(runs) else {
            throw ExactPathScaleBenchmarkError.invalidRuns
        }
        return ExactPathScaleBenchmarkOptions(
            corpusSize: corpusSize,
            dimension: 512,
            queryCount: 8,
            runsPerQuery: runs,
            resultLimit: 10)
    }

    var isValid: Bool {
        corpusSize > 0
            && dimension > 0
            && queryCount > 0
            && queryCount <= corpusSize
            && runsPerQuery > 0
            && resultLimit > 0
            && resultLimit <= corpusSize
    }
}

private struct ExactPathScaleBenchmarkReport: Codable, Sendable {
    let schemaVersion: Int
    let fixtureVersion: String
    let measurementPolicyVersion: String
    let buildConfiguration: String
    let host: Host
    let configuration: Configuration
    let engines: [EngineObservation]
    let agreement: Agreement

    struct Host: Codable, Sendable {
        let operatingSystem: String
        let architecture: String
        let processorCount: Int
        let physicalMemoryBytes: UInt64
    }

    struct Configuration: Codable, Sendable {
        let corpusSize: Int
        let dimension: Int
        let queryCount: Int
        let runsPerQuery: Int
        let resultLimit: Int
        let rawEmbeddingBytes: Int64
        let controlDatabaseBytes: Int64
        let fixturePreparationMilliseconds: Double
        let buildOrder: String
    }

    struct EngineObservation: Codable, Sendable {
        let engine: Engine
        let buildMilliseconds: Double
        let queryWallMilliseconds: MillisecondDistribution
        let resultCount: Int
    }

    enum Engine: String, Codable, Sendable {
        case accelerateExact
        case sqliteVecExact
    }

    struct Agreement: Codable, Sendable {
        let comparisonCount: Int
        let expectedTopHitCount: Int
        let topHitMatchCount: Int
        let exactRankMatchCount: Int
        let overlapAtKCount: Int
    }
}

private struct MillisecondDistribution: Codable, Sendable {
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

private enum ExactPathScaleBenchmark {
    private static let segmentsPerMeeting = 200

    static func run(
        options: ExactPathScaleBenchmarkOptions
    ) async throws -> ExactPathScaleBenchmarkReport {
        guard options.isValid else {
            throw ExactPathScaleBenchmarkError.invalidConfiguration
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "portavoz-exact-path-benchmark-\(UUID().uuidString)",
            isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let fixtureStart = ContinuousClock.now
        let fixture = ExactPathFixture.make(options: options)
        let fixtureMilliseconds = milliseconds(since: fixtureStart)
        let profile = SemanticEmbeddingProfile(
            modelIdentifier: "portavoz.research.synthetic-exact-path-v1",
            modelRevision: 1,
            vectorDimension: options.dimension,
            pipelineIdentifier: "deterministic-normalized-lcg-v1",
            pipelineRevision: 1,
            vectorSchemaVersion: 1)

        let controlBuildStart = ContinuousClock.now
        let databaseURL = directory.appendingPathComponent("control.sqlite")
        let store = try MeetingStore(databaseURL: databaseURL)
        try await seedControl(
            store: store,
            entries: fixture.entries,
            profile: profile)
        let controlBuildMilliseconds = milliseconds(since: controlBuildStart)

        let candidateBuildStart = ContinuousClock.now
        let candidate = try SQLiteVecExactShadowRanker(
            profile: profile,
            entries: fixture.entries)
        let candidateBuildMilliseconds = milliseconds(since: candidateBuildStart)
        let control = AccelerateExactSemanticIndex(store: store)

        for queryPosition in fixture.queryPositions {
            _ = try await control.search(
                fixture.entries[queryPosition].vector,
                profile: profile,
                limit: options.resultLimit)
            _ = try await candidate.rankedCandidates(
                for: fixture.entries[queryPosition].vector,
                profile: profile,
                limit: options.resultLimit)
        }

        var controlSamples: [Double] = []
        var candidateSamples: [Double] = []
        controlSamples.reserveCapacity(options.queryCount * options.runsPerQuery)
        candidateSamples.reserveCapacity(options.queryCount * options.runsPerQuery)
        var agreement = ExactPathAgreementAccumulator()
        var controlResultCount = 0
        var candidateResultCount = 0

        for (queryOffset, queryPosition) in fixture.queryPositions.enumerated() {
            let query = fixture.entries[queryPosition].vector
            let expected = fixture.entries[queryPosition].identity
            for run in 0..<options.runsPerQuery {
                let controlFirst = (queryOffset * options.runsPerQuery + run).isMultiple(of: 2)
                let controlMeasurement: (value: [SemanticSearchCandidateIdentity], ms: Double)
                let candidateMeasurement: (value: [SemanticSearchCandidateIdentity], ms: Double)
                if controlFirst {
                    controlMeasurement = try await measure {
                        try await control.search(query, profile: profile, limit: options.resultLimit)
                            .map {
                                SemanticSearchCandidateIdentity(
                                    segmentID: $0.segmentID,
                                    transcriptRevision: $0.transcriptRevision)
                            }
                    }
                    candidateMeasurement = try await measure {
                        try await candidate.rankedCandidates(
                            for: query,
                            profile: profile,
                            limit: options.resultLimit)
                    }
                } else {
                    candidateMeasurement = try await measure {
                        try await candidate.rankedCandidates(
                            for: query,
                            profile: profile,
                            limit: options.resultLimit)
                    }
                    controlMeasurement = try await measure {
                        try await control.search(query, profile: profile, limit: options.resultLimit)
                            .map {
                                SemanticSearchCandidateIdentity(
                                    segmentID: $0.segmentID,
                                    transcriptRevision: $0.transcriptRevision)
                            }
                    }
                }
                guard controlMeasurement.value.count == options.resultLimit,
                      candidateMeasurement.value.count == options.resultLimit
                else {
                    throw ExactPathScaleBenchmarkError.invalidResultCount
                }
                guard controlMeasurement.value.first == expected,
                      candidateMeasurement.value.first == expected
                else {
                    throw ExactPathScaleBenchmarkError.unexpectedTopHit
                }
                controlSamples.append(controlMeasurement.ms)
                candidateSamples.append(candidateMeasurement.ms)
                controlResultCount = controlMeasurement.value.count
                candidateResultCount = candidateMeasurement.value.count
                agreement.record(
                    expected: expected,
                    control: controlMeasurement.value,
                    candidate: candidateMeasurement.value)
            }
        }

        #if DEBUG
        let buildConfiguration = "debug"
        #else
        let buildConfiguration = "release"
        #endif
        return ExactPathScaleBenchmarkReport(
            schemaVersion: 1,
            fixtureVersion: "synthetic-exact-path-v1",
            measurementPolicyVersion: "alternating-query-order-v1",
            buildConfiguration: buildConfiguration,
            host: .init(
                operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
                architecture: machineArchitecture(),
                processorCount: ProcessInfo.processInfo.processorCount,
                physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory),
            configuration: .init(
                corpusSize: options.corpusSize,
                dimension: options.dimension,
                queryCount: options.queryCount,
                runsPerQuery: options.runsPerQuery,
                resultLimit: options.resultLimit,
                rawEmbeddingBytes: Int64(
                    options.corpusSize * options.dimension * MemoryLayout<Float>.size),
                controlDatabaseBytes: try allocatedSize(of: directory),
                fixturePreparationMilliseconds: fixtureMilliseconds,
                buildOrder: "accelerate-control-then-sqlite-vec-v1"),
            engines: [
                .init(
                    engine: .accelerateExact,
                    buildMilliseconds: controlBuildMilliseconds,
                    queryWallMilliseconds: .init(controlSamples),
                    resultCount: controlResultCount),
                .init(
                    engine: .sqliteVecExact,
                    buildMilliseconds: candidateBuildMilliseconds,
                    queryWallMilliseconds: .init(candidateSamples),
                    resultCount: candidateResultCount),
            ],
            agreement: agreement.report)
    }

    private static func seedControl(
        store: MeetingStore,
        entries: [SQLiteVecShadowEntry],
        profile: SemanticEmbeddingProfile
    ) async throws {
        for lowerBound in stride(from: 0, to: entries.count, by: segmentsPerMeeting) {
            let upperBound = min(lowerBound + segmentsPerMeeting, entries.count)
            let batch = Array(entries[lowerBound..<upperBound])
            let meeting = Meeting(
                title: "Synthetic exact-path benchmark",
                startedAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(lowerBound)))
            let speaker = Speaker(meetingID: meeting.id, label: "S1")
            let segments = batch.enumerated().map { offset, entry in
                TranscriptSegment(
                    id: entry.identity.segmentID,
                    meetingID: meeting.id,
                    speakerID: speaker.id,
                    channel: .system,
                    text: "Synthetic exact-path benchmark",
                    startTime: Double(offset),
                    endTime: Double(offset + 1),
                    isFinal: true)
            }
            try await store.save(meeting)
            try await store.save([speaker])
            try await store.save(segments)
            let candidates = try await store.segmentsNeedingEmbeddings(limit: batch.count)
            guard Set(candidates.map(\.id)) == Set(batch.map(\.identity.segmentID)) else {
                throw ExactPathScaleBenchmarkError.fixturePublicationMismatch
            }
            let embeddings = Dictionary(uniqueKeysWithValues: batch.map {
                ($0.identity.segmentID, $0.vector)
            })
            let result = try await store.storeEmbeddings(
                embeddings,
                for: candidates,
                profile: profile)
            guard result.publishedSegmentIDs == Set(batch.map(\.identity.segmentID)),
                  result.skippedSegmentIDs.isEmpty
            else {
                throw ExactPathScaleBenchmarkError.fixturePublicationMismatch
            }
        }
    }

    private static func measure<Value: Sendable>(
        operation: () async throws -> Value
    ) async throws -> (value: Value, ms: Double) {
        let start = ContinuousClock.now
        let value = try await operation()
        return (value, milliseconds(since: start))
    }

    private static func milliseconds(since start: ContinuousClock.Instant) -> Double {
        let components = start.duration(to: .now).components
        return Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1_000_000_000_000_000
    }

    private static func allocatedSize(of directory: URL) throws -> Int64 {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileAllocatedSizeKey]
        let files = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: Array(keys))
        var bytes: Int64 = 0
        while let file = files?.nextObject() as? URL {
            let values = try file.resourceValues(forKeys: keys)
            if values.isRegularFile == true {
                bytes += Int64(values.fileAllocatedSize ?? 0)
            }
        }
        return bytes
    }

    private static func machineArchitecture() -> String {
        var system = utsname()
        uname(&system)
        return withUnsafePointer(to: &system.machine) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: 1) {
                String(cString: $0)
            }
        }
    }
}

private struct ExactPathFixture {
    let entries: [SQLiteVecShadowEntry]
    let queryPositions: [Int]

    static func make(options: ExactPathScaleBenchmarkOptions) -> ExactPathFixture {
        let entries = (0..<options.corpusSize).map { position in
            SQLiteVecShadowEntry(
                identity: SemanticSearchCandidateIdentity(
                    segmentID: UUID(),
                    transcriptRevision: 0),
                vector: vector(position: position, dimension: options.dimension))
        }
        let queryPositions = (0..<options.queryCount).map { offset in
            (offset + 1) * options.corpusSize / (options.queryCount + 1)
        }
        return ExactPathFixture(entries: entries, queryPositions: queryPositions)
    }

    private static func vector(position: Int, dimension: Int) -> [Float] {
        var state = UInt64(truncatingIfNeeded: position + 1) &* 0x9E37_79B9_7F4A_7C15
        var values = [Float](repeating: 0, count: dimension)
        var normSquared: Float = 0
        for offset in values.indices {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let unit = Float(state >> 40) / Float(1 << 24)
            values[offset] = unit * 2 - 1
            normSquared += values[offset] * values[offset]
        }
        let norm = sqrt(normSquared)
        if norm > 0 {
            for offset in values.indices { values[offset] /= norm }
        }
        return values
    }
}

private struct ExactPathAgreementAccumulator {
    private(set) var comparisonCount = 0
    private(set) var expectedTopHitCount = 0
    private(set) var topHitMatchCount = 0
    private(set) var exactRankMatchCount = 0
    private(set) var overlapAtKCount = 0

    mutating func record(
        expected: SemanticSearchCandidateIdentity,
        control: [SemanticSearchCandidateIdentity],
        candidate: [SemanticSearchCandidateIdentity]
    ) {
        comparisonCount += 1
        if control.first == expected, candidate.first == expected {
            expectedTopHitCount += 1
        }
        if control.first == candidate.first { topHitMatchCount += 1 }
        if control == candidate { exactRankMatchCount += 1 }
        overlapAtKCount += Set(control).intersection(candidate).count
    }

    var report: ExactPathScaleBenchmarkReport.Agreement {
        .init(
            comparisonCount: comparisonCount,
            expectedTopHitCount: expectedTopHitCount,
            topHitMatchCount: topHitMatchCount,
            exactRankMatchCount: exactRankMatchCount,
            overlapAtKCount: overlapAtKCount)
    }
}

private extension JSONEncoder {
    static var exactPathBenchmark: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}
