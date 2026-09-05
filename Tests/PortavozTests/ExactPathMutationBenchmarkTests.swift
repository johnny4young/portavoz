import ApplicationKit
import Darwin
import Foundation
import PortavozCore
import SQLiteVecResearchKit
import StorageKit
import XCTest

final class ExactPathMutationBenchmarkTests: XCTestCase {
    func testEnvironmentRequiresCanonicalScaleAndBoundedRuns() throws {
        XCTAssertNil(try ExactPathMutationOptions.environmentOptions([:]))
        XCTAssertEqual(ExactPathMutationOptions.canonicalBatchSizes, [1, 10, 100])

        XCTAssertThrowsError(try ExactPathMutationOptions.environmentOptions([
            "PORTAVOZ_EXACT_PATH_MUTATION_BENCHMARK": "1",
            "PORTAVOZ_EXACT_PATH_MUTATION_SCALE": "999",
        ])) {
            XCTAssertEqual($0 as? ExactPathMutationError, .invalidCorpusSize)
        }
        XCTAssertThrowsError(try ExactPathMutationOptions.environmentOptions([
            "PORTAVOZ_EXACT_PATH_MUTATION_BENCHMARK": "1",
            "PORTAVOZ_EXACT_PATH_MUTATION_SCALE": "1000",
            "PORTAVOZ_EXACT_PATH_MUTATION_RUNS": "2",
        ])) {
            XCTAssertEqual($0 as? ExactPathMutationError, .invalidRuns)
        }

        let options = try XCTUnwrap(
            ExactPathMutationOptions.environmentOptions([
                "PORTAVOZ_EXACT_PATH_MUTATION_BENCHMARK": "1",
                "PORTAVOZ_EXACT_PATH_MUTATION_SCALE": "10000",
                "PORTAVOZ_EXACT_PATH_MUTATION_RUNS": "7",
            ]))
        XCTAssertEqual(options.corpusSize, 10_000)
        XCTAssertEqual(options.dimension, 512)
        XCTAssertEqual(options.runsPerBatch, 7)
        XCTAssertEqual(options.resultLimit, 10)
    }

    func testSmallHarnessMeasuresMutationsWithoutPayload() async throws {
        let report = try await ExactPathMutationBenchmark.run(options: .init(
            corpusSize: 128,
            dimension: 8,
            runsPerBatch: 2,
            resultLimit: 5))

        XCTAssertEqual(report.schemaVersion, 1)
        XCTAssertEqual(report.fixtureVersion, "synthetic-exact-path-mutation-v1")
        XCTAssertEqual(
            report.measurementPolicyVersion,
            "alternating-mutation-engine-order-v1")
        XCTAssertEqual(report.configuration.batchSizes, [1, 10, 100])
        XCTAssertEqual(
            report.configuration.mutationLifecycle,
            "control-authoritative-source-publication-vs-candidate-prepared-vectors-v1")
        XCTAssertEqual(report.engines.map(\.engine), [.accelerateExact, .sqliteVecExact])
        XCTAssertTrue(report.engines.allSatisfy { $0.fullRebuildMilliseconds >= 0 })
        XCTAssertTrue(report.engines.allSatisfy { engine in
            engine.mutations.count == 9
                && engine.mutations.allSatisfy {
                    $0.wallMilliseconds.sampleCount == 2
                }
        })
        XCTAssertEqual(report.agreement.comparisonCount, 19)
        XCTAssertEqual(report.agreement.expectedTopHitCount, 13)
        XCTAssertEqual(report.agreement.topHitMatchCount, 19)
        XCTAssertEqual(report.agreement.topKSetMatchCount, 19)

        let data = try JSONEncoder.exactPathMutation.encode(report)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        for forbidden in [
            "segmentID", "meetingID", "transcript", "queryVector",
            "modelIdentifier", "databasePath", "Synthetic exact-path mutation",
        ] {
            XCTAssertFalse(json.contains(forbidden), "payload leaked: \(forbidden)")
        }
    }

