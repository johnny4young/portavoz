import Foundation
import GRDB
import PortavozCore
import XCTest

@testable import StorageKit

final class CommitmentRadarScaleBenchmarkTests: XCTestCase {
    func testEnvironmentRequiresCanonicalScalesAndBoundedRuns() throws {
        XCTAssertNil(try CommitmentRadarBenchmarkOptions.environmentOptions([:]))
        XCTAssertEqual(CommitmentRadarBenchmarkOptions.canonicalCorpusSizes, [1_000, 10_000])

        XCTAssertThrowsError(try CommitmentRadarBenchmarkOptions.environmentOptions([
            "PORTAVOZ_COMMITMENT_RADAR_BENCHMARK": "1",
            "PORTAVOZ_COMMITMENT_RADAR_RUNS": "2"
        ])) {
            XCTAssertEqual($0 as? CommitmentRadarBenchmarkError, .invalidRuns)
        }

        let options = try XCTUnwrap(
            CommitmentRadarBenchmarkOptions.environmentOptions([
                "PORTAVOZ_COMMITMENT_RADAR_BENCHMARK": "1",
                "PORTAVOZ_COMMITMENT_RADAR_RUNS": "7"
            ]))
        XCTAssertEqual(options.corpusSizes, [1_000, 10_000])
        XCTAssertEqual(options.runs, 7)
        XCTAssertEqual(options.itemLimit, 100)
        XCTAssertEqual(options.p95BudgetMilliseconds, 100)
    }

    func testSmallHarnessReportsOnlyBoundedAggregateCost() async throws {
        let report = try await CommitmentRadarBenchmark.run(options: .init(
            corpusSizes: [100],
            runs: 2,
            itemLimit: 25,
            p95BudgetMilliseconds: 1_000))

        XCTAssertEqual(report.schemaVersion, 1)
        XCTAssertEqual(report.fixtureVersion, "synthetic-confirmed-continuity-v1")
        XCTAssertEqual(report.measurementPolicyVersion, "fresh-store-warm-query-v1")
        XCTAssertEqual(report.points.count, 1)
        let point = try XCTUnwrap(report.points.first)
        XCTAssertEqual(point.corpusSize, 100)
        XCTAssertEqual(point.returnedItemCount, 25)
        XCTAssertEqual(point.totalCount, 100)
        XCTAssertEqual(point.selectCount, 4)
        XCTAssertEqual(point.timing.sampleCount, 2)
        XCTAssertGreaterThanOrEqual(point.timing.p95Milliseconds, 0)

        let data = try JSONEncoder.commitmentRadar.encode(report)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        for forbidden in [
            "commitmentID", "sourceID", "eventID", "meetingID", "title",
            "databasePath", "Synthetic commitment"
        ] {
            XCTAssertFalse(json.contains(forbidden), "payload leaked: \(forbidden)")
        }
    }

    func testCanonicalOneAndTenThousandBenchmarkFromEnvironment() async throws {
        guard let options = try CommitmentRadarBenchmarkOptions.environmentOptions(
            ProcessInfo.processInfo.environment)
        else {
            XCTAssertEqual(
                CommitmentRadarBenchmarkOptions.canonicalCorpusSizes,
                [1_000, 10_000])
            return
        }

        let report = try await CommitmentRadarBenchmark.run(options: options)
        let data = try JSONEncoder.commitmentRadar.encode(report)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        print("PORTAVOZ_COMMITMENT_RADAR_REPORT \(json)")
    }
}

private enum CommitmentRadarBenchmarkError: Error, Equatable {
    case invalidRuns
    case invalidConfiguration
    case unstableOutput
    case statementBoundChanged
    case p95BudgetExceeded
}

private struct CommitmentRadarBenchmarkOptions: Equatable, Sendable {
    static let canonicalCorpusSizes = [1_000, 10_000]

    let corpusSizes: [Int]
    let runs: Int
    let itemLimit: Int
    let p95BudgetMilliseconds: Double

