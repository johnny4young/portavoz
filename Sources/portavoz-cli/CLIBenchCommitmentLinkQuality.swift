import ApplicationKit
import CryptoKit
import Foundation
import PortavozCore
import StorageKit

enum BenchCommitmentLinkQualityCommand {
    static func run(_ arguments: [String]) async {
        do {
            let options = try CommitmentLinkQualityBenchmarkOptions(arguments: arguments)
            let fixture = try CommitmentLinkQualityFixture.load(from: options.fixture)
            let observations = try await CommitmentLinkQualityProductBenchmark.run(
                fixture: fixture,
                runtime: CLISemanticEmbeddingRuntime(),
                allowAssetDownload: options.allowAssetDownload)
            try CommitmentLinkQualityPrivateJSONWriter.write(
                observations,
                to: options.output)
            print("Commitment-link observations: \(options.output.path)")
        } catch {
            FileHandle.standardError.write(
                Data("bench-commitment-link-quality error: \(error.localizedDescription)\n".utf8))
            Foundation.exit(64)
        }
    }
}

/// Captures score-bearing product-path evidence for offline policy research.
/// This command is deliberately separate from the stable unscored observation
/// schema: it cannot evaluate, approve, or serve a link suggestion.
enum BenchCommitmentLinkSimilarityCommand {
    static func run(_ arguments: [String]) async {
        do {
            let options = try CommitmentLinkSimilarityBenchmarkOptions(
                arguments: arguments)
            let fixture = try CommitmentLinkQualityFixture.load(from: options.fixture)
            let observations = try await CommitmentLinkQualityProductBenchmark
                .runSimilarity(
                    fixture: fixture,
                    runtime: CLISemanticEmbeddingRuntime(),
                    build: options.build,
                    commit: options.commit,
                    allowAssetDownload: options.allowAssetDownload)
            try CommitmentLinkSimilarityJSONWriter.write(
                observations,
                to: options.output)
            print("Commitment-link similarity observations: \(options.output.path)")
        } catch {
            FileHandle.standardError.write(
                Data(
                    "bench-commitment-link-similarity error: \(error.localizedDescription)\n"
                        .utf8))
            Foundation.exit(64)
        }
    }
}

struct CommitmentLinkQualityBenchmarkOptions: Equatable {
    let fixture: URL
    let output: URL
    let allowAssetDownload: Bool

    init(arguments: [String]) throws {
        let values = try Self.parse(arguments)
        guard let fixture = values["--fixture"], !fixture.isEmpty else {
            throw CommitmentLinkQualityBenchmarkError.missingOption("--fixture")
        }
        guard let output = values["--output"], !output.isEmpty else {
            throw CommitmentLinkQualityBenchmarkError.missingOption("--output")
        }
        let downloadPolicy = values["--asset-download"] ?? "never"
        guard ["never", "if-needed"].contains(downloadPolicy) else {
            throw CommitmentLinkQualityBenchmarkError.invalidAssetDownloadPolicy(
                downloadPolicy)
        }
        self.fixture = URL(fileURLWithPath: fixture).standardizedFileURL
        self.output = URL(fileURLWithPath: output).standardizedFileURL
        allowAssetDownload = downloadPolicy == "if-needed"
        guard self.fixture != self.output else {
            throw CommitmentLinkQualityBenchmarkError.outputMatchesFixture
        }
    }

    private static func parse(_ arguments: [String]) throws -> [String: String] {
        let allowed = Set(["--fixture", "--output", "--asset-download"])
        var values: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            let option = arguments[index]
            guard allowed.contains(option) else {
                throw CommitmentLinkQualityBenchmarkError.unknownOption(option)
            }
            index += 1
            guard arguments.indices.contains(index) else {
                throw CommitmentLinkQualityBenchmarkError.missingOptionValue(option)
            }
            guard values.updateValue(arguments[index], forKey: option) == nil else {
                throw CommitmentLinkQualityBenchmarkError.duplicateOption(option)
            }
            index += 1
        }
        return values
    }
}

struct CommitmentLinkSimilarityBenchmarkOptions: Equatable {
    let fixture: URL
    let output: URL
    let build: String
    let commit: String
    let allowAssetDownload: Bool