    func testCanonicalMutationBenchmarkFromEnvironment() async throws {
        guard let options = try ExactPathMutationOptions.environmentOptions(
            ProcessInfo.processInfo.environment)
        else {
            XCTAssertEqual(ExactPathMutationOptions.canonicalCorpusSizes.last, 100_000)
            return
        }

        let report = try await ExactPathMutationBenchmark.run(options: options)
        let data = try JSONEncoder.exactPathMutation.encode(report)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        print("PORTAVOZ_EXACT_PATH_MUTATION_REPORT \(json)")
    }
}

private enum ExactPathMutationError: Error, Equatable {
    case invalidCorpusSize
    case invalidRuns
    case invalidConfiguration
    case fixturePublicationMismatch
    case invalidResultCount
    case unexpectedTopHit
    case rankMismatch
}

private struct ExactPathMutationOptions: Equatable, Sendable {
    static let canonicalCorpusSizes = [1_000, 10_000, 50_000, 100_000]
    static let canonicalBatchSizes = [1, 10, 100]

    let corpusSize: Int
    let dimension: Int
    let runsPerBatch: Int
    let resultLimit: Int

    static func environmentOptions(
        _ environment: [String: String]
    ) throws -> ExactPathMutationOptions? {
        guard environment["PORTAVOZ_EXACT_PATH_MUTATION_BENCHMARK"] == "1" else {
            return nil
        }
        guard let rawCorpusSize = environment["PORTAVOZ_EXACT_PATH_MUTATION_SCALE"],
              let corpusSize = Int(rawCorpusSize),
              canonicalCorpusSizes.contains(corpusSize)
        else {
            throw ExactPathMutationError.invalidCorpusSize
        }
        let runs = environment["PORTAVOZ_EXACT_PATH_MUTATION_RUNS"]
            .flatMap(Int.init) ?? 5
        guard (3...20).contains(runs) else {
            throw ExactPathMutationError.invalidRuns
        }
        return ExactPathMutationOptions(
            corpusSize: corpusSize,
            dimension: 512,
            runsPerBatch: runs,
            resultLimit: 10)
    }

    var isValid: Bool {
        corpusSize >= Self.canonicalBatchSizes.last ?? 0
            && dimension > 0
            && runsPerBatch > 0
            && resultLimit > 0
            && resultLimit <= corpusSize
    }
}

private struct ExactPathMutationReport: Codable, Sendable {
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
        let runsPerBatch: Int
        let resultLimit: Int
        let batchSizes: [Int]
        let rawEmbeddingBytes: Int64
        let fixturePreparationMilliseconds: Double
        let rebuildLifecycle: String
        let mutationLifecycle: String
    }

    struct EngineObservation: Codable, Sendable {
        let engine: Engine
        let fullRebuildMilliseconds: Double
        let mutations: [MutationObservation]
    }

    struct MutationObservation: Codable, Sendable {
        let operation: Operation
        let batchSize: Int
        let wallMilliseconds: MutationMillisecondDistribution
    }

    enum Engine: String, Codable, Sendable {
        case accelerateExact
        case sqliteVecExact
    }

    enum Operation: String, Codable, Hashable, Sendable {
        case add
        case update
        case delete
    }

    struct Agreement: Codable, Sendable {
        let comparisonCount: Int
        let expectedTopHitCount: Int
        let topHitMatchCount: Int
        let exactRankMatchCount: Int
        let topKSetMatchCount: Int
    }
}

private struct MutationMillisecondDistribution: Codable, Sendable {
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

private enum ExactPathMutationBenchmark {
    private static let segmentsPerMeeting = 200

