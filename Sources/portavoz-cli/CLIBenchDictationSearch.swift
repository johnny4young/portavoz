import ApplicationKit
import CryptoKit
import Foundation
import IntelligenceKit
import PortavozCore
import StorageKit

/// Dictation search evidence over the public bilingual corpus: the shipped
/// lexical ranking and a semantic ranking with similarities, plus latency and
/// memory at scale. The output holds identities and numbers, never text;
/// `scripts/dictation_search_quality.py` derives the hybrid and the verdict.
enum BenchDictationSearchCommand {
    static func run(_ arguments: [String]) async {
        do {
            let options = try DictationSearchBenchmarkOptions(arguments: arguments)
            let embedder = try SentenceEmbedder()
            try await embedder.prepare(allowAssetDownload: options.allowAssetDownload)
            let observations = try await DictationSearchBenchmark.observe(
                fixtureData: try Data(contentsOf: options.fixture),
                embedding: embedder,
                build: options.build,
                commit: options.commit,
                scales: options.scales)
            try CLIPrivateJSONWriter.write(observations, to: options.output)
            print("Dictation search observations: \(options.output.path)")
        } catch {
            FileHandle.standardError.write(Data("bench-dictation-search error: \(error.localizedDescription)\n".utf8))
            Foundation.exit(64)
        }
    }
}

enum DictationSearchBenchmarkError: Error, Equatable, LocalizedError {
    case invalidArguments(String)
    case invalidFixture
    case invalidEmbedding

    var errorDescription: String? {
        switch self {
        case .invalidArguments(let reason): "invalid arguments: \(reason)"
        case .invalidFixture: "invalid fixture"
        case .invalidEmbedding: "the embedding returned an unusable vector"
        }
    }
}

struct DictationSearchBenchmarkOptions: Equatable {
    let fixture: URL
    let output: URL
    let build: String
    let commit: String
    let allowAssetDownload: Bool
    let scales: [Int]

    init(arguments: [String]) throws {
        var values: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            let key = arguments[index]
            guard ["--fixture", "--output", "--build", "--commit", "--asset-download", "--scales"].contains(key),
                  index + 1 < arguments.count, values[key] == nil
            else { throw DictationSearchBenchmarkError.invalidArguments("unknown or repeated option") }
            values[key] = arguments[index + 1]
            index += 2
        }
        guard let fixture = values["--fixture"], let output = values["--output"], fixture != output,
              let build = values["--build"], (1...80).contains(build.count),
              build.allSatisfy({ $0.isLetter || $0.isNumber || ".+_-".contains($0) }),
              let commit = values["--commit"], commit.utf8.count == 40,
              commit.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
        else { throw DictationSearchBenchmarkError.invalidArguments("fixture, output, build and commit are required") }
        let download = values["--asset-download"] ?? "never"
        guard ["never", "if-needed"].contains(download) else {
            throw DictationSearchBenchmarkError.invalidArguments("asset download is never or if-needed")
        }
        let scales = (values["--scales"] ?? "1000,10000").split(separator: ",").compactMap { Int($0) }
        guard !scales.isEmpty, scales.allSatisfy({ (1...100_000).contains($0) }) else {
            throw DictationSearchBenchmarkError.invalidArguments("scales are 1 to 100000")
        }
        self.fixture = URL(fileURLWithPath: fixture)
        self.output = URL(fileURLWithPath: output)
        self.build = build
        self.commit = commit
        self.allowAssetDownload = download == "if-needed"
        self.scales = scales
    }
}

struct DictationSearchObservations: Encodable, Equatable {
    struct Hit: Encodable, Equatable {
        let id: String
        let similarity: Double
    }

    struct Query: Encodable, Equatable {
        let id: String
        let lexical: [String]
        let semantic: [Hit]
        /// The same scan after subtracting the corpus mean vector and renormalizing.
        let semanticCentered: [Hit]
        /// The shipped retrieval, which adds the meeting Ask rewrites, and a
        /// research lane with a dictation-specific rewrite. nil without Foundation Models.
        let lexicalExpandedMeeting: [String]?
        let lexicalExpandedDictation: [String]?
    }

    struct Percentiles: Encodable, Equatable {
        let p50: Double
        let p95: Double
    }

    struct Scale: Encodable, Equatable {
        let dictations: Int
        let lexicalP95Milliseconds: Double
        let semanticP95Milliseconds: Double
        let vectorBytes: Int
    }

    struct Resources: Encodable, Equatable {
        let dictationCount: Int
        let embedMilliseconds: Percentiles
        let lexicalQueryMilliseconds: Percentiles
        let semanticQueryMilliseconds: Percentiles
        /// Questions the shipped parser read a period or app from; the corpus keeps it at zero.
        let queriesWithParsedFilters: Int
        let expansionMeetingMilliseconds: Percentiles?
        let expansionDictationMilliseconds: Percentiles?
        /// Rewrites refused or failed (a guardrail, for example); those questions search unexpanded.
        let expansionDictationFailures: Int
        let scale: [Scale]
    }

    var schemaVersion = 1
    var kind = "dictation-search-observations"
    let fixtureSHA256: String
    let build: String
    let commit: String
    let embeddingProfileFingerprint: String
    let dimension: Int
    let queries: [Query]
    let resources: Resources
}