    init(arguments: [String]) throws {
        let values = try Self.parse(arguments)
        guard let fixture = values["--fixture"], !fixture.isEmpty else {
            throw CommitmentLinkQualityBenchmarkError.missingOption("--fixture")
        }
        guard let output = values["--output"], !output.isEmpty else {
            throw CommitmentLinkQualityBenchmarkError.missingOption("--output")
        }
        guard let build = values["--build"],
              CommitmentLinkBenchmarkIdentity.isSafeBuild(build)
        else {
            throw CommitmentLinkQualityBenchmarkError.invalidBuild
        }
        guard let commit = values["--commit"],
              CommitmentLinkBenchmarkIdentity.isCommit(commit)
        else {
            throw CommitmentLinkQualityBenchmarkError.invalidCommit
        }
        let downloadPolicy = values["--asset-download"] ?? "never"
        guard ["never", "if-needed"].contains(downloadPolicy) else {
            throw CommitmentLinkQualityBenchmarkError.invalidAssetDownloadPolicy(
                downloadPolicy)
        }
        self.fixture = URL(fileURLWithPath: fixture).standardizedFileURL
        self.output = URL(fileURLWithPath: output).standardizedFileURL
        self.build = build
        self.commit = commit
        allowAssetDownload = downloadPolicy == "if-needed"
        guard self.fixture != self.output else {
            throw CommitmentLinkQualityBenchmarkError.outputMatchesFixture
        }
    }

    private static func parse(_ arguments: [String]) throws -> [String: String] {
        let allowed = Set([
            "--fixture", "--output", "--build", "--commit", "--asset-download"
        ])
        var values: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            let option = arguments[index]
            guard allowed.contains(option) else {
                throw CommitmentLinkQualityBenchmarkError.unknownOption(option)
            }
            index += 1
            guard arguments.indices.contains(index) else {
                throw CommitmentLinkQualityBenchmarkError.missingOptionValue(option)
            }
            guard values.updateValue(arguments[index], forKey: option) == nil else {
                throw CommitmentLinkQualityBenchmarkError.duplicateOption(option)
            }
            index += 1
        }
        return values
    }
}

enum CommitmentLinkQualityBenchmarkError: Error, Equatable, LocalizedError {
    case unknownOption(String)
    case duplicateOption(String)
    case missingOptionValue(String)
    case missingOption(String)
    case invalidBuild
    case invalidCommit
    case invalidAssetDownloadPolicy(String)
    case outputMatchesFixture
    case invalidFixture(String)
    case invalidObservation(String)
    case outputAlreadyExists
    case outputPublicationFailed

    var errorDescription: String? {
        switch self {
        case .unknownOption(let option): "unknown option: \(option)"
        case .duplicateOption(let option): "duplicate option: \(option)"
        case .missingOptionValue(let option): "missing value for option: \(option)"
        case .missingOption(let option): "missing required option: \(option)"
        case .invalidBuild: "build must be a bounded receipt-safe identifier"
        case .invalidCommit: "commit must be one full lowercase SHA"
        case .invalidAssetDownloadPolicy(let policy):
            "invalid asset download policy: \(policy)"
        case .outputMatchesFixture: "output must not replace the fixture"
        case .invalidFixture(let reason): "invalid fixture: \(reason)"
        case .invalidObservation(let reason): "invalid observation: \(reason)"
        case .outputAlreadyExists: "output already exists"
        case .outputPublicationFailed: "output publication failed"
        }
    }
}

private enum CommitmentLinkBenchmarkIdentity {
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

struct CommitmentLinkQualityFixture: Decodable, Sendable {
    static let canonicalDigest =
        "e9ebeb86f832f726deb82ea5b08953808f23a3ac79ab8018375599d1a6971f0a"

    let schemaVersion: Int
    let kind: String
    let generation: String
    let contentSource: String
    let cases: [CommitmentLinkQualityCase]
    private(set) var fixtureSHA256 = ""

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, kind, generation, contentSource, cases
    }