    static func run(
        options: ExactPathMutationOptions
    ) async throws -> ExactPathMutationReport {
        guard options.isValid else {
            throw ExactPathMutationError.invalidConfiguration
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "portavoz-exact-path-mutation-\(UUID().uuidString)",
            isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let fixtureStart = ContinuousClock.now
        let fixture = MutationFixture.make(options: options)
        let fixtureMilliseconds = milliseconds(since: fixtureStart)
        let profile = SemanticEmbeddingProfile(
            modelIdentifier: "portavoz.research.synthetic-exact-path-mutation-v1",
            modelRevision: 1,
            vectorDimension: options.dimension,
            pipelineIdentifier: "deterministic-normalized-lcg-mutation-v1",
            pipelineRevision: 1,
            vectorSchemaVersion: 1)

        let controlBuildStart = ContinuousClock.now
        let store = try MeetingStore(
            databaseURL: directory.appendingPathComponent("control.sqlite"))
        let controlRecords = try await seedControl(
            store: store,
            entries: fixture.entries,
            profile: profile)
        let controlBuildMilliseconds = milliseconds(since: controlBuildStart)
        let control = AccelerateExactSemanticIndex(store: store)

        let candidateBuildStart = ContinuousClock.now
        let candidate = try SQLiteVecExactShadowRanker(
            profile: profile,
            entries: fixture.entries)
        let candidateBuildMilliseconds = milliseconds(since: candidateBuildStart)

        var samples: [ExactPathMutationReport.Engine: [MutationKey: [Double]]] = [
            .accelerateExact: [:],
            .sqliteVecExact: [:],
        ]
        var agreement = MutationAgreementAccumulator()
        try await compare(
            query: fixture.entries[options.corpusSize / 2].vector,
            expected: fixture.entries[options.corpusSize / 2].identity,
            control: control,
            candidate: candidate,
            profile: profile,
            limit: options.resultLimit,
            agreement: &agreement)

        for batchSize in ExactPathMutationOptions.canonicalBatchSizes {
            let baseEntries = Array(fixture.entries.prefix(batchSize))
            let baseRecords = Array(controlRecords.prefix(batchSize))
            for run in 0..<options.runsPerBatch {
                let added = MutationFixture.addedEntries(
                    count: batchSize,
                    dimension: options.dimension,
                    generation: run + batchSize * 10)
                let addKey = MutationKey(operation: .add, batchSize: batchSize)
                let addedMeeting: MeetingID
                if (run + batchSize).isMultiple(of: 2) {
                    let controlMeasurement = try await measure {
                        try await addControl(
                            store: store, entries: added, profile: profile)
                    }
                    addedMeeting = controlMeasurement.value
                    samples[.accelerateExact, default: [:]][addKey, default: []]
                        .append(controlMeasurement.ms)
                    let candidateMeasurement = try await measure {
                        try await candidate.apply(
                            .init(upserts: added, deletedSegmentIDs: []),
                            profile: profile)
                    }
                    samples[.sqliteVecExact, default: [:]][addKey, default: []]
                        .append(candidateMeasurement.ms)
                } else {
                    let candidateMeasurement = try await measure {
                        try await candidate.apply(
                            .init(upserts: added, deletedSegmentIDs: []),
                            profile: profile)
                    }
                    samples[.sqliteVecExact, default: [:]][addKey, default: []]
                        .append(candidateMeasurement.ms)
                    let controlMeasurement = try await measure {
                        try await addControl(
                            store: store, entries: added, profile: profile)
                    }
                    addedMeeting = controlMeasurement.value
                    samples[.accelerateExact, default: [:]][addKey, default: []]
                        .append(controlMeasurement.ms)
                }
                try await compare(
                    query: added[0].vector,
                    expected: added[0].identity,
                    control: control,
                    candidate: candidate,
                    profile: profile,
                    limit: options.resultLimit,
                    agreement: &agreement)

                let deleteKey = MutationKey(operation: .delete, batchSize: batchSize)
                let deletedIDs = added.map(\.identity.segmentID)
                if (run + batchSize).isMultiple(of: 2) {
                    samples[.accelerateExact, default: [:]][deleteKey, default: []]
                        .append(try await measure {
                            try await store.delete(addedMeeting)
                        }.ms)
                    samples[.sqliteVecExact, default: [:]][deleteKey, default: []]
                        .append(try await measure {
                            try await candidate.apply(
                                .init(upserts: [], deletedSegmentIDs: deletedIDs),
                                profile: profile)
                        }.ms)
                } else {
                    samples[.sqliteVecExact, default: [:]][deleteKey, default: []]
                        .append(try await measure {
                            try await candidate.apply(
                                .init(upserts: [], deletedSegmentIDs: deletedIDs),
                                profile: profile)
                        }.ms)
                    samples[.accelerateExact, default: [:]][deleteKey, default: []]
                        .append(try await measure {
                            try await store.delete(addedMeeting)
                        }.ms)
                }
                try await compare(
                    query: added[0].vector,
                    expected: nil,
                    control: control,
                    candidate: candidate,
                    profile: profile,
                    limit: options.resultLimit,
                    agreement: &agreement)

                let updated = zip(baseEntries, baseRecords).enumerated().map {
                    offset, pair in
                    SQLiteVecShadowEntry(
                        identity: pair.0.identity,
                        vector: MutationFixture.vector(
                            position: offset,
                            dimension: options.dimension,
                            generation: run + 1))
                }
                let updateKey = MutationKey(operation: .update, batchSize: batchSize)
                if (run + batchSize).isMultiple(of: 2) {
                    samples[.accelerateExact, default: [:]][updateKey, default: []]
                        .append(try await measure {
                            try await updateControl(
                                store: store,
                                records: baseRecords,
                                entries: updated,
                                generation: run,
                                profile: profile)
                        }.ms)
                    samples[.sqliteVecExact, default: [:]][updateKey, default: []]
                        .append(try await measure {
                            try await candidate.apply(
                                .init(upserts: updated, deletedSegmentIDs: []),
                                profile: profile)
                        }.ms)
                } else {
                    samples[.sqliteVecExact, default: [:]][updateKey, default: []]
                        .append(try await measure {
                            try await candidate.apply(
                                .init(upserts: updated, deletedSegmentIDs: []),
                                profile: profile)
                        }.ms)
                    samples[.accelerateExact, default: [:]][updateKey, default: []]
                        .append(try await measure {
                            try await updateControl(
                                store: store,
                                records: baseRecords,
                                entries: updated,
                                generation: run,
                                profile: profile)
                        }.ms)
                }
                try await compare(
                    query: updated[0].vector,
                    expected: updated[0].identity,
                    control: control,
                    candidate: candidate,
                    profile: profile,
                    limit: options.resultLimit,
                    agreement: &agreement)
            }
        }

        #if DEBUG
        let buildConfiguration = "debug"
        #else
        let buildConfiguration = "release"
        #endif
        return ExactPathMutationReport(
            schemaVersion: 1,
            fixtureVersion: "synthetic-exact-path-mutation-v1",
            measurementPolicyVersion: "alternating-mutation-engine-order-v1",
            buildConfiguration: buildConfiguration,
            host: .init(
                operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
                architecture: machineArchitecture(),
                processorCount: ProcessInfo.processInfo.processorCount,
                physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory),
            configuration: .init(
                corpusSize: options.corpusSize,
                dimension: options.dimension,
                runsPerBatch: options.runsPerBatch,
                resultLimit: options.resultLimit,
                batchSizes: ExactPathMutationOptions.canonicalBatchSizes,
                rawEmbeddingBytes: Int64(
                    options.corpusSize * options.dimension * MemoryLayout<Float>.size),
                fixturePreparationMilliseconds: fixtureMilliseconds,
                rebuildLifecycle: "control-source-publication-vs-candidate-prepared-vectors-v1",
                mutationLifecycle:
                    "control-authoritative-source-publication-vs-candidate-prepared-vectors-v1"),
            engines: [
                engineObservation(
                    engine: .accelerateExact,
                    rebuild: controlBuildMilliseconds,
                    samples: samples[.accelerateExact] ?? [:]),
                engineObservation(
                    engine: .sqliteVecExact,
                    rebuild: candidateBuildMilliseconds,
                    samples: samples[.sqliteVecExact] ?? [:]),
            ],
            agreement: agreement.report)
    }

    private static func engineObservation(
        engine: ExactPathMutationReport.Engine,
        rebuild: Double,
        samples: [MutationKey: [Double]]
    ) -> ExactPathMutationReport.EngineObservation {
        let observations = ExactPathMutationOptions.canonicalBatchSizes.flatMap { batch in
            ExactPathMutationReport.Operation.allCases.map { operation in
                let key = MutationKey(operation: operation, batchSize: batch)
                return ExactPathMutationReport.MutationObservation(
                    operation: operation,
                    batchSize: batch,
                    wallMilliseconds: .init(samples[key] ?? []))
            }
        }
        return .init(
            engine: engine,
            fullRebuildMilliseconds: rebuild,
            mutations: observations)
    }

    private static func seedControl(
        store: MeetingStore,
        entries: [SQLiteVecShadowEntry],
        profile: SemanticEmbeddingProfile
    ) async throws -> [ControlSegmentRecord] {
        var records: [ControlSegmentRecord] = []
        records.reserveCapacity(entries.count)
        for lowerBound in stride(from: 0, to: entries.count, by: segmentsPerMeeting) {
            let upperBound = min(lowerBound + segmentsPerMeeting, entries.count)
            let batch = Array(entries[lowerBound..<upperBound])
            let meeting = Meeting(
                title: "Synthetic exact-path mutation",
                startedAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(lowerBound)))
            let speaker = Speaker(meetingID: meeting.id, label: "S1")
            let segments = batch.enumerated().map { offset, entry in
                TranscriptSegment(
                    id: entry.identity.segmentID,
                    meetingID: meeting.id,
                    speakerID: speaker.id,
                    channel: .system,
                    text: "Synthetic exact-path mutation",
                    startTime: Double(offset),
                    endTime: Double(offset + 1),
                    isFinal: true)
            }
            try await store.save(meeting)
            try await store.save([speaker])
            try await store.save(segments)
            try await publish(
                store: store,
                entries: batch,
                profile: profile)
            records.append(contentsOf: segments.map {
                .init(
                    id: $0.id,
                    meetingID: $0.meetingID,
                    speakerID: $0.speakerID,
                    startTime: $0.startTime,
                    endTime: $0.endTime)
            })
        }
        return records
    }

