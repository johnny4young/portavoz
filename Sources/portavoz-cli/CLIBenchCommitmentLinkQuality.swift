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

/// Captures score-bearing product-path evidence from one owner-reviewed,
/// anonymized private pack. The command has a separate fixture loader and
/// receipt kind so private field evidence cannot be mistaken for the public
/// synthetic authority.
enum BenchPrivateCommitmentLinkSimilarityCommand {
    static func run(_ arguments: [String]) async {
        do {
            let options = try CommitmentLinkSimilarityBenchmarkOptions(
                arguments: arguments)
            let fixture = try CommitmentLinkPrivateQualityFixture.load(
                from: options.fixture)
            let observations = try await CommitmentLinkQualityProductBenchmark
                .runPrivateSimilarity(
                    fixture: fixture,
                    runtime: CLISemanticEmbeddingRuntime(),
                    build: options.build,
                    commit: options.commit,
                    allowAssetDownload: options.allowAssetDownload)
            try CommitmentLinkPrivateSimilarityJSONWriter.write(
                observations,
                to: options.output)
            print("Private commitment-link similarity observations: \(options.output.path)")
        } catch {
            FileHandle.standardError.write(
                Data(
                    "bench-private-commitment-link-similarity error: \(error.localizedDescription)\n"
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

    fileprivate init(
        schemaVersion: Int,
        kind: String,
        generation: String,
        contentSource: String,
        cases: [CommitmentLinkQualityCase],
        fixtureSHA256: String
    ) {
        self.schemaVersion = schemaVersion
        self.kind = kind
        self.generation = generation
        self.contentSource = contentSource
        self.cases = cases
        self.fixtureSHA256 = fixtureSHA256
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

    fileprivate static func canonicalDigest(for data: Data) throws -> String {
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

    fileprivate func validate() throws {
        guard schemaVersion == 1,
              kind == "commitment-link-quality-fixture",
              generation == "public-synthetic-v1",
              contentSource == "public-synthetic-only",
              cases.count == 36
        else {
            throw CommitmentLinkQualityBenchmarkError.invalidFixture(
                "unsupported fixture schema or bounds")
        }
        try validateCases()
    }

    fileprivate func validateCases() throws {
        guard Set(cases.map(\.id)).count == cases.count else {
            throw CommitmentLinkQualityBenchmarkError.invalidFixture(
                "fixture case identities are not unique")
        }
        for fixtureCase in cases {
            try fixtureCase.validate()
        }
    }
}

struct CommitmentLinkPrivateAnonymization: Codable, Sendable, Equatable {
    let policy: String
    let reviewStatus: String
    let containsAudio: Bool
    let containsFilePaths: Bool
    let containsAccountIdentifiers: Bool
    let containsDirectIdentifiers: Bool

    fileprivate func validate() throws {
        guard policy == "owner-reviewed-redaction-v1",
              reviewStatus == "owner-reviewed",
              !containsAudio,
              !containsFilePaths,
              !containsAccountIdentifiers,
              !containsDirectIdentifiers
        else {
            throw CommitmentLinkQualityBenchmarkError.invalidFixture(
                "private anonymization attestation is invalid")
        }
    }
}

struct CommitmentLinkPrivateQualityFixture: Sendable {
    static let kind = "commitment-link-private-quality-fixture"
    static let contentSource = "private-anonymized-local"

    let productFixture: CommitmentLinkQualityFixture
    let anonymization: CommitmentLinkPrivateAnonymization

    var generation: String { productFixture.generation }
    var fixtureSHA256: String { productFixture.fixtureSHA256 }
    var cases: [CommitmentLinkQualityCase] { productFixture.cases }

    static func load(from url: URL) throws -> Self {
        try CommitmentLinkPrivateFixtureFilePolicy.validate(url)
        let data: Data
        do {
            data = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            throw CommitmentLinkQualityBenchmarkError.invalidFixture(
                "private fixture cannot be read")
        }
        guard data.count <= 4 * 1_024 * 1_024 else {
            throw CommitmentLinkQualityBenchmarkError.invalidFixture(
                "private fixture exceeds 4 MiB")
        }
        try validateExactShape(in: data)
        let payload: Payload
        do {
            payload = try JSONDecoder().decode(Payload.self, from: data)
        } catch {
            throw CommitmentLinkQualityBenchmarkError.invalidFixture(
                "private fixture is not valid JSON")
        }
        let digest = try CommitmentLinkQualityFixture.canonicalDigest(for: data)
        let fixture = CommitmentLinkQualityFixture(
            schemaVersion: payload.schemaVersion,
            kind: payload.kind,
            generation: payload.generation,
            contentSource: payload.contentSource,
            cases: payload.cases,
            fixtureSHA256: digest)
        try payload.anonymization.validate()
        try fixture.validatePrivateContract()
        return Self(
            productFixture: fixture,
            anonymization: payload.anonymization)
    }

    private struct Payload: Decodable {
        let schemaVersion: Int
        let kind: String
        let generation: String
        let contentSource: String
        let anonymization: CommitmentLinkPrivateAnonymization
        let cases: [CommitmentLinkQualityCase]
    }

    private static func validateExactShape(in data: Data) throws {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw CommitmentLinkQualityBenchmarkError.invalidFixture(
                "private fixture is not valid JSON")
        }
        let root = try exactObject(
            object,
            label: "private fixture",
            keys: [
                "schemaVersion", "kind", "generation", "contentSource",
                "anonymization", "cases"
            ])
        _ = try exactObject(
            root["anonymization"],
            label: "private fixture anonymization",
            keys: [
                "policy", "reviewStatus", "containsAudio",
                "containsFilePaths", "containsAccountIdentifiers",
                "containsDirectIdentifiers"
            ])
        guard let cases = root["cases"] as? [Any] else {
            throw CommitmentLinkQualityBenchmarkError.invalidFixture(
                "private fixture cases are not an array")
        }
        for (caseIndex, value) in cases.enumerated() {
            let fixtureCase = try exactObject(
                value,
                label: "private fixture case \(caseIndex)",
                keys: [
                    "id", "language", "class", "candidate", "targets",
                    "expected"
                ])
            let candidate = try exactObject(
                fixtureCase["candidate"],
                label: "private fixture candidate \(caseIndex)",
                keys: [
                    "sourceMeetingID", "actionItemID", "language", "text",
                    "assignee"
                ])
            try validateExactAssignee(
                candidate["assignee"],
                label: "private fixture candidate assignee \(caseIndex)")
            _ = try exactObject(
                fixtureCase["expected"],
                label: "private fixture expected \(caseIndex)",
                keys: [
                    "semanticRelevantCommitmentIDs", "linkableCommitmentIDs",
                    "mustAbstain"
                ])
            guard let targets = fixtureCase["targets"] as? [Any] else {
                throw CommitmentLinkQualityBenchmarkError.invalidFixture(
                    "private fixture targets are not an array")
            }
            for (targetIndex, targetValue) in targets.enumerated() {
                let target = try exactObject(
                    targetValue,
                    label: "private fixture target \(caseIndex).\(targetIndex)",
                    keys: [
                        "id", "title", "status", "assignee",
                        "sourceMeetingIDs", "evidence"
                    ])
                try validateExactAssignee(
                    target["assignee"],
                    label: "private fixture target assignee \(caseIndex).\(targetIndex)")
                guard let evidence = target["evidence"] as? [Any] else {
                    throw CommitmentLinkQualityBenchmarkError.invalidFixture(
                        "private fixture evidence is not an array")
                }
                for (evidenceIndex, evidenceValue) in evidence.enumerated() {
                    _ = try exactObject(
                        evidenceValue,
                        label: "private fixture evidence \(caseIndex).\(targetIndex).\(evidenceIndex)",
                        keys: ["id", "meetingID", "language", "text"])
                }
            }
        }
    }

    private static func validateExactAssignee(
        _ value: Any?,
        label: String
    ) throws {
        _ = try exactObject(
            value,
            label: label,
            keys: ["kind", "id"])
    }

    private static func exactObject(
        _ value: Any?,
        label: String,
        keys: Set<String>
    ) throws -> [String: Any] {
        guard let object = value as? [String: Any],
              Set(object.keys) == keys
        else {
            throw CommitmentLinkQualityBenchmarkError.invalidFixture(
                "\(label) is not exact")
        }
        return object
    }
}

private enum CommitmentLinkPrivateFixtureFilePolicy {
    static func validate(_ url: URL) throws {
        let values: URLResourceValues
        let attributes: [FileAttributeKey: Any]
        do {
            values = try url.resourceValues(forKeys: [
                .isRegularFileKey, .isSymbolicLinkKey
            ])
            attributes = try FileManager.default.attributesOfItem(
                atPath: url.path)
        } catch {
            throw CommitmentLinkQualityBenchmarkError.invalidFixture(
                "private fixture metadata cannot be inspected")
        }
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              permissions == 0o600
        else {
            throw CommitmentLinkQualityBenchmarkError.invalidFixture(
                "private fixture must be a regular non-symlink mode-0600 file")
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

private extension CommitmentLinkQualityFixture {
    static let privateClassCounts = [
        "continuation": 12,
        "ambiguous": 3,
        "self-continuation": 3,
        "wrong-person": 3,
        "no-overlap": 3,
        "same-meeting": 3,
        "inactive-target": 3,
        "dismissed-target": 3,
        "unknown-owner": 3,
    ]

    func validatePrivateContract() throws {
        guard schemaVersion == 1,
              kind == CommitmentLinkPrivateQualityFixture.kind,
              generation.hasPrefix("private-anonymized-"),
              Self.isSafePrivateIdentifier(generation),
              contentSource == CommitmentLinkPrivateQualityFixture.contentSource,
              cases.count == 36
        else {
            throw CommitmentLinkQualityBenchmarkError.invalidFixture(
                "private fixture schema or generation is invalid")
        }
        try validateCases()

        let languageCounts = Dictionary(
            grouping: cases,
            by: \.language).mapValues(\.count)
        let classCounts = Dictionary(
            grouping: cases,
            by: \.`class`).mapValues(\.count)
        let linkableCount = cases.filter {
            !$0.expected.linkableCommitmentIDs.isEmpty
        }.count
        guard languageCounts == ["en": 12, "es": 12, "mixed": 12],
              classCounts == Self.privateClassCounts,
              linkableCount == 18,
              cases.filter(\.expected.mustAbstain).count == 18
        else {
            throw CommitmentLinkQualityBenchmarkError.invalidFixture(
                "private fixture balance is invalid")
        }
        for fixtureCase in cases {
            try Self.validatePrivateCase(fixtureCase)
        }
    }

    static func validatePrivateCase(
        _ fixtureCase: CommitmentLinkQualityCase
    ) throws {
        let candidate = fixtureCase.candidate
        guard isSafePrivateIdentifier(fixtureCase.id),
              isSafePrivateIdentifier(candidate.sourceMeetingID),
              isSafePrivateIdentifier(candidate.actionItemID)
        else {
            throw CommitmentLinkQualityBenchmarkError.invalidFixture(
                "private fixture contains an unsafe identity")
        }
        try validatePrivateAssignee(candidate.assignee)
        try validatePrivateText(candidate.text)

        let targets = Dictionary(
            uniqueKeysWithValues: fixtureCase.targets.map { ($0.id, $0) })
        for target in fixtureCase.targets {
            guard isSafePrivateIdentifier(target.id),
                  target.sourceMeetingIDs.allSatisfy(isSafePrivateIdentifier)
            else {
                throw CommitmentLinkQualityBenchmarkError.invalidFixture(
                    "private fixture contains an unsafe target identity")
            }
            try validatePrivateAssignee(target.assignee)
            try validatePrivateText(target.title)
            for evidence in target.evidence {
                guard isSafePrivateIdentifier(evidence.id),
                      isSafePrivateIdentifier(evidence.meetingID),
                      ["en", "es", "mixed"].contains(evidence.language)
                else {
                    throw CommitmentLinkQualityBenchmarkError.invalidFixture(
                        "private fixture contains invalid evidence")
                }
                try validatePrivateText(evidence.text)
            }
        }
        for targetID in fixtureCase.expected.linkableCommitmentIDs {
            guard let target = targets[targetID],
                  target.status == "confirmed",
                  candidate.assignee.kind != "unassigned",
                  candidate.assignee == target.assignee,
                  !target.sourceMeetingIDs.contains(candidate.sourceMeetingID)
            else {
                throw CommitmentLinkQualityBenchmarkError.invalidFixture(
                    "private fixture link truth is not legally admissible")
            }
        }
    }

    static func validatePrivateAssignee(
        _ assignee: CommitmentLinkQualityAssignee
    ) throws {
        if let id = assignee.id, !isSafePrivateIdentifier(id) {
            throw CommitmentLinkQualityBenchmarkError.invalidFixture(
                "private fixture contains an unsafe assignee identity")
        }
    }

    static func validatePrivateText(_ value: String) throws {
        guard value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty,
              value.count <= 500,
              !value.contains("\0")
        else {
            throw CommitmentLinkQualityBenchmarkError.invalidFixture(
                "private fixture contains invalid text")
        }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        for (label, expression) in privateTextPatterns
        where expression.firstMatch(in: value, range: range) != nil {
            throw CommitmentLinkQualityBenchmarkError.invalidFixture(
                "private fixture contains an obvious \(label)")
        }
    }

    static func isSafePrivateIdentifier(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard (1...96).contains(bytes.count),
              let first = bytes.first,
              isLowercaseASCII(first) || isDigitASCII(first)
        else { return false }
        return bytes.allSatisfy {
            isLowercaseASCII($0) || isDigitASCII($0)
                || $0 == 46 || $0 == 95 || $0 == 45
        }
    }

    static func isLowercaseASCII(_ byte: UInt8) -> Bool {
        (97...122).contains(byte)
    }

    static func isDigitASCII(_ byte: UInt8) -> Bool {
        (48...57).contains(byte)
    }

    static let privateTextPatterns: [(String, NSRegularExpression)] = [
        ("email address", try! NSRegularExpression(
            pattern: #"\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b"#,
            options: [.caseInsensitive])),
        ("URL", try! NSRegularExpression(
            pattern: #"(?:https?://|\bwww\.)"#,
            options: [.caseInsensitive])),
        ("filesystem path", try! NSRegularExpression(
            pattern: #"(?:/Users/|/home/|[A-Z]:\\)"#,
            options: [.caseInsensitive])),
        ("UUID", try! NSRegularExpression(
            pattern: #"\b[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\b"#,
            options: [.caseInsensitive])),
        ("phone-like number", try! NSRegularExpression(
            pattern: #"(?<!\w)(?:\+?\d[\s().-]*){8,}(?!\w)"#)),
    ]
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

/// Owner-only field evidence. This separate envelope keeps private provenance
/// explicit and carries no candidate, target, or evidence source text.
struct CommitmentLinkPrivateSimilarityDocument: Encodable, Sendable {
    let schemaVersion = 1
    let kind = "commitment-link-private-similarity-observations"
    let fixtureGeneration: String
    let fixtureSHA256: String
    let contentSource: String
    let anonymization: CommitmentLinkPrivateAnonymization
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

    static func runPrivateSimilarity(
        fixture: CommitmentLinkPrivateQualityFixture,
        runtime: any SemanticEmbeddingRuntimeClient,
        build: String,
        commit: String,
        allowAssetDownload: Bool = false
    ) async throws -> CommitmentLinkPrivateSimilarityDocument {
        guard CommitmentLinkBenchmarkIdentity.isSafeBuild(build) else {
            throw CommitmentLinkQualityBenchmarkError.invalidBuild
        }
        guard CommitmentLinkBenchmarkIdentity.isCommit(commit) else {
            throw CommitmentLinkQualityBenchmarkError.invalidCommit
        }
        let productRun = try await observeProductPath(
            fixture: fixture.productFixture,
            runtime: runtime,
            allowAssetDownload: allowAssetDownload)
        return CommitmentLinkPrivateSimilarityDocument(
            fixtureGeneration: fixture.generation,
            fixtureSHA256: fixture.fixtureSHA256,
            contentSource: CommitmentLinkPrivateQualityFixture.contentSource,
            anonymization: fixture.anonymization,
            adapter: "product-accelerate-exact-private-scored-v1",
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

enum CommitmentLinkPrivateSimilarityJSONWriter {
    static func write(
        _ document: CommitmentLinkPrivateSimilarityDocument,
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
