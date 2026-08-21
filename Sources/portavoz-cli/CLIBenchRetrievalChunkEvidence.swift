import ApplicationKit
import Darwin
import Foundation
import PortavozCore

enum BenchRetrievalChunkEvidenceCommand {
    static func run(_ arguments: [String]) async {
        do {
            let options = try RetrievalChunkEvidenceOptions(arguments: arguments)
            let fixture = try AskQualityFixture.load(from: options.fixture)
            let fixtureData = try Data(
                contentsOf: options.fixture,
                options: .mappedIfSafe)
            guard ContentDigest.sha256(fixtureData) == options.fixtureSHA256 else {
                throw RetrievalChunkEvidenceError.fixtureDigestMismatch
            }
            let observation = try await RetrievalChunkEvidenceBenchmark.run(
                fixture: fixture,
                options: options)
            do {
                try CLIPrivateJSONWriter.write(observation, to: options.output)
            } catch CLIPrivateJSONWriterError.outputAlreadyExists {
                throw RetrievalChunkEvidenceError.outputAlreadyExists
            } catch CLIPrivateJSONWriterError.publicationFailed {
                throw RetrievalChunkEvidenceError.outputPublicationFailed
            }
            print("Retrieval chunk evidence: \(options.output.path)")
        } catch {
            FileHandle.standardError.write(Data(
                "bench-retrieval-chunks error: \(error.localizedDescription)\n".utf8))
            Foundation.exit(64)
        }
    }
}

struct RetrievalChunkEvidenceOptions: Equatable, Sendable {
    let fixture: URL
    let output: URL
    let build: String
    let commit: String
    let fixtureSHA256: String
    let toolchainSHA256: String
    let hostProfile: String
    let role: RetrievalChunkEvidenceRole

    init(arguments: [String]) throws {
        let values = try Self.parse(arguments)
        fixture = try Self.url("--fixture", values: values)
        output = try Self.url("--output", values: values)
        guard fixture != output else {
            throw RetrievalChunkEvidenceError.outputMatchesFixture
        }
        build = try Self.safeIdentifier("--build", values: values)
        commit = try Self.digest("--commit", length: 40, values: values)
        fixtureSHA256 = try Self.digest(
            "--fixture-sha256",
            length: 64,
            values: values)
        toolchainSHA256 = try Self.digest(
            "--toolchain-sha256",
            length: 64,
            values: values)
        hostProfile = try Self.safeIdentifier("--host-profile", values: values)
        guard let retrievalUnit = values["--retrieval-unit"] else {
            throw RetrievalChunkEvidenceError.missingOption("--retrieval-unit")
        }
        role = try RetrievalChunkEvidenceRole(argument: retrievalUnit)
    }

    private static func parse(_ arguments: [String]) throws -> [String: String] {
        let allowed = Set([
            "--fixture", "--output", "--build", "--commit",
            "--fixture-sha256", "--toolchain-sha256", "--host-profile",
            "--retrieval-unit"
        ])
        var values: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            let option = arguments[index]
            guard allowed.contains(option) else {
                throw RetrievalChunkEvidenceError.unknownOption(option)
            }
            guard values[option] == nil else {
                throw RetrievalChunkEvidenceError.duplicateOption(option)
            }
            index += 1
            guard arguments.indices.contains(index) else {
                throw RetrievalChunkEvidenceError.missingOptionValue(option)
            }
            values[option] = arguments[index]
            index += 1
        }
        return values
    }

    private static func url(
        _ option: String,
        values: [String: String]
    ) throws -> URL {
        guard let value = values[option], !value.isEmpty else {
            throw RetrievalChunkEvidenceError.missingOption(option)
        }
        return URL(fileURLWithPath: value).standardizedFileURL
    }

    private static func safeIdentifier(
        _ option: String,
        values: [String: String]
    ) throws -> String {
        guard let value = values[option],
              (1...80).contains(value.utf8.count),
              value.utf8.allSatisfy({ byte in
                  (48...57).contains(byte)
                      || (65...90).contains(byte)
                      || (97...122).contains(byte)
                      || [43, 45, 46, 95].contains(byte)
              })
        else { throw RetrievalChunkEvidenceError.invalidIdentity(option) }
        return value
    }

    private static func digest(
        _ option: String,
        length: Int,
        values: [String: String]
    ) throws -> String {
        guard let value = values[option],
              value.utf8.count == length,
              value.utf8.allSatisfy({
                  (48...57).contains($0) || (97...102).contains($0)
              })
        else { throw RetrievalChunkEvidenceError.invalidIdentity(option) }
        return value
    }
}