    static func environmentOptions(
        _ environment: [String: String]
    ) throws -> CommitmentRadarBenchmarkOptions? {
        guard environment["PORTAVOZ_COMMITMENT_RADAR_BENCHMARK"] == "1" else {
            return nil
        }
        let runs = environment["PORTAVOZ_COMMITMENT_RADAR_RUNS"].flatMap(Int.init) ?? 5
        guard (3...20).contains(runs) else {
            throw CommitmentRadarBenchmarkError.invalidRuns
        }
        return CommitmentRadarBenchmarkOptions(
            corpusSizes: canonicalCorpusSizes,
            runs: runs,
            itemLimit: 100,
            p95BudgetMilliseconds: 100)
    }

    var isValid: Bool {
        !corpusSizes.isEmpty
            && corpusSizes.allSatisfy { $0 > 0 }
            && corpusSizes == corpusSizes.sorted()
            && Set(corpusSizes).count == corpusSizes.count
            && runs > 0
            && (1...CommitmentRadarQuery.maximumItemCount).contains(itemLimit)
            && p95BudgetMilliseconds > 0
    }
}

private struct CommitmentRadarBenchmarkReport: Codable, Sendable {
    let schemaVersion: Int
    let fixtureVersion: String
    let measurementPolicyVersion: String
    let buildConfiguration: String
    let host: Host
    let runs: Int
    let itemLimit: Int
    let p95BudgetMilliseconds: Double
    let points: [Point]

    struct Host: Codable, Sendable {
        let operatingSystem: String
        let architecture: String
        let processorCount: Int
        let physicalMemoryBytes: UInt64
    }

    struct Point: Codable, Sendable {
        let corpusSize: Int
        let returnedItemCount: Int
        let totalCount: Int
        let selectCount: Int
        let timing: CommitmentRadarMillisecondDistribution
    }
}

private struct CommitmentRadarMillisecondDistribution: Codable, Sendable {
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

private enum CommitmentRadarBenchmark {
    private static let fixtureDayStart = Date(timeIntervalSince1970: 1_801_440_000)

    static func run(
        options: CommitmentRadarBenchmarkOptions
    ) async throws -> CommitmentRadarBenchmarkReport {
        guard options.isValid else {
            throw CommitmentRadarBenchmarkError.invalidConfiguration
        }

        var points: [CommitmentRadarBenchmarkReport.Point] = []
        for corpusSize in options.corpusSizes {
            points.append(try await measurePoint(
                corpusSize: corpusSize,
                options: options))
        }

        let process = ProcessInfo.processInfo
        return CommitmentRadarBenchmarkReport(
            schemaVersion: 1,
            fixtureVersion: "synthetic-confirmed-continuity-v1",
            measurementPolicyVersion: "fresh-store-warm-query-v1",
            buildConfiguration: buildConfiguration,
            host: .init(
                operatingSystem: process.operatingSystemVersionString,
                architecture: architectureName,
                processorCount: process.processorCount,
                physicalMemoryBytes: process.physicalMemory),
            runs: options.runs,
            itemLimit: options.itemLimit,
            p95BudgetMilliseconds: options.p95BudgetMilliseconds,
            points: points)
    }

    private static func measurePoint(
        corpusSize: Int,
        options: CommitmentRadarBenchmarkOptions
    ) async throws -> CommitmentRadarBenchmarkReport.Point {
        let store = try MeetingStore.inMemory()
        try await insertFixture(count: corpusSize, into: store)
        let query = try benchmarkQuery(itemLimit: options.itemLimit)
        let warmPage = try await store.commitmentRadar(query)
        let expectedIDs = warmPage.items.map(\.id)
        guard warmPage.totalCount == corpusSize,
              warmPage.items.count == min(corpusSize, options.itemLimit)
        else { throw CommitmentRadarBenchmarkError.unstableOutput }

        var samples: [Double] = []
        for _ in 0..<options.runs {
            let start = ContinuousClock.now
            let page = try await store.commitmentRadar(query)
            samples.append(milliseconds(since: start))
            guard page.totalCount == corpusSize,
                  page.items.map(\.id) == expectedIDs
            else { throw CommitmentRadarBenchmarkError.unstableOutput }
        }

        let selectCount = try await measuredSelectCount(store: store, query: query)
        guard selectCount == 4 else {
            throw CommitmentRadarBenchmarkError.statementBoundChanged
        }
        let timing = CommitmentRadarMillisecondDistribution(samples)
        guard timing.p95Milliseconds <= options.p95BudgetMilliseconds else {
            throw CommitmentRadarBenchmarkError.p95BudgetExceeded
        }
        return .init(
            corpusSize: corpusSize,
            returnedItemCount: warmPage.items.count,
            totalCount: warmPage.totalCount,
            selectCount: selectCount,
            timing: timing)
    }

