import ApplicationKit
import Foundation
import PortavozCore
import StorageKit

/// Runs the production hybrid retrieval adapter over an isolated judged
/// corpus and emits D203 observations. It never opens the user's library and
/// does not run a generative answer model; answer quality stays explicitly
/// unevaluated until a separate, versioned judge supplies that evidence.
enum BenchAskQualityCommand {
    static func run(_ arguments: [String], attribution: Bool = false) async {
        do {
            let options = try AskQualityBenchmarkOptions(arguments: arguments)
            let fixture = try AskQualityFixture.load(from: options.fixture)
            if attribution {
                let document = try await AskQualityAttributionBenchmark.run(
                    fixture: fixture, options: options)
                try CLIPrivateJSONWriter.write(document, to: options.output)
                print("Ask stage attribution: \(options.output.path)")
                return
            }
            let observations = try await AskQualityProductionBenchmark.run(
                fixture: fixture,
                build: options.build,
                commit: options.commit,
                retrievalUnit: options.retrievalUnit,
                allowAssetDownload: options.allowAssetDownload)
            try AskQualityPrivateJSONWriter.write(
                observations,
                to: options.output)
            print("Ask quality observations: \(options.output.path)")
        } catch {
            let command = attribution ? "bench-ask-attribution" : "bench-ask-quality"
            // Attribution never exports arbitrary provider/storage error payloads.
            let detail = attribution
                ? (error as? AskQualityAttributionError)?.localizedDescription ?? "diagnostic failed"
                : error.localizedDescription
            FileHandle.standardError.write(
                Data("\(command) error: \(detail)\n".utf8))
            Foundation.exit(64)
        }
    }
}

struct AskQualityBenchmarkOptions: Equatable {
    let fixture: URL
    let output: URL
    let build: String
    let commit: String
    let retrievalUnit: AskQualityRetrievalUnit
    let allowAssetDownload: Bool

    init(arguments: [String]) throws {
        let values = try Self.parse(arguments)
        guard let fixture = values["--fixture"], !fixture.isEmpty else {
            throw AskQualityBenchmarkError.missingOption("--fixture")
        }
        guard let output = values["--output"], !output.isEmpty else {
            throw AskQualityBenchmarkError.missingOption("--output")
        }
        guard let build = values["--build"], AskQualityIdentity.isSafeBuild(build) else {
            throw AskQualityBenchmarkError.invalidBuild
        }
        guard let commit = values["--commit"], AskQualityIdentity.isCommit(commit) else {
            throw AskQualityBenchmarkError.invalidCommit
        }
        let retrievalUnit = try AskQualityRetrievalUnit(
            argument: values["--retrieval-unit"] ?? AskQualityRetrievalUnit.segment.rawValue)
        let assetDownloadPolicy = values["--asset-download"] ?? "never"
        guard ["never", "if-needed"].contains(assetDownloadPolicy) else {
            throw AskQualityBenchmarkError.invalidAssetDownloadPolicy(
                assetDownloadPolicy)
        }
        self.fixture = URL(fileURLWithPath: fixture).standardizedFileURL
        self.output = URL(fileURLWithPath: output).standardizedFileURL
        self.build = build
        self.commit = commit
        self.retrievalUnit = retrievalUnit
        self.allowAssetDownload = assetDownloadPolicy == "if-needed"
        guard self.fixture != self.output else {
            throw AskQualityBenchmarkError.outputMatchesFixture
        }
    }

    private static func parse(_ arguments: [String]) throws -> [String: String] {
        let allowed = Set([
            "--fixture", "--output", "--build", "--commit", "--retrieval-unit",
            "--asset-download"
        ])
        var values: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            let option = arguments[index]
            guard allowed.contains(option) else {
                throw AskQualityBenchmarkError.unknownOption(option)
            }
            index += 1
            guard arguments.indices.contains(index) else {
                throw AskQualityBenchmarkError.missingOptionValue(option)
            }
            values[option] = arguments[index]
            index += 1
        }
        return values
    }
}

