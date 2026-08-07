import ApplicationKit
import Foundation
import PortavozCore
import XCTest

final class TranscriptCorrectionScaleBenchmarkTests: XCTestCase {
    func testEnvironmentRequiresCanonicalScaleAndBoundedRuns() throws {
        XCTAssertNil(try CorrectionCompositionBenchmarkOptions.environmentOptions([:]))
        XCTAssertEqual(CorrectionCompositionBenchmarkOptions.canonicalSegmentCount, 20_000)

        XCTAssertThrowsError(try CorrectionCompositionBenchmarkOptions.environmentOptions([
            "PORTAVOZ_CORRECTION_COMPOSITION_BENCHMARK": "1",
            "PORTAVOZ_CORRECTION_COMPOSITION_RUNS": "2",
        ])) {
            XCTAssertEqual(
                $0 as? CorrectionCompositionBenchmarkError,
                .invalidRuns)
        }
        let options = try XCTUnwrap(
            CorrectionCompositionBenchmarkOptions.environmentOptions([
                "PORTAVOZ_CORRECTION_COMPOSITION_BENCHMARK": "1",
                "PORTAVOZ_CORRECTION_COMPOSITION_RUNS": "7",
            ]))
        XCTAssertEqual(options.segmentCount, 20_000)
        XCTAssertEqual(options.correctionInterval, 50)
        XCTAssertEqual(options.runs, 7)
        XCTAssertEqual(options.p95BudgetMilliseconds, 250)
    }

    /// A heavily corrected meeting: 4 000 corrections over 8 000 segments.
    ///
    /// Lane resolution used to re-index the whole correction history once per
    /// active correction, twice per compose — quadratic in the correction
    /// count. This fixture measured 12 749 ms p95 that way, against 185 ms
    /// once the history is indexed once. The test is the guard against that
    /// cost coming back.
    func testDenseCorrectionHistoryStaysWithinTheCompositionBudget() throws {
        let report = try CorrectionCompositionBenchmark.run(options: .init(
            segmentCount: 8_000,
            correctionInterval: 2,
            runs: 5,
            p95BudgetMilliseconds: 250))

        XCTAssertEqual(report.configuration.correctionCount, 4_000)
        XCTAssertLessThan(
            report.timing.p95Milliseconds,
            250,
            "a dense correction history must stay interactive")
    }

    func testSmallHarnessReportsOnlyAggregateCompositionCost() throws {
        let report = try CorrectionCompositionBenchmark.run(options: .init(
            segmentCount: 200,
            correctionInterval: 10,
            runs: 2,
            p95BudgetMilliseconds: 250))

        XCTAssertEqual(report.schemaVersion, 1)
        XCTAssertEqual(report.fixtureVersion, "synthetic-correction-composition-v1")
        XCTAssertEqual(report.configuration.segmentCount, 200)
        XCTAssertEqual(report.configuration.correctionCount, 20)
        XCTAssertEqual(report.configuration.p95BudgetMilliseconds, 250)
        XCTAssertEqual(report.timing.sampleCount, 2)
        XCTAssertGreaterThan(report.configuration.composedRowCount, 0)
        XCTAssertGreaterThanOrEqual(report.timing.p95Milliseconds, 0)

        let data = try JSONEncoder.correctionComposition.encode(report)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        for forbidden in [
            "meetingID", "segmentID", "speakerID", "transcript",
            "Corrected", "Source row", "databasePath",
        ] {
            XCTAssertFalse(json.contains(forbidden), "payload leaked: \(forbidden)")
        }
    }

    func testCanonicalTwentyThousandSegmentBenchmarkFromEnvironment() throws {
        guard let options = try CorrectionCompositionBenchmarkOptions.environmentOptions(
            ProcessInfo.processInfo.environment)
        else {
            XCTAssertEqual(
                CorrectionCompositionBenchmarkOptions.canonicalSegmentCount,
                20_000)
            return
        }

        let report = try CorrectionCompositionBenchmark.run(options: options)
        let data = try JSONEncoder.correctionComposition.encode(report)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        print("PORTAVOZ_CORRECTION_COMPOSITION_REPORT \(json)")
    }
}

private enum CorrectionCompositionBenchmarkError: Error, Equatable {
    case invalidRuns
    case invalidConfiguration
    case unstableOutput
    case p95BudgetExceeded
}

private struct CorrectionCompositionBenchmarkOptions: Equatable, Sendable {
    static let canonicalSegmentCount = 20_000

    let segmentCount: Int
    let correctionInterval: Int
    let runs: Int
    let p95BudgetMilliseconds: Double

    static func environmentOptions(
        _ environment: [String: String]
    ) throws -> CorrectionCompositionBenchmarkOptions? {
        guard environment["PORTAVOZ_CORRECTION_COMPOSITION_BENCHMARK"] == "1" else {
            return nil
        }
        let runs = environment["PORTAVOZ_CORRECTION_COMPOSITION_RUNS"].flatMap(Int.init) ?? 5
        guard (3...20).contains(runs) else {
            throw CorrectionCompositionBenchmarkError.invalidRuns
        }
        return CorrectionCompositionBenchmarkOptions(
            segmentCount: canonicalSegmentCount,
            correctionInterval: 50,
            runs: runs,
            p95BudgetMilliseconds: 250)
    }

    var isValid: Bool {
        segmentCount > 0
            && correctionInterval > 0
            && correctionInterval <= segmentCount
            && runs > 0
            && p95BudgetMilliseconds > 0
    }
}

