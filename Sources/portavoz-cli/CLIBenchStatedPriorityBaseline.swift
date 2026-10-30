import CryptoKit
import Foundation
import IntelligenceKit

/// Emits `stated-priority-observations` for one split of the public corpus from
/// the linguistic baseline. Research only: nothing here serves a priority.
enum BenchStatedPriorityBaselineCommand {
    static func run(_ arguments: [String]) {
        do {
            let options = try StatedPriorityBaselineOptions(arguments: arguments)
            let fixture = try StatedPriorityQualityFixture.load(from: options.fixture)
            let document = StatedPriorityBaselineBenchmark.observations(fixture: fixture, split: options.split)
            let data = try StatedPriorityBaselineBenchmark.encoded(document)
            if let output = options.output {
                try data.write(to: output, options: .withoutOverwriting)
            } else {
                FileHandle.standardOutput.write(data)
            }
        } catch {
            FileHandle.standardError.write(
                Data("bench-stated-priority-baseline error: \(error.localizedDescription)\n".utf8))
            Foundation.exit(64)
        }
    }
}

enum StatedPriorityBaselineError: Error, Equatable, LocalizedError {
    case unknownOption(String)
    case missingOption(String)
    case missingOptionValue(String)
    case duplicateOption(String)
    case invalidSplit(String)
    case sealedSplit
    case outputMatchesFixture
    case invalidFixture(String)

    var errorDescription: String? {
        switch self {
        case .unknownOption(let option): "unknown option \(option)"
        case .missingOption(let option): "\(option) is required"
        case .missingOptionValue(let option): "\(option) needs a value"
        case .duplicateOption(let option): "\(option) was given twice"
        case .invalidSplit(let split): "split must be development or evaluation, not \(split)"
        case .sealedSplit: "the evaluation split is sealed; pass --unseal only for the frozen policy's sealed run"
        case .outputMatchesFixture: "--output must not be the fixture"
        case .invalidFixture(let reason): reason
        }
    }
}

struct StatedPriorityBaselineOptions: Equatable {
    static let splits: Set<String> = ["development", "evaluation"]

    let fixture: URL
    let split: String
    let output: URL?

    init(arguments: [String]) throws {
        var values: [String: String] = [:]
        var unseal = false
        var index = 0
        while index < arguments.count {
            let option = arguments[index]
            index += 1
            if option == "--unseal" {
                guard !unseal else { throw StatedPriorityBaselineError.duplicateOption(option) }
                unseal = true
                continue
            }
            guard ["--fixture", "--split", "--output"].contains(option) else {
                throw StatedPriorityBaselineError.unknownOption(option)
            }
            guard arguments.indices.contains(index) else {
                throw StatedPriorityBaselineError.missingOptionValue(option)
            }
            guard values.updateValue(arguments[index], forKey: option) == nil else {
                throw StatedPriorityBaselineError.duplicateOption(option)
            }
            index += 1
        }
        guard let fixture = values["--fixture"], !fixture.isEmpty else {
            throw StatedPriorityBaselineError.missingOption("--fixture")
        }
        guard let split = values["--split"] else { throw StatedPriorityBaselineError.missingOption("--split") }
        guard Self.splits.contains(split) else { throw StatedPriorityBaselineError.invalidSplit(split) }
        guard split == "development" || unseal else { throw StatedPriorityBaselineError.sealedSplit }
        self.fixture = URL(fileURLWithPath: fixture).standardizedFileURL
        self.split = split
        output = values["--output"].map { URL(fileURLWithPath: $0).standardizedFileURL }
        guard output != self.fixture else { throw StatedPriorityBaselineError.outputMatchesFixture }
    }
}

/// Decodes only what an arm may see: captions and focus. Gold labels,
/// evidence, tags, and annotations are never read into memory.
struct StatedPriorityQualityFixture: Decodable, Sendable {
    static let canonicalDigest = "9cca13ea3eb28cd87627bdae2648dd967be76dde40a41323f3d2f5a2fa127885"

    struct Caption: Decodable, Sendable {
        let id: String
        let text: String
    }

    struct Focus: Decodable, Sendable {
        let captionID: String
        let sentence: String
        let mention: String?
    }