enum RetrievalChunkEvidenceError: Error, Equatable, LocalizedError {
    case unknownOption(String)
    case duplicateOption(String)
    case missingOptionValue(String)
    case missingOption(String)
    case invalidIdentity(String)
    case invalidRetrievalUnit(String)
    case outputMatchesFixture
    case fixtureDigestMismatch
    case outputAlreadyExists
    case outputPublicationFailed
    case invalidCorpus
    case inconsistentAdapter
    case processUsageUnavailable
    case semanticEmbeddingUnavailable

    var errorDescription: String? {
        switch self {
        case .unknownOption(let option):
            "unknown option: \(option)"
        case .duplicateOption(let option):
            "option may appear only once: \(option)"
        case .missingOptionValue(let option):
            "missing value for option: \(option)"
        case .missingOption(let option):
            "missing required option: \(option)"
        case .invalidIdentity(let option):
            "invalid bounded evidence identity: \(option)"
        case .invalidRetrievalUnit(let unit):
            "invalid retrieval unit: \(unit)"
        case .outputMatchesFixture:
            "output must not replace the fixture"
        case .fixtureDigestMismatch:
            "fixture does not match its declared SHA-256"
        case .outputAlreadyExists:
            "output already exists"
        case .outputPublicationFailed:
            "output publication failed"
        case .invalidCorpus:
            "fixture cannot form the bounded correction corpus"
        case .inconsistentAdapter:
            "candidate adapter changed during one observation"
        case .processUsageUnavailable:
            "process CPU or physical-footprint counters are unavailable"
        case .semanticEmbeddingUnavailable:
            "semantic-boundary embedding is unavailable"
        }
    }
}

struct RetrievalChunkEvidenceObservation: Encodable, Sendable {
    let schemaVersion = 1
    let kind = "retrieval-chunk-resource-correction-observation"
    let authority = "research-resource-correction-only"
    let contentPolicy = "content-free"
    let lifecycle = "candidate-construction-and-one-meeting-rebuild-only"
    let assetDownloadPolicy = "never"
    let productComposition = "unchanged"
    let candidateSelection = "not-evaluated"
    let performanceDecision = "not-evaluated"
    let subject: Subject
    let host: Host
    let corpus: Corpus
    let construction: Construction
    let corrections: [Correction]

    struct Subject: Encodable, Sendable {
        let build: String
        let sourceCommit: String
        let fixtureGeneration: String
        let fixtureSHA256: String
        let toolchainSHA256: String
        let hostProfile: String
        let retrievalUnit: String
        let adapter: String
    }

    struct Host: Encodable, Sendable {
        let operatingSystem: String
        let architecture: String
        let processorCount: Int
        let physicalMemoryBytes: UInt64
        let evidenceScope = "single-development-host"
    }

    struct Corpus: Encodable, Sendable {
        let contentSource: String
        let userLibraryAccess = "none"
        let meetingCount: Int
        let sourceSegmentCount: Int
    }

    struct Construction: Encodable, Sendable {
        let resultingUnitCount: Int
        let sourceReferenceCount: Int
        let turnCount: Int
        let diagnostics: Diagnostics?
        let resources: Resources
    }

    struct Correction: Encodable, Sendable {
        let scenario: String
        let inputSegmentCount: Int
        let resultingUnitCount: Int
        let sourceReferenceCount: Int
        let turnCount: Int
        let retainedUnitCount: Int
        let candidateEmbeddingUpsertCount: Int
        let removedUnitCount: Int
        let diagnostics: Diagnostics?
        let resources: Resources
    }

    struct Diagnostics: Encodable, Equatable, Sendable {
        private(set) var turnCount: Int
        private(set) var vectorizedTurnCount: Int
        private(set) var joinedBoundaryCount: Int
        private(set) var languageTransitionBoundaryCount: Int
        private(set) var unavailableLanguageBoundaryCount: Int
        private(set) var resourceBoundaryCount: Int
        private(set) var similarityBoundaryCount: Int

        init(_ value: RetrievalSemanticBoundaryDiagnostics) {
            turnCount = value.turnCount
            vectorizedTurnCount = value.vectorizedTurnCount
            joinedBoundaryCount = value.joinedBoundaryCount
            languageTransitionBoundaryCount = value.languageTransitionBoundaryCount
            unavailableLanguageBoundaryCount = value.unavailableLanguageBoundaryCount
            resourceBoundaryCount = value.resourceBoundaryCount
            similarityBoundaryCount = value.similarityBoundaryCount
        }