private struct CorrectionCompositionBenchmarkReport: Codable, Sendable {
    let schemaVersion: Int
    let fixtureVersion: String
    let measurementPolicyVersion: String
    let buildConfiguration: String
    let host: Host
    let configuration: Configuration
    let timing: MillisecondDistribution

    struct Host: Codable, Sendable {
        let operatingSystem: String
        let architecture: String
        let processorCount: Int
        let physicalMemoryBytes: UInt64
    }

    struct Configuration: Codable, Sendable {
        let segmentCount: Int
        let correctionCount: Int
        let correctionInterval: Int
        let runs: Int
        let composedRowCount: Int
        let p95BudgetMilliseconds: Double
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

private enum CorrectionCompositionBenchmark {
    static func run(
        options: CorrectionCompositionBenchmarkOptions
    ) throws -> CorrectionCompositionBenchmarkReport {
        guard options.isValid else {
            throw CorrectionCompositionBenchmarkError.invalidConfiguration
        }
        let fixture = Fixture.make(options: options)
        let inputs = (0..<options.runs).map { run in
            var generator = BenchmarkGenerator(seed: UInt64(run + 1))
            return (
                fixture.segments.shuffled(using: &generator),
                fixture.corrections.shuffled(using: &generator))
        }
        let composer = ComposeTranscript()
        var samples: [Double] = []
        var expectedRowCount: Int?
        for input in inputs {
            let start = ContinuousClock.now
            let result = try composer.execute(
                baseTranscriptRevision: Fixture.transcriptRevision,
                baseMaterial: .refined,
                segments: input.0,
                corrections: input.1)
            samples.append(milliseconds(since: start))
            let rowCount = result.composed.rows.count
            guard expectedRowCount.map({ $0 == rowCount }) ?? true else {
                throw CorrectionCompositionBenchmarkError.unstableOutput
            }
            expectedRowCount = rowCount
        }

        let timing = MillisecondDistribution(samples)
        guard timing.p95Milliseconds <= options.p95BudgetMilliseconds else {
            throw CorrectionCompositionBenchmarkError.p95BudgetExceeded
        }
        let process = ProcessInfo.processInfo
        return CorrectionCompositionBenchmarkReport(
            schemaVersion: 1,
            fixtureVersion: "synthetic-correction-composition-v1",
            measurementPolicyVersion: "prebuilt-input-permutation-v1",
            buildConfiguration: buildConfiguration,
            host: .init(
                operatingSystem: process.operatingSystemVersionString,
                architecture: architectureName,
                processorCount: process.processorCount,
                physicalMemoryBytes: process.physicalMemory),
            configuration: .init(
                segmentCount: options.segmentCount,
                correctionCount: fixture.corrections.count,
                correctionInterval: options.correctionInterval,
                runs: options.runs,
                composedRowCount: expectedRowCount ?? 0,
                p95BudgetMilliseconds: options.p95BudgetMilliseconds),
            timing: timing)
    }

    private static var architectureName: String {
#if arch(arm64)
        "arm64"
#elseif arch(x86_64)
        "x86_64"
#else
        "unknown"
#endif
    }

    private static var buildConfiguration: String {
#if DEBUG
        "debug"
#else
        "release"
#endif
    }

    private static func milliseconds(since start: ContinuousClock.Instant) -> Double {
        let components = start.duration(to: .now).components
        return Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1_000_000_000_000_000
    }
}

private extension CorrectionCompositionBenchmark {
    struct Fixture {
        static let transcriptRevision = 4

        let segments: [TranscriptSegment]
        let corrections: [TranscriptCorrectionEvent]

        static func make(options: CorrectionCompositionBenchmarkOptions) -> Fixture {
            let meetingID = MeetingID(rawValue: uuid(900_001))
            let firstSpeaker = SpeakerID(rawValue: uuid(900_002))
            let secondSpeaker = SpeakerID(rawValue: uuid(900_003))
            let sourceDeviceID = uuid(900_004)
            let segments = (0..<options.segmentCount).map { index in
                TranscriptSegment(
                    id: uuid(index + 1),
                    meetingID: meetingID,
                    speakerID: index.isMultiple(of: 2) ? firstSpeaker : secondSpeaker,
                    channel: index.isMultiple(of: 2) ? .microphone : .system,
                    text: "Source row \(index)",
                    language: index.isMultiple(of: 2) ? "es" : "en",
                    startTime: Double(index) * 0.75,
                    endTime: Double(index) * 0.75 + 0.5,
                    confidence: 0.9,
                    isFinal: true)
            }
            let corrections = stride(
                from: 0,
                to: options.segmentCount,
                by: options.correctionInterval
            ).enumerated().map { correctionIndex, segmentIndex in
                let kind: TranscriptCorrectionKind = switch correctionIndex % 3 {
                case 0:
                    .replaceText(
                        text: "Corrected row \(segmentIndex)",
                        language: segmentIndex.isMultiple(of: 2) ? "es" : "en")
                case 1:
                    .changeSpeaker(firstSpeaker)
                default:
                    .suppress
                }
                return TranscriptCorrectionEvent(
                    id: uuid(100_000 + correctionIndex),
                    meetingID: meetingID,
                    baseTranscriptRevision: transcriptRevision,
                    targetSegmentIDs: [segments[segmentIndex].id],
                    kind: kind,
                    sourceDeviceID: sourceDeviceID,
                    createdAt: Date(timeIntervalSince1970: 1_800_000_000 + Double(correctionIndex)))
            }
            return Fixture(segments: segments, corrections: corrections)
        }

        private static func uuid(_ value: Int) -> UUID {
            UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", value))!
        }
    }
}

private struct BenchmarkGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state
    }
}

private extension JSONEncoder {
    static var correctionComposition: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}