    private static func benchmarkQuery(
        itemLimit: Int
    ) throws -> CommitmentRadarQuery {
        return try CommitmentRadarQuery(
            dayStart: fixtureDayStart,
            dueSoonEnd: fixtureDayStart.addingTimeInterval(7 * 86_400),
            newSince: fixtureDayStart.addingTimeInterval(-7 * 86_400),
            itemLimit: itemLimit,
            sourceLimitPerItem: 3,
            historyLimitPerItem: 8)
    }

    private static func insertFixture(
        count: Int,
        into store: MeetingStore
    ) async throws {
        let person = Person(
            id: PersonID(rawValue: benchmarkUUID(prefix: "D0", index: 0)),
            preferredName: "Synthetic owner")
        try await store.database.write { database in
            try PersonRecord(
                person,
                createdAt: fixtureDayStart,
                updatedAt: fixtureDayStart)
                .insert(database)
            for index in 0..<count {
                let timestamp = fixtureDayStart.addingTimeInterval(Double(index))
                let commitment = Commitment(
                    id: commitmentID(index),
                    title: "Synthetic commitment \(index)",
                    assignee: .person(person.id),
                    dueAt: dueDate(index: index),
                    createdAt: timestamp)
                let source = CommitmentSource(
                    id: sourceID(index),
                    commitmentID: commitment.id,
                    kind: .manual,
                    meetingID: nil,
                    firstSeenAt: timestamp)
                let event = CommitmentEvent(
                    id: eventID(index),
                    commitmentID: commitment.id,
                    kind: .confirm,
                    assignee: .person(person.id),
                    dueAt: commitment.dueAt,
                    occurredAt: timestamp)
                try CommitmentRecord(commitment).insert(database)
                try CommitmentSourceRecord(source).insert(database)
                try CommitmentEventRecord(event).insert(database)
            }
        }
    }

    private static func dueDate(index: Int) -> Date? {
        switch index % 3 {
        case 0: fixtureDayStart.addingTimeInterval(-86_400)
        case 1: fixtureDayStart.addingTimeInterval(3 * 86_400)
        default: nil
        }
    }

    private static func commitmentID(_ index: Int) -> CommitmentID {
        CommitmentID(rawValue: benchmarkUUID(prefix: "C0", index: index))
    }

    private static func sourceID(_ index: Int) -> CommitmentSourceID {
        CommitmentSourceID(rawValue: benchmarkUUID(prefix: "C1", index: index))
    }

    private static func eventID(_ index: Int) -> CommitmentEventID {
        CommitmentEventID(rawValue: benchmarkUUID(prefix: "C2", index: index))
    }

    private static func benchmarkUUID(prefix: String, index: Int) -> UUID {
        UUID(uuidString: String(
            format: "%@000000-0000-4000-8000-%012d",
            prefix,
            index + 1))!
    }

    private static func measuredSelectCount(
        store: MeetingStore,
        query: CommitmentRadarQuery
    ) async throws -> Int {
        let counter = CommitmentRadarBenchmarkStatementCounter()
        try await store.database.write { database in
            database.trace(options: .statement) { counter.record($0) }
        }
        _ = try await store.commitmentRadar(query)
        try await store.database.write { database in
            database.trace(options: [])
        }
        return counter.readStatementCount
    }

    private static func milliseconds(since start: ContinuousClock.Instant) -> Double {
        let components = start.duration(to: .now).components
        return Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1_000_000_000_000_000
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
}

private final class CommitmentRadarBenchmarkStatementCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var statements = 0

    var readStatementCount: Int {
        lock.withLock { statements }
    }

    func record(_ event: Database.TraceEvent) {
        guard case .statement(let statement) = event else { return }
        let sql = statement.sql.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard sql.hasPrefix("SELECT") || sql.hasPrefix("WITH") else { return }
        lock.withLock { statements += 1 }
    }
}

private extension JSONEncoder {
    static var commitmentRadar: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}