        static func sum(
            _ values: [RetrievalSemanticBoundaryDiagnostics]
        ) -> Self? {
            guard !values.isEmpty else { return nil }
            var result = Self(
                turnCount: 0,
                vectorizedTurnCount: 0,
                joinedBoundaryCount: 0,
                languageTransitionBoundaryCount: 0,
                unavailableLanguageBoundaryCount: 0,
                resourceBoundaryCount: 0,
                similarityBoundaryCount: 0)
            for value in values {
                result.turnCount += value.turnCount
                result.vectorizedTurnCount += value.vectorizedTurnCount
                result.joinedBoundaryCount += value.joinedBoundaryCount
                result.languageTransitionBoundaryCount +=
                    value.languageTransitionBoundaryCount
                result.unavailableLanguageBoundaryCount +=
                    value.unavailableLanguageBoundaryCount
                result.resourceBoundaryCount += value.resourceBoundaryCount
                result.similarityBoundaryCount += value.similarityBoundaryCount
            }
            return result
        }

        private init(
            turnCount: Int,
            vectorizedTurnCount: Int,
            joinedBoundaryCount: Int,
            languageTransitionBoundaryCount: Int,
            unavailableLanguageBoundaryCount: Int,
            resourceBoundaryCount: Int,
            similarityBoundaryCount: Int
        ) {
            self.turnCount = turnCount
            self.vectorizedTurnCount = vectorizedTurnCount
            self.joinedBoundaryCount = joinedBoundaryCount
            self.languageTransitionBoundaryCount = languageTransitionBoundaryCount
            self.unavailableLanguageBoundaryCount = unavailableLanguageBoundaryCount
            self.resourceBoundaryCount = resourceBoundaryCount
            self.similarityBoundaryCount = similarityBoundaryCount
        }
    }

    struct Resources: Encodable, Sendable {
        let wallMilliseconds: Double
        let processCPUMilliseconds: Double
        let baselinePhysicalFootprintBytes: UInt64
        let peakPhysicalFootprintBytes: UInt64
        let incrementalPeakPhysicalFootprintBytes: UInt64
        let endingPhysicalFootprintBytes: UInt64
    }
}

enum RetrievalChunkEvidenceBenchmark {
    typealias Observation = RetrievalChunkEvidenceObservation

    static func run(
        fixture: AskQualityFixture,
        options: RetrievalChunkEvidenceOptions,
        embedding injectedEmbedding: (any RetrievalSemanticBoundaryEmbedding)? = nil
    ) async throws -> Observation {
        let meetings = try RetrievalChunkEvidenceCorpus.meetings(from: fixture)
        guard let target = meetings.first else {
            throw RetrievalChunkEvidenceError.invalidCorpus
        }
        let embedding: (any RetrievalSemanticBoundaryEmbedding)?
        if options.role == .semanticBoundary {
            if let injectedEmbedding {
                embedding = injectedEmbedding
            } else {
                embedding = try CLIAppleSentenceBoundaryEmbedding()
            }
        } else {
            embedding = nil
        }

        let (projections, constructionSample) = try await samplePeakStage {
            var values: [RetrievalChunkEvidenceProjection] = []
            values.reserveCapacity(meetings.count)
            for meeting in meetings {
                values.append(try await RetrievalChunkEvidenceCorpus.projection(
                    for: meeting,
                    role: options.role,
                    embedding: embedding))
            }
            return values
        }
        guard let baselineTarget = projections.first,
              let adapter = projections.first?.adapter,
              projections.allSatisfy({ $0.adapter == adapter })
        else { throw RetrievalChunkEvidenceError.inconsistentAdapter }
        let corrections = try await correctionObservations(
            target: target,
            baseline: baselineTarget,
            adapter: adapter,
            role: options.role,
            embedding: embedding)
        return makeObservation(
            fixture: fixture,
            options: options,
            projections: projections,
            constructionResources: constructionSample.resources,
            corrections: corrections,
            adapter: adapter)
    }

    private static func makeObservation(
        fixture: AskQualityFixture,
        options: RetrievalChunkEvidenceOptions,
        projections: [RetrievalChunkEvidenceProjection],
        constructionResources: Observation.Resources,
        corrections: [Observation.Correction],
        adapter: String
    ) -> Observation {
        let subject = Observation.Subject(
            build: options.build,
            sourceCommit: options.commit,
            fixtureGeneration: fixture.generation,
            fixtureSHA256: options.fixtureSHA256,
            toolchainSHA256: options.toolchainSHA256,
            hostProfile: options.hostProfile,
            retrievalUnit: options.role.rawValue,
            adapter: adapter)
        let process = ProcessInfo.processInfo
        let host = Observation.Host(
            operatingSystem: process.operatingSystemVersionString,
            architecture: machineArchitecture(),
            processorCount: process.processorCount,
            physicalMemoryBytes: process.physicalMemory)
        let corpus = Observation.Corpus(
            contentSource: fixture.contentSource,
            meetingCount: Set(fixture.segments.map(\.meetingID)).count,
            sourceSegmentCount: fixture.segments.count)
        let construction = Observation.Construction(
            resultingUnitCount: projections.reduce(0) {
                $0 + $1.units.count
            },
            sourceReferenceCount: projections.reduce(0) {
                $0 + $1.sourceReferenceCount
            },
            turnCount: projections.reduce(0) { $0 + $1.turnCount },
            diagnostics: Observation.Diagnostics.sum(
                projections.compactMap(\.semanticDiagnostics)),
            resources: constructionResources)
        return Observation(
            subject: subject,
            host: host,
            corpus: corpus,
            construction: construction,
            corrections: corrections)
    }

