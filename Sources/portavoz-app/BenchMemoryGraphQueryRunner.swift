import ApplicationKit
import Darwin
import Foundation
import PortavozCore
import StorageKit

struct BenchMemoryGraphQueryConfiguration: Equatable {
    let outputURL: URL
    let run: Int
    let iterationsPerJob: Int

    static func requested(
        arguments: [String]
    ) throws -> BenchMemoryGraphQueryConfiguration? {
        guard arguments.contains("--bench-graph-queries") else { return nil }
        let outputPath = try optionValue(
            "--bench-graph-output",
            arguments: arguments,
            error: .missingOutput)
        guard let outputPath else { throw BenchMemoryGraphQueryError.missingOutput }
        let run = try integer(
            "--bench-graph-run",
            arguments: arguments,
            defaultValue: nil,
            allowed: 1...100,
            error: .invalidRun)
        let iterations = try integer(
            "--bench-graph-iterations",
            arguments: arguments,
            defaultValue: 31,
            allowed: 5...1_000,
            error: .invalidIterations)
        return BenchMemoryGraphQueryConfiguration(
            outputURL: URL(
                fileURLWithPath: outputPath)
                .standardizedFileURL,
            run: run,
            iterationsPerJob: iterations)
    }

    private static func integer(
        _ option: String,
        arguments: [String],
        defaultValue: Int?,
        allowed: ClosedRange<Int>,
        error: BenchMemoryGraphQueryError
    ) throws -> Int {
        guard let rawValue = try optionValue(
            option,
            arguments: arguments,
            error: error)
        else {
            guard let defaultValue else { throw error }
            return defaultValue
        }
        guard let value = Int(rawValue),
              allowed.contains(value)
        else { throw error }
        return value
    }

    private static func optionValue(
        _ option: String,
        arguments: [String],
        error: BenchMemoryGraphQueryError
    ) throws -> String? {
        let matches = arguments.indices.filter { arguments[$0] == option }
        guard matches.count <= 1 else { throw error }
        guard let index = matches.first else { return nil }
        guard arguments.indices.contains(index + 1) else { throw error }
        let value = arguments[index + 1]
        guard !value.isEmpty, !value.hasPrefix("-") else { throw error }
        return value
    }
}

enum BenchMemoryGraphQueryError: Error, Equatable, LocalizedError {
    case factUnavailable(MeetingMemoryGraphQueryJob)
    case hostChanged
    case hostMetadataUnavailable
    case invalidFixture
    case invalidIterations
    case invalidRun
    case missingOutput
    case requiresDisposableStore
    case requiresPublicFixture
    case timedOut

    var errorDescription: String? {
        switch self {
        case .factUnavailable(let job):
            "Graph benchmark fixture has no fact for \(job.rawValue)"
        case .hostChanged:
            "Graph benchmark host readiness changed during measurement"
        case .hostMetadataUnavailable:
            "Graph benchmark host metadata is unavailable"
        case .invalidFixture:
            "Graph benchmark fixture is invalid"
        case .invalidIterations:
            "Graph benchmark iterations must be between 5 and 1000"
        case .invalidRun:
            "Graph benchmark run must be between 1 and 100"
        case .missingOutput:
            "Graph benchmark output path is required"
        case .requiresDisposableStore:
            "Graph benchmark requires a disposable meeting store"
        case .requiresPublicFixture:
            "Graph benchmark requires the complete public synthetic fixture"
        case .timedOut:
            "Graph benchmark exceeded its six-minute process deadline"
        }
    }
}

private struct BenchMemoryGraphQueries: Sendable {
    let person: PersonCommitmentsQuery
    let commitmentBlockers: CommitmentBlockerQuery
    let firstDiscussion: TopicFirstDiscussionQuery
    let decisionConflicts: DecisionConflictsQuery
    let changeSince: ChangeSinceQuery
    let decisionHistory: DecisionHistoryQuery
}