    static func load(from url: URL) throws -> Self {
        let data: Data
        do {
            data = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            throw CommitmentLinkQualityBenchmarkError.invalidFixture(
                "fixture cannot be read")
        }
        guard data.count <= 4 * 1_024 * 1_024 else {
            throw CommitmentLinkQualityBenchmarkError.invalidFixture(
                "fixture exceeds 4 MiB")
        }
        let digest = try canonicalDigest(for: data)
        guard digest == canonicalDigest else {
            throw CommitmentLinkQualityBenchmarkError.invalidFixture(
                "fixture does not match the canonical public generation")
        }
        var fixture: Self
        do {
            fixture = try JSONDecoder().decode(Self.self, from: data)
        } catch {
            throw CommitmentLinkQualityBenchmarkError.invalidFixture(
                "fixture is not valid JSON")
        }
        fixture.fixtureSHA256 = digest
        try fixture.validate()
        return fixture
    }

    private static func canonicalDigest(for data: Data) throws -> String {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw CommitmentLinkQualityBenchmarkError.invalidFixture(
                "fixture is not valid JSON")
        }
        let canonical: Data
        do {
            canonical = try JSONSerialization.data(
                withJSONObject: object,
                options: [.sortedKeys, .withoutEscapingSlashes])
        } catch {
            throw CommitmentLinkQualityBenchmarkError.invalidFixture(
                "fixture cannot be canonicalized")
        }
        return SHA256.hash(data: canonical)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func validate() throws {
        guard schemaVersion == 1,
              kind == "commitment-link-quality-fixture",
              generation == "public-synthetic-v1",
              contentSource == "public-synthetic-only",
              cases.count == 36,
              Set(cases.map(\.id)).count == cases.count
        else {
            throw CommitmentLinkQualityBenchmarkError.invalidFixture(
                "unsupported fixture schema or bounds")
        }
        for fixtureCase in cases {
            try fixtureCase.validate()
        }
    }
}

struct CommitmentLinkQualityCase: Decodable, Sendable {
    let id: String
    let language: String
    let `class`: String
    let candidate: CommitmentLinkQualityCandidate
    let targets: [CommitmentLinkQualityTarget]
    let expected: CommitmentLinkQualityExpected

    func validate() throws {
        let targetIDs = targets.map(\.id)
        let evidenceIDs = targets.flatMap { $0.evidence.map(\.id) }
        guard !id.isEmpty,
              ["en", "es", "mixed"].contains(language),
              !`class`.isEmpty,
              (1...200).contains(targets.count),
              Set(targetIDs).count == targetIDs.count,
              Set(evidenceIDs).count == evidenceIDs.count,
              expected.linkableCommitmentIDs.allSatisfy(targetIDs.contains),
              expected.semanticRelevantCommitmentIDs.allSatisfy(targetIDs.contains),
              Set(expected.linkableCommitmentIDs).isSubset(
                  of: Set(expected.semanticRelevantCommitmentIDs)),
              expected.mustAbstain == expected.linkableCommitmentIDs.isEmpty
        else {
            throw CommitmentLinkQualityBenchmarkError.invalidFixture(
                "case \(id) is inconsistent")
        }
        try candidate.validate()
        for target in targets { try target.validate() }
    }
}

struct CommitmentLinkQualityCandidate: Decodable, Sendable {
    let sourceMeetingID: String
    let actionItemID: String
    let language: String
    let text: String
    let assignee: CommitmentLinkQualityAssignee

    func validate() throws {
        guard !sourceMeetingID.isEmpty,
              !actionItemID.isEmpty,
              ["en", "es", "mixed"].contains(language),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.count <= 500
        else {
            throw CommitmentLinkQualityBenchmarkError.invalidFixture(
                "candidate is invalid")
        }
        try assignee.validate()
    }
}

struct CommitmentLinkQualityTarget: Decodable, Sendable {
    let id: String
    let title: String
    let status: String
    let assignee: CommitmentLinkQualityAssignee
    let sourceMeetingIDs: [String]
    let evidence: [CommitmentLinkQualityEvidence]

    func validate() throws {
        guard !id.isEmpty,
              !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              ["confirmed", "done", "dismissed"].contains(status),
              (1...20).contains(sourceMeetingIDs.count),
              Set(sourceMeetingIDs).count == sourceMeetingIDs.count,
              (1...20).contains(evidence.count),
              evidence.allSatisfy({ sourceMeetingIDs.contains($0.meetingID) })
        else {
            throw CommitmentLinkQualityBenchmarkError.invalidFixture(
                "target \(id) is invalid")
        }
        try assignee.validate()
    }
}