    struct Case: Decodable, Sendable {
        let id: String
        let split: String
        let captions: [Caption]
        let focus: Focus
    }

    let schemaVersion: Int
    let kind: String
    let generation: String
    let contentSource: String
    let cases: [Case]
    private(set) var fixtureSHA256 = ""

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, kind, generation, contentSource, cases
    }

    static func load(from url: URL) throws -> Self {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            throw StatedPriorityBaselineError.invalidFixture("fixture cannot be read")
        }
        guard data.count <= 2 * 1_024 * 1_024 else {
            throw StatedPriorityBaselineError.invalidFixture("fixture exceeds 2 MiB")
        }
        let digest = try canonicalDigest(for: data)
        guard digest == canonicalDigest else {
            throw StatedPriorityBaselineError.invalidFixture("fixture does not match the canonical public generation")
        }
        guard var fixture = try? JSONDecoder().decode(Self.self, from: data),
              fixture.schemaVersion == 1, fixture.kind == "stated-priority-quality-fixture",
              fixture.generation == "public-synthetic-v1", fixture.contentSource == "public-synthetic-only",
              fixture.cases.count == 100
        else {
            throw StatedPriorityBaselineError.invalidFixture("unsupported fixture schema or bounds")
        }
        fixture.fixtureSHA256 = digest
        return fixture
    }

    /// The evaluator's digest: sorted keys, compact, non-ASCII kept verbatim.
    static func canonicalDigest(for data: Data) throws -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let canonical = try? JSONSerialization.data(
                withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        else {
            throw StatedPriorityBaselineError.invalidFixture("fixture is not valid JSON")
        }
        return SHA256.hash(data: canonical).map { String(format: "%02x", $0) }.joined()
    }
}

struct StatedPriorityObservationSpan: Encodable, Equatable, Sendable {
    let captionID: String
    let quote: String
}

struct StatedPriorityObservation: Encodable, Equatable, Sendable {
    let id: String
    let decision: String
    let reason: String?
    let target: StatedPriorityObservationSpan?
    let evidence: [StatedPriorityObservationSpan]

    private enum CodingKeys: String, CodingKey {
        case id, decision, reason, target, evidence, probabilities
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(decision, forKey: .decision)
        try container.encode(reason, forKey: .reason)
        try container.encode(target, forKey: .target)
        try container.encode(evidence, forKey: .evidence)
        // The baseline is deterministic and claims no calibrated probability.
        try container.encodeNil(forKey: .probabilities)
    }
}

struct StatedPriorityObservationsDocument: Encodable, Equatable, Sendable {
    let schemaVersion: Int
    let kind: String
    let fixtureSHA256: String
    let split: String
    let arm: String
    let observations: [StatedPriorityObservation]
}

enum StatedPriorityBaselineBenchmark {
    static func observations(
        fixture: StatedPriorityQualityFixture, split: String
    ) -> StatedPriorityObservationsDocument {
        let classifier = StatedPriorityClassifier()
        let observations = fixture.cases.filter { $0.split == split }.map { fixtureCase in
            let reading = classifier.classify(
                captions: fixtureCase.captions.map { StatedPriorityCaption(id: $0.id, text: $0.text) },
                focus: StatedPriorityFocus(
                    captionID: fixtureCase.focus.captionID,
                    sentence: fixtureCase.focus.sentence,
                    mention: fixtureCase.focus.mention))
            let span = { (span: StatedPrioritySpan) in
                StatedPriorityObservationSpan(captionID: span.captionID, quote: span.quote)
            }
            return StatedPriorityObservation(
                id: fixtureCase.id,
                decision: reading.decision.rawValue,
                reason: reading.abstention?.rawValue,
                target: reading.target.map(span),
                evidence: reading.evidence.map(span))
        }
        return StatedPriorityObservationsDocument(
            schemaVersion: 1,
            kind: "stated-priority-observations",
            fixtureSHA256: fixture.fixtureSHA256,
            split: split,
            arm: StatedPriorityClassifier.arm,
            observations: observations)
    }

    static func encoded(_ document: StatedPriorityObservationsDocument) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(document) + Data("\n".utf8)
    }
}