enum AskQualityBenchmarkError: Error, Equatable, LocalizedError {
    case unknownOption(String)
    case missingOptionValue(String)
    case missingOption(String)
    case invalidBuild
    case invalidCommit
    case invalidRetrievalUnit(String)
    case invalidAssetDownloadPolicy(String)
    case outputMatchesFixture
    case invalidFixture(String)
    case invalidTimestamp
    case outputAlreadyExists
    case outputPublicationFailed

    var errorDescription: String? {
        switch self {
        case .unknownOption(let option):
            "unknown option: \(option)"
        case .missingOptionValue(let option):
            "missing value for option: \(option)"
        case .missingOption(let option):
            "missing required option: \(option)"
        case .invalidBuild:
            "build must be a bounded receipt-safe identifier"
        case .invalidCommit:
            "commit must be one full lowercase SHA"
        case .invalidRetrievalUnit(let unit):
            "invalid retrieval unit: \(unit)"
        case .invalidAssetDownloadPolicy(let policy):
            "invalid asset download policy: \(policy)"
        case .outputMatchesFixture:
            "output must not replace the fixture"
        case .invalidFixture(let reason):
            "invalid fixture: \(reason)"
        case .invalidTimestamp:
            "fixture timestamp cannot be represented"
        case .outputAlreadyExists:
            "output already exists"
        case .outputPublicationFailed:
            "output publication failed"
        }
    }
}

private enum AskQualityIdentity {
    static func isSafeBuild(_ value: String) -> Bool {
        guard (1...80).contains(value.count) else { return false }
        return value.allSatisfy {
            $0.isLetter || $0.isNumber || ".+_-".contains($0)
        }
    }

    static func isCommit(_ value: String) -> Bool {
        value.utf8.count == 40 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }
}

enum AskQualityRetrievalUnit: String, Equatable, Sendable {
    case segment
    case speakerTurn = "speaker-turn"
    case conversationWindow = "conversation-window"
    case semanticBoundary = "semantic-boundary"

    init(argument: String) throws {
        guard let value = Self(rawValue: argument) else {
            throw AskQualityBenchmarkError.invalidRetrievalUnit(argument)
        }
        self = value
    }

    var fixedAdapter: String? {
        switch self {
        case .segment:
            "local-hybrid-preindexed-segment-no-expansion-evidence-v3"
        case .speakerTurn:
            "local-hybrid-preindexed-speaker-turn-v1-no-expansion-evidence-v1"
        case .conversationWindow:
            "local-hybrid-preindexed-conversation-window-v1-no-expansion-evidence-v1"
        case .semanticBoundary:
            nil
        }
    }

    func matches(adapter: String) -> Bool {
        if let fixedAdapter {
            return adapter == fixedAdapter
        }
        guard adapter.hasPrefix(RetrievalSemanticBoundaryChunker.adapterPrefix)
        else { return false }
        let fingerprint = adapter.dropFirst(
            RetrievalSemanticBoundaryChunker.adapterPrefix.count)
        return fingerprint.utf8.count == 64
            && fingerprint.utf8.allSatisfy {
                (48...57).contains($0) || (97...102).contains($0)
            }
    }
}

struct AskQualityFixture: Decodable, Sendable {
    let schemaVersion: Int
    let kind: String
    let generation: String
    let contentSource: String
    let segments: [AskQualityFixtureSegment]
    let queries: [AskQualityFixtureQuery]

    static func load(from url: URL) throws -> Self {
        let data: Data
        do {
            data = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            throw AskQualityBenchmarkError.invalidFixture("fixture cannot be read")
        }
        guard data.count <= 8 * 1_024 * 1_024 else {
            throw AskQualityBenchmarkError.invalidFixture("fixture exceeds 8 MiB")
        }
        let fixture: Self
        do {
            fixture = try JSONDecoder().decode(Self.self, from: data)
        } catch {
            throw AskQualityBenchmarkError.invalidFixture("fixture is not valid JSON")
        }
        try fixture.validate()
        return fixture
    }