    private static func addControl(
        store: MeetingStore,
        entries: [SQLiteVecShadowEntry],
        profile: SemanticEmbeddingProfile
    ) async throws -> MeetingID {
        let meeting = Meeting(
            title: "Synthetic exact-path mutation addition",
            startedAt: Date(timeIntervalSince1970: 1_800_000_000))
        let speaker = Speaker(meetingID: meeting.id, label: "S1")
        let segments = entries.enumerated().map { offset, entry in
            TranscriptSegment(
                id: entry.identity.segmentID,
                meetingID: meeting.id,
                speakerID: speaker.id,
                channel: .system,
                text: "Synthetic exact-path mutation addition",
                startTime: Double(offset),
                endTime: Double(offset + 1),
                isFinal: true)
        }
        try await store.save(meeting)
        try await store.save([speaker])
        try await store.save(segments)
        try await publish(store: store, entries: entries, profile: profile)
        return meeting.id
    }

    private static func updateControl(
        store: MeetingStore,
        records: [ControlSegmentRecord],
        entries: [SQLiteVecShadowEntry],
        generation: Int,
        profile: SemanticEmbeddingProfile
    ) async throws {
        let segments = zip(records, entries).map { record, entry in
            TranscriptSegment(
                id: entry.identity.segmentID,
                meetingID: record.meetingID,
                speakerID: record.speakerID,
                channel: .system,
                text: "Synthetic exact-path mutation correction \(generation)",
                startTime: record.startTime,
                endTime: record.endTime,
                isFinal: true)
        }
        try await store.save(segments)
        try await publish(store: store, entries: entries, profile: profile)
    }