    private static func correctionObservations(
        target: RetrievalChunkEvidenceMeeting,
        baseline: RetrievalChunkEvidenceProjection,
        adapter: String,
        role: RetrievalChunkEvidenceRole,
        embedding: (any RetrievalSemanticBoundaryEmbedding)?
    ) async throws -> [Observation.Correction] {
        var observations: [Observation.Correction] = []
        for scenario in RetrievalChunkCorrectionScenario.allCases {
            let corrected = try RetrievalChunkEvidenceCorpus.corrected(
                target,
                scenario: scenario)
            let (projection, sample) = try await samplePeakStage {
                try await RetrievalChunkEvidenceCorpus.projection(
                    for: corrected,
                    role: role,
                    embedding: embedding)
            }
            guard projection.adapter == adapter else {
                throw RetrievalChunkEvidenceError.inconsistentAdapter
            }
            let delta = RetrievalChunkEvidenceDelta.between(
                previous: baseline,
                current: projection)
            observations.append(Observation.Correction(
                scenario: scenario.rawValue,
                inputSegmentCount: corrected.segments.count,
                resultingUnitCount: projection.units.count,
                sourceReferenceCount: projection.sourceReferenceCount,
                turnCount: projection.turnCount,
                retainedUnitCount: delta.retainedCount,
                candidateEmbeddingUpsertCount: delta.upsertCount,
                removedUnitCount: delta.removedCount,
                diagnostics: projection.semanticDiagnostics.map(
                    Observation.Diagnostics.init),
                resources: sample.resources))
        }
        return observations
    }

    private struct ProcessUsage: Sendable {
        let cpuAbsoluteTime: UInt64
        let physicalFootprintBytes: UInt64

        static func current() throws -> Self {
            var usage = rusage_info_current()
            let result = withUnsafeMutablePointer(to: &usage) { pointer in
                pointer.withMemoryRebound(
                    to: rusage_info_t?.self,
                    capacity: 1
                ) { reboundPointer in
                    proc_pid_rusage(
                        getpid(),
                        RUSAGE_INFO_CURRENT,
                        reboundPointer)
                }
            }
            guard result == 0 else {
                throw RetrievalChunkEvidenceError.processUsageUnavailable
            }
            return Self(
                cpuAbsoluteTime: usage.ri_user_time + usage.ri_system_time,
                physicalFootprintBytes: usage.ri_phys_footprint)
        }
    }

    private struct PeakSample: Sendable {
        let resources: Observation.Resources
    }

    private static func samplePeakStage<Value: Sendable>(
        _ operation: () async throws -> Value
    ) async throws -> (Value, PeakSample) {
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
        do {
            let start = ContinuousClock.now
            let value = try await operation()
            let wallMilliseconds = milliseconds(since: start)
            let after = try ProcessUsage.current()
            sampler.cancel()
            let peak = max(after.physicalFootprintBytes, await sampler.value)
            let cpuTicks = after.cpuAbsoluteTime
                - min(after.cpuAbsoluteTime, before.cpuAbsoluteTime)
            return (
                value,
                PeakSample(resources: .init(
                    wallMilliseconds: wallMilliseconds,
                    processCPUMilliseconds: cpuMilliseconds(ticks: cpuTicks),
                    baselinePhysicalFootprintBytes: before.physicalFootprintBytes,
                    peakPhysicalFootprintBytes: peak,
                    incrementalPeakPhysicalFootprintBytes:
                        peak - min(peak, before.physicalFootprintBytes),
                    endingPhysicalFootprintBytes: after.physicalFootprintBytes)))
        } catch {
            sampler.cancel()
            _ = await sampler.value
            throw error
        }
    }

    private static func milliseconds(
        since start: ContinuousClock.Instant
    ) -> Double {
        let components = start.duration(to: .now).components
        return Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1_000_000_000_000_000
    }

    private static func cpuMilliseconds(ticks: UInt64) -> Double {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        return Double(ticks) * Double(timebase.numer)
            / Double(timebase.denom) / 1_000_000
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