struct CommitmentLinkQualityEvidence: Decodable, Sendable {
    let id: String
    let meetingID: String
    let language: String
    let text: String
}

struct CommitmentLinkQualityAssignee: Codable, Sendable, Equatable, Hashable {
    let kind: String
    let id: String?

    func validate() throws {
        let valid = switch kind {
        case "person": id?.isEmpty == false
        case "me", "unassigned": id == nil
        default: false
        }
        guard valid else {
            throw CommitmentLinkQualityBenchmarkError.invalidFixture(
                "assignee is invalid")
        }
    }

    private enum CodingKeys: String, CodingKey { case kind, id }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        if let id {
            try container.encode(id, forKey: .id)
        } else {
            try container.encodeNil(forKey: .id)
        }
    }
}

struct CommitmentLinkQualityExpected: Decodable, Sendable {
    let semanticRelevantCommitmentIDs: [String]
    let linkableCommitmentIDs: [String]
    let mustAbstain: Bool
}

struct CommitmentLinkQualityObservationDocument: Encodable, Sendable {
    let schemaVersion = 1
    let kind = "commitment-link-quality-observations"
    let fixtureGeneration: String
    let fixtureSHA256: String
    let adapter: String
    let observations: [CommitmentLinkQualityCaseObservation]
}

struct CommitmentLinkQualityCaseObservation: Encodable, Sendable {
    let caseID: String
    let semanticHitSegmentIDs: [String]
    let suggestions: [CommitmentLinkSuggestionRow]
}

struct CommitmentLinkSuggestionRow: Encodable, Sendable {
    let commitmentID: String
    let assignee: CommitmentLinkQualityAssignee
    let matchedEvidenceSegmentIDs: [String]
    let bestSemanticRank: Int
}

/// Owner-only score evidence for deterministic offline policy replay. The
/// document is intentionally distinct from the stable unscored contract.
struct CommitmentLinkSimilarityDocument: Encodable, Sendable {
    let schemaVersion = 1
    let kind = "commitment-link-similarity-observations"
    let fixtureGeneration: String
    let fixtureSHA256: String
    let adapter: String
    let embeddingProfileFingerprint: String
    let build: String
    let commit: String
    let evaluationStatus = "not-evaluated"
    let servingStatus = "not-approved"
    let observations: [CommitmentLinkSimilarityCaseObservation]
}

struct CommitmentLinkSimilarityCaseObservation: Encodable, Sendable {
    let caseID: String
    let semanticHits: [CommitmentLinkSimilarityHitRow]
    let suggestions: [CommitmentLinkSuggestionRow]
}

struct CommitmentLinkSimilarityHitRow: Encodable, Sendable, Equatable {
    let evidenceSegmentID: String
    let similarity: Float
}

private struct CommitmentLinkProductObservationRun: Sendable {
    let profileFingerprint: String
    let rows: [CommitmentLinkProductCaseObservation]
}

struct CommitmentLinkProductCaseObservation: Sendable {
    let quality: CommitmentLinkQualityCaseObservation
    let similarity: CommitmentLinkSimilarityCaseObservation
}

enum CommitmentLinkQualityProductBenchmark {
    static func run(
        fixture: CommitmentLinkQualityFixture,
        runtime: any SemanticEmbeddingRuntimeClient,
        allowAssetDownload: Bool = false
    ) async throws -> CommitmentLinkQualityObservationDocument {
        let productRun = try await observeProductPath(
            fixture: fixture,
            runtime: runtime,
            allowAssetDownload: allowAssetDownload)
        return CommitmentLinkQualityObservationDocument(
            fixtureGeneration: fixture.generation,
            fixtureSHA256: fixture.fixtureSHA256,
            adapter: "product-accelerate-exact-\(productRun.profileFingerprint.prefix(16))-v1",
            observations: productRun.rows.map(\.quality))
    }