extension BenchMode {
    /// Runs all six released exact graph reads through the production telemetry
    /// adapter over the disposable public fixture. The runner never opens the
    /// real library and writes only one content-free, non-replacing receipt.
    @MainActor
    static func runMemoryGraphQueryBenchIfRequested(services: AppServices) {
        let arguments = ProcessInfo.processInfo.arguments
        let configuration: BenchMemoryGraphQueryConfiguration?
        do {
            configuration = try BenchMemoryGraphQueryConfiguration.requested(
                arguments: arguments)
        } catch {
            emitGraphBenchmarkFailure(error)
        }
        guard let configuration else { return }
        guard services.usesTemporaryMeetingStore else {
            emitGraphBenchmarkFailure(
                BenchMemoryGraphQueryError.requiresDisposableStore)
        }
        let requiredFixtureFlags = [
            "-seed-demo",
            "-seed-ask-memory",
            "-seed-ask-topic-memory"
        ]
        guard requiredFixtureFlags.allSatisfy(arguments.contains) else {
            emitGraphBenchmarkFailure(
                BenchMemoryGraphQueryError.requiresPublicFixture)
        }

        setbuf(stdout, nil)
        Task { @MainActor in
            await executeGraphBenchmark(
                configuration: configuration,
                services: services)
        }
    }

    @MainActor
    private static func executeGraphBenchmark(
        configuration: BenchMemoryGraphQueryConfiguration,
        services: AppServices
    ) async {
        let deadline = Task.detached {
            try await Task.sleep(for: .seconds(360))
            emitGraphBenchmarkFailure(BenchMemoryGraphQueryError.timedOut)
        }
        defer { deadline.cancel() }
        do {
            try await ResourceProbeHostReadiness.waitUntilNominal()
            let initialUsage = try ResourceProbeUsage.current()
            guard initialUsage.thermalState == .nominal,
                  initialUsage.powerSource == .ac,
                  !initialUsage.lowPowerModeEnabled
            else { throw BenchMemoryGraphQueryError.hostChanged }

            await services.seedDemoIfRequested(
                reconcileSearchAfterSeed: false)
            let queries = try await graphBenchmarkQueries(
                store: services.store)
            try await executeGraphBenchmarkRound(
                queries,
                store: services.store,
                telemetry: .disabled)

            let probe = try MeetingMemoryGraphQueryRunProbe(
                run: configuration.run,
                iterationsPerJob: configuration.iterationsPerJob)
            try await measureGraphQueries(
                queries,
                store: services.store,
                iterations: configuration.iterationsPerJob,
                probe: probe)

            let finalUsage = try ResourceProbeUsage.current()
            guard finalUsage.thermalState == .nominal,
                  finalUsage.powerSource == .ac,
                  !finalUsage.lowPowerModeEnabled
            else { throw BenchMemoryGraphQueryError.hostChanged }
            try probe.writeReceipt(
                to: configuration.outputURL,
                host: try graphBenchmarkHost(usage: finalUsage),
                fixtureGeneration: "public-synthetic-graph-product-v1")
            print("graph-query-benchmark: receipt written")
            exit(0)
        } catch {
            emitGraphBenchmarkFailure(error)
        }
    }

    private static func measureGraphQueries(
        _ queries: BenchMemoryGraphQueries,
        store: MeetingStore,
        iterations: Int,
        probe: MeetingMemoryGraphQueryRunProbe
    ) async throws {
        let observer = AppMeetingMemoryGraphQueryTelemetry.shared.addObserver(
            probe.receive)
        defer {
            AppMeetingMemoryGraphQueryTelemetry.shared.removeObserver(observer)
        }
        for _ in 0..<iterations {
            try await executeGraphBenchmarkRound(
                queries,
                store: store,
                telemetry: AppMeetingMemoryGraphQueryTelemetry.shared.telemetry)
        }
    }