    func validate() throws {
        guard schemaVersion == 1, kind == "ask-quality-fixture" else {
            throw AskQualityBenchmarkError.invalidFixture("unsupported fixture schema")
        }
        guard !generation.isEmpty,
              ["public-synthetic-only", "private-anonymized"].contains(contentSource),
              !segments.isEmpty,
              !queries.isEmpty,
              segments.count <= 10_000,
              queries.count <= 10_000
        else {
            throw AskQualityBenchmarkError.invalidFixture("invalid fixture bounds")
        }
        let segmentIDs = Set(segments.map(\.id))
        guard segmentIDs.count == segments.count,
              Set(queries.map(\.id)).count == queries.count
        else {
            throw AskQualityBenchmarkError.invalidFixture("fixture identities repeat")
        }
        guard segments.allSatisfy({
            !$0.id.isEmpty && !$0.meetingID.isEmpty && !$0.meetingTitle.isEmpty
                && !$0.owner.isEmpty && !$0.text.isEmpty
                && $0.timestampMilliseconds >= 0 && $0.transcriptRevision >= 1
        }) else {
            throw AskQualityBenchmarkError.invalidFixture("invalid segment")
        }
        for query in queries {
            try query.validate(segmentIDs: segmentIDs)
        }
        for group in Dictionary(grouping: segments, by: \.meetingID).values {
            guard Set(group.map(\.meetingTitle)).count == 1,
                  Set(group.map(\.transcriptRevision)).count == 1
            else {
                throw AskQualityBenchmarkError.invalidFixture(
                    "meeting title or transcript revision is inconsistent")
            }
        }
    }
}

struct AskQualityFixtureSegment: Decodable, Sendable {
    let id: String
    let meetingID: String
    let meetingTitle: String
    let timestampMilliseconds: Int
    let transcriptRevision: Int
    let language: String
    let owner: String
    let text: String
}

struct AskQualityFixtureQuery: Decodable, Sendable {
    let id: String
    let text: String
    let relationship: String
    let intent: String
    let relevant: [AskQualityFixtureRelevant]
    let hardNegativeSegmentIDs: [String]
    let answerPolicy: String

    func validate(segmentIDs: Set<String>) throws {
        let relevantIDs = relevant.map(\.segmentID)
        let hardNegativeIDs = hardNegativeSegmentIDs
        guard !id.isEmpty,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              ["answer", "abstain"].contains(answerPolicy),
              relevant.allSatisfy({
                  segmentIDs.contains($0.segmentID)
                      && (1...3).contains($0.grade)
                      && $0.expectedTimestampMilliseconds >= 0
                      && !$0.expectedOwner.isEmpty
              }),
              hardNegativeIDs.allSatisfy(segmentIDs.contains),
              Set(relevantIDs).count == relevantIDs.count,
              Set(hardNegativeIDs).count == hardNegativeIDs.count,
              Set(relevantIDs).isDisjoint(with: hardNegativeIDs),
              (answerPolicy == "answer") == !relevant.isEmpty
        else {
            throw AskQualityBenchmarkError.invalidFixture("invalid query")
        }
    }
}

struct AskQualityFixtureRelevant: Decodable, Sendable {
    let segmentID: String
    let grade: Int
    let expectedTimestampMilliseconds: Int
    let expectedOwner: String
}

struct AskQualityObservationDocument: Encodable, Sendable {
    let schemaVersion = 2
    let kind = "ask-quality-observations"
    let fixtureGeneration: String
    let adapter: String
    let build: String
    let commit: String
    let queries: [AskQualityQueryObservation]
}

struct AskQualityQueryObservation: Encodable, Sendable {
    let queryID: String
    let hits: [AskQualityHitObservation]
    let answer: AskQualityAnswerObservation
}