    static func runSimilarity(
        fixture: CommitmentLinkQualityFixture,
        runtime: any SemanticEmbeddingRuntimeClient,
        build: String,
        commit: String,
        allowAssetDownload: Bool = false
    ) async throws -> CommitmentLinkSimilarityDocument {
        guard CommitmentLinkBenchmarkIdentity.isSafeBuild(build) else {
            throw CommitmentLinkQualityBenchmarkError.invalidBuild
        }
        guard CommitmentLinkBenchmarkIdentity.isCommit(commit) else {
            throw CommitmentLinkQualityBenchmarkError.invalidCommit
        }
        let productRun = try await observeProductPath(
            fixture: fixture,
            runtime: runtime,
            allowAssetDownload: allowAssetDownload)
        return CommitmentLinkSimilarityDocument(
            fixtureGeneration: fixture.generation,
            fixtureSHA256: fixture.fixtureSHA256,
            adapter: "product-accelerate-exact-scored-v1",
            embeddingProfileFingerprint: productRun.profileFingerprint,
            build: build,
            commit: commit,
            observations: productRun.rows.map(\.similarity))
    }

    private static func observeProductPath(
        fixture: CommitmentLinkQualityFixture,
        runtime: any SemanticEmbeddingRuntimeClient,
        allowAssetDownload: Bool
    ) async throws -> CommitmentLinkProductObservationRun {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "portavoz-commitment-link-quality-\(UUID().uuidString)",
            isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }

        var rows: [CommitmentLinkProductCaseObservation] = []
        var profileFingerprint: String?
        rows.reserveCapacity(fixture.cases.count)
        for (index, fixtureCase) in fixture.cases.enumerated() {
            try Task.checkCancellation()
            let database = root.appendingPathComponent("case-\(index).sqlite")
            let store = try MeetingStore(databaseURL: database)
            let mapping = try await CommitmentLinkQualityCorpusMapping.seed(
                fixtureCase: fixtureCase,
                store: store)
            _ = try await runtime.withPreparedEmbedding(
                allowAssetDownload: allowAssetDownload
            ) { embedder in
                try await IndexSemanticCorpus(store: store).all(
                    using: embedder,
                    batchSize: 64)
            }
            guard let profile = await runtime.semanticEmbeddingProfile(),
                  profile.isValid
            else {
                throw CommitmentLinkQualityBenchmarkError.invalidObservation(
                    "embedding profile is unavailable")
            }
            if let profileFingerprint, profileFingerprint != profile.fingerprint {
                throw CommitmentLinkQualityBenchmarkError.invalidObservation(
                    "embedding profile changed during the run")
            }
            profileFingerprint = profile.fingerprint
            let observer = ObserveCommitmentLinkSuggestions(
                store: store,
                runtime: runtime)
            let observation = try await observer.execute(
                mapping.request(for: fixtureCase.candidate))
            rows.append(try mapping.observations(
                caseID: fixtureCase.id,
                result: observation))
        }
        guard let profileFingerprint else {
            throw CommitmentLinkQualityBenchmarkError.invalidObservation(
                "fixture produced no observations")
        }
        return CommitmentLinkProductObservationRun(
            profileFingerprint: profileFingerprint,
            rows: rows)
    }
}

enum CommitmentLinkQualityPrivateJSONWriter {
    static func write(
        _ document: CommitmentLinkQualityObservationDocument,
        to output: URL
    ) throws {
        do {
            try CLIPrivateJSONWriter.write(document, to: output)
        } catch CLIPrivateJSONWriterError.outputAlreadyExists {
            throw CommitmentLinkQualityBenchmarkError.outputAlreadyExists
        } catch CLIPrivateJSONWriterError.publicationFailed {
            throw CommitmentLinkQualityBenchmarkError.outputPublicationFailed
        }
    }
}

enum CommitmentLinkSimilarityJSONWriter {
    static func write(
        _ document: CommitmentLinkSimilarityDocument,
        to output: URL
    ) throws {
        do {
            try CLIPrivateJSONWriter.write(document, to: output)
        } catch CLIPrivateJSONWriterError.outputAlreadyExists {
            throw CommitmentLinkQualityBenchmarkError.outputAlreadyExists
        } catch CLIPrivateJSONWriterError.publicationFailed {
            throw CommitmentLinkQualityBenchmarkError.outputPublicationFailed
        }
    }
}