    private static func publish(
        store: MeetingStore,
        entries: [SQLiteVecShadowEntry],
        profile: SemanticEmbeddingProfile
    ) async throws {
        let candidates = try await store.segmentsNeedingEmbeddings(limit: entries.count)
        guard Set(candidates.map(\.id)) == Set(entries.map(\.identity.segmentID)) else {
            throw ExactPathMutationError.fixturePublicationMismatch
        }
        let vectors = Dictionary(uniqueKeysWithValues: entries.map {
            ($0.identity.segmentID, $0.vector)
        })
        let result = try await store.storeEmbeddings(
            vectors,
            for: candidates,
            profile: profile)
        guard result.publishedSegmentIDs == Set(entries.map(\.identity.segmentID)),
              result.skippedSegmentIDs.isEmpty
        else {
            throw ExactPathMutationError.fixturePublicationMismatch
        }
    }

    private static func compare(
        query: [Float],
        expected: SemanticSearchCandidateIdentity?,
        control: AccelerateExactSemanticIndex,
        candidate: SQLiteVecExactShadowRanker,
        profile: SemanticEmbeddingProfile,
        limit: Int,
        agreement: inout MutationAgreementAccumulator
    ) async throws {
        let controlResult = try await control.search(query, profile: profile, limit: limit)
            .map {
                SemanticSearchCandidateIdentity(
                    segmentID: $0.segmentID,
                    transcriptRevision: $0.transcriptRevision)
            }
        let candidateResult = try await candidate.rankedCandidates(
            for: query,
            profile: profile,
            limit: limit)
        guard controlResult.count == limit, candidateResult.count == limit else {
            throw ExactPathMutationError.invalidResultCount
        }
        if let expected,
           controlResult.first != expected || candidateResult.first != expected {
            throw ExactPathMutationError.unexpectedTopHit
        }
        guard controlResult.first == candidateResult.first,
              Set(controlResult) == Set(candidateResult)
        else {
            throw ExactPathMutationError.rankMismatch
        }
        agreement.record(expected: expected, control: controlResult, candidate: candidateResult)
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

private struct MutationKey: Hashable {
    let operation: ExactPathMutationReport.Operation
    let batchSize: Int
}

private struct ControlSegmentRecord: Sendable {
    let id: UUID
    let meetingID: MeetingID
    let speakerID: SpeakerID?
    let startTime: TimeInterval
    let endTime: TimeInterval
}

private struct MutationFixture {
    let entries: [SQLiteVecShadowEntry]

    static func make(options: ExactPathMutationOptions) -> MutationFixture {
        MutationFixture(entries: (0..<options.corpusSize).map { position in
            SQLiteVecShadowEntry(
                identity: .init(segmentID: UUID(), transcriptRevision: 0),
                vector: vector(
                    position: position,
                    dimension: options.dimension,
                    generation: 0))
        })
    }

    static func addedEntries(
        count: Int,
        dimension: Int,
        generation: Int
    ) -> [SQLiteVecShadowEntry] {
        (0..<count).map { position in
            SQLiteVecShadowEntry(
                identity: .init(segmentID: UUID(), transcriptRevision: 0),
                vector: vector(
                    position: position + 1_000_000,
                    dimension: dimension,
                    generation: generation))
        }
    }

    static func vector(position: Int, dimension: Int, generation: Int) -> [Float] {
        var state = UInt64(truncatingIfNeeded: position + 1)
            &* 0x9E37_79B9_7F4A_7C15
            &+ UInt64(truncatingIfNeeded: generation + 1)
            &* 0xD1B5_4A32_D192_ED03
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

private struct MutationAgreementAccumulator {
    private(set) var comparisonCount = 0
    private(set) var expectedTopHitCount = 0
    private(set) var topHitMatchCount = 0
    private(set) var exactRankMatchCount = 0
    private(set) var topKSetMatchCount = 0

    mutating func record(
        expected: SemanticSearchCandidateIdentity?,
        control: [SemanticSearchCandidateIdentity],
        candidate: [SemanticSearchCandidateIdentity]
    ) {
        comparisonCount += 1
        if let expected, control.first == expected, candidate.first == expected {
            expectedTopHitCount += 1
        }
        if control.first == candidate.first { topHitMatchCount += 1 }
        if control == candidate { exactRankMatchCount += 1 }
        if Set(control) == Set(candidate) { topKSetMatchCount += 1 }
    }

    var report: ExactPathMutationReport.Agreement {
        .init(
            comparisonCount: comparisonCount,
            expectedTopHitCount: expectedTopHitCount,
            topHitMatchCount: topHitMatchCount,
            exactRankMatchCount: exactRankMatchCount,
            topKSetMatchCount: topKSetMatchCount)
    }
}

private extension ExactPathMutationReport.Operation {
    static let allCases: [Self] = [.add, .update, .delete]
}

private extension JSONEncoder {
    static var exactPathMutation: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}