struct AskQualityHitObservation: Encodable, Equatable, Sendable {
    let unitID: String
    let sourceSegmentIDs: [String]
    let meetingID: String
    let timestampMilliseconds: Int
    let transcriptRevision: Int
}

struct AskQualityAnswerObservation: Encodable, Sendable {
    let outcome = "notEvaluated"
    let factuality: Double? = nil
    let citationCoverage: Double? = nil
    let unsupportedClaims = 0

    private enum CodingKeys: String, CodingKey {
        case outcome, factuality, citationCoverage, unsupportedClaims
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(outcome, forKey: .outcome)
        try container.encodeNil(forKey: .factuality)
        try container.encodeNil(forKey: .citationCoverage)
        try container.encode(unsupportedClaims, forKey: .unsupportedClaims)
    }
}

enum AskQualityProductionBenchmark {
    static func run(
        fixture: AskQualityFixture,
        build: String,
        commit: String,
        retrievalUnit: AskQualityRetrievalUnit = .segment,
        allowAssetDownload: Bool = false
    ) async throws -> AskQualityObservationDocument {
        try await AskQualityWorkspace.withCorpus(
            fixture: fixture,
            retrievalUnit: retrievalUnit
        ) { context in
            _ = try await prepareCorpus(
                store: context.store, runtime: context.runtime,
                allowAssetDownload: allowAssetDownload)
            let retrieval = LocalAskMeetingRetrieval(
                store: context.store,
                queryExpander: AskQualityNoExpansion(),
                runtime: context.runtime)
            return try await observe(
                fixture: fixture, mapping: context.mapping, retrieval: retrieval,
                build: build, commit: commit, retrievalUnit: retrievalUnit)
        }
    }

    static func prepareCorpus(
        store: MeetingStore,
        runtime: any SemanticEmbeddingRuntimeClient,
        allowAssetDownload: Bool = false
    ) async throws -> SemanticCorpusIndexingResult {
        try await runtime.withPreparedEmbedding(
            allowAssetDownload: allowAssetDownload
        ) { embedder in
            try await IndexSemanticCorpus(store: store).all(
                using: embedder,
                batchSize: 256)
        }
    }

    static func observe(
        fixture: AskQualityFixture,
        mapping: AskQualityCorpusMapping,
        retrieval: any AskMeetingRetrieving,
        build: String,
        commit: String,
        retrievalUnit: AskQualityRetrievalUnit = .segment
    ) async throws -> AskQualityObservationDocument {
        guard retrievalUnit.matches(adapter: mapping.adapter) else {
            throw AskQualityBenchmarkError.invalidFixture(
                "retrieval unit does not match corpus adapter identity")
        }
        var observations: [AskQualityQueryObservation] = []
        observations.reserveCapacity(fixture.queries.count)
        for query in fixture.queries {
            try Task.checkCancellation()
            let citations = try await retrieval.retrieve(
                question: query.text,
                limit: 10)
            let hits = try citations.map { citation in
                try mapping.observation(for: citation)
            }
            observations.append(AskQualityQueryObservation(
                queryID: query.id,
                hits: hits,
                answer: AskQualityAnswerObservation()))
        }
        return AskQualityObservationDocument(
            fixtureGeneration: fixture.generation,
            adapter: mapping.adapter,
            build: build,
            commit: commit,
            queries: observations)
    }
}

struct AskQualityNoExpansion: AskQueryExpanding {
    func expand(_ question: String) throws -> [String] { [question] }
}

enum AskQualityPrivateJSONWriter {
    static func write(
        _ document: AskQualityObservationDocument,
        to output: URL
    ) throws {
        do {
            try CLIPrivateJSONWriter.write(document, to: output)
        } catch CLIPrivateJSONWriterError.outputAlreadyExists {
            throw AskQualityBenchmarkError.outputAlreadyExists
        } catch CLIPrivateJSONWriterError.publicationFailed {
            throw AskQualityBenchmarkError.outputPublicationFailed
        }
    }
}