    @MainActor
    private static func graphBenchmarkQueries(
        store: MeetingStore
    ) async throws -> BenchMemoryGraphQueries {
        let entities = LoadAutomationEntities(catalog: store)
        let people = try await entities.people(AutomationEntityLookup(
            matching: "Ana",
            limit: 2))
        let commitments = try await entities.commitments(
            AutomationEntityLookup(
                matching: "Prepare the rollout",
                limit: 2))
        let meetings = try await entities.meetings(AutomationEntityLookup(
            matching: "Planning baseline",
            limit: 2))
        let topics = try await LoadConfirmedTopicCatalog(catalog: store)
            .execute(ConfirmedTopicCatalogLookup(
                matching: "model rollout",
                limit: 2))
        guard people.count == 1,
              commitments.count == 1,
              meetings.count == 1,
              topics.count == 1,
              let person = people.first,
              let commitment = commitments.first,
              let meeting = meetings.first,
              let topic = topics.first
        else { throw BenchMemoryGraphQueryError.hostMetadataUnavailable }

        return BenchMemoryGraphQueries(
            person: PersonCommitmentsQuery(personID: person.id),
            commitmentBlockers: CommitmentBlockerQuery(
                commitmentID: commitment.id),
            firstDiscussion: TopicFirstDiscussionQuery(topicID: topic.id),
            decisionConflicts: DecisionConflictsQuery(topicID: topic.id),
            changeSince: ChangeSinceQuery(
                topicID: topic.id,
                sinceMeetingID: meeting.id),
            decisionHistory: DecisionHistoryQuery(topicID: topic.id))
    }

    private static func executeGraphBenchmarkRound(
        _ queries: BenchMemoryGraphQueries,
        store: MeetingStore,
        telemetry: MeetingMemoryGraphQueryTelemetry
    ) async throws {
        try requireGraphFacts(
            await LoadCommitmentBlockers(
                repository: store,
                telemetry: telemetry)
                .execute(queries.commitmentBlockers),
            job: .commitmentBlockers)
        try requireGraphFacts(
            await LoadTopicFirstDiscussion(
                repository: store,
                telemetry: telemetry)
                .execute(queries.firstDiscussion),
            job: .topicFirstDiscussion)
        try requireGraphFacts(
            await LoadPersonCommitments(
                repository: store,
                telemetry: telemetry)
                .execute(queries.person),
            job: .personCommitments)
        try requireGraphFacts(
            await LoadDecisionConflicts(
                repository: store,
                telemetry: telemetry)
                .execute(queries.decisionConflicts),
            job: .decisionConflicts)
        try requireGraphFacts(
            await LoadChangeSince(
                repository: store,
                telemetry: telemetry)
                .execute(queries.changeSince),
            job: .changeSince)
        try requireGraphFacts(
            await LoadDecisionHistory(
                repository: store,
                telemetry: telemetry)
                .execute(queries.decisionHistory),
            job: .decisionHistory)
    }

    private static func requireGraphFacts(
        _ result: MeetingMemoryGraphQueryResult,
        job: MeetingMemoryGraphQueryJob
    ) throws {
        guard case .facts(let page) = result,
              !page.facts.isEmpty
        else { throw BenchMemoryGraphQueryError.factUnavailable(job) }
    }

    private static func graphBenchmarkHost(
        usage: ResourceProbeUsage
    ) throws -> MeetingMemoryGraphQueryBenchmarkHost {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let hardwareModel = try sysctlString("hw.model")
        let operatingSystemBuild = try sysctlString("kern.osversion")
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "unsupported"
        #endif
        return MeetingMemoryGraphQueryBenchmarkHost(
            architecture: architecture,
            hardwareModel: hardwareModel,
            operatingSystem:
                "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
            operatingSystemBuild: operatingSystemBuild,
            physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory,
            powerSource: usage.powerSource.rawValue,
            thermalState: usage.thermalState.rawValue,
            lowPowerModeEnabled: usage.lowPowerModeEnabled)
    }

    private static func sysctlString(_ name: String) throws -> String {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0,
              size > 1,
              size <= 4_096
        else { throw BenchMemoryGraphQueryError.hostMetadataUnavailable }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &bytes, &size, nil, 0) == 0 else {
            throw BenchMemoryGraphQueryError.hostMetadataUnavailable
        }
        let utf8 = bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        guard let value = String(bytes: utf8, encoding: .utf8),
              !value.isEmpty
        else {
            throw BenchMemoryGraphQueryError.hostMetadataUnavailable
        }
        return value
    }

    private static func emitGraphBenchmarkFailure(_ error: Error) -> Never {
        print("graph-query-benchmark: FAILED: \(error.localizedDescription)")
        exit(1)
    }
}
