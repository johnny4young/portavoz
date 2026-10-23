import ApplicationKit
import Foundation
import PortavozCore
import XCTest
@testable import PortavozCLIKit

final class DictationSearchBenchmarkTests: XCTestCase {
    func testOptionsRequireIdentityAndBoundedScales() throws {
        let options = try DictationSearchBenchmarkOptions(arguments: [
            "--fixture", "/tmp/f.json", "--output", "/tmp/o.json", "--build", "dev-1",
            "--commit", String(repeating: "a", count: 40), "--scales", "100,2000"
        ])
        XCTAssertFalse(options.allowAssetDownload)
        XCTAssertEqual(options.scales, [100, 2000])
        for arguments in [
            ["--fixture", "/tmp/f.json", "--output", "/tmp/f.json", "--build", "b", "--commit", String(repeating: "a", count: 40)],
            ["--fixture", "/tmp/f.json", "--output", "/tmp/o.json", "--build", "b", "--commit", "abc"],
            ["--fixture", "/tmp/f.json", "--output", "/tmp/o.json", "--build", "b",
             "--commit", String(repeating: "a", count: 40), "--asset-download", "always"]
        ] {
            XCTAssertThrowsError(try DictationSearchBenchmarkOptions(arguments: arguments))
        }
    }

    func testObservationsCoverEveryQueryWithIdentitiesAndNumbersOnly() async throws {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/DictationSearch/public-synthetic-v1.json")
        let data = try Data(contentsOf: fixtureURL)
        let fixture = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let queries = try XCTUnwrap(fixture?["queries"] as? [[String: Any]])
        let dictations = try XCTUnwrap(fixture?["dictations"] as? [[String: Any]])

        let observations = try await DictationSearchBenchmark.observe(
            fixtureData: data, embedding: HashedWordEmbedding(), build: "test",
            commit: String(repeating: "b", count: 40), scales: [200], rewrites: false)

        XCTAssertEqual(observations.queries.map(\.id), queries.compactMap { $0["id"] as? String })
        XCTAssertEqual(observations.resources.queriesWithParsedFilters, 0, "the corpus never reads as a period or app")
        XCTAssertEqual(observations.resources.scale.map(\.dictations), [200])
        XCTAssertTrue(observations.queries.allSatisfy { $0.lexicalExpandedMeeting == nil })
        let known = Set(dictations.compactMap { $0["id"] as? String })
        XCTAssertTrue(observations.queries.allSatisfy { query in
            Set(query.lexical).isSubset(of: known) && query.semantic.allSatisfy { known.contains($0.id) }
        })
        let encoded = String(decoding: try JSONEncoder().encode(observations), as: UTF8.self)
        for text in (queries.compactMap { $0["text"] as? String } + dictations.compactMap { $0["text"] as? String }) {
            XCTAssertFalse(encoded.contains(text), "observations carry no text")
        }
    }
}

/// A deterministic bag-of-words vector, enough to exercise ranking without model assets.
private struct HashedWordEmbedding: SemanticTextEmbedding {
    func semanticEmbeddingProfile() async -> SemanticEmbeddingProfile {
        SemanticEmbeddingProfile(
            modelIdentifier: "test.hashed-words", modelRevision: 1, vectorDimension: 32,
            pipelineIdentifier: "bag-of-words", pipelineRevision: 1, vectorSchemaVersion: 1)
    }

    func vectors(for texts: [String]) async throws -> [[Float]] {
        texts.map { text in
            var vector = [Float](repeating: 0, count: 32)
            for word in text.lowercased().split(whereSeparator: { !$0.isLetter }) {
                vector[abs(word.hashValue) % 32] += 1
            }
            let norm = vector.reduce(0) { $0 + $1 * $1 }.squareRoot()
            return norm > 0 ? vector.map { $0 / norm } : [1] + [Float](repeating: 0, count: 31)
        }
    }
}
