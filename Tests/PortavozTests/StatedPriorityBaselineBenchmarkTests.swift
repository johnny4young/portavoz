import Foundation
import Testing
@testable import PortavozCLIKit

struct StatedPriorityBaselineBenchmarkTests {
    private static let fixtureURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/StatedPriorityQuality/public-synthetic-v1.json")

    @Test func developmentRunsWithoutUnsealing() throws {
        let options = try StatedPriorityBaselineOptions(arguments: [
            "--fixture", "/tmp/fixture.json", "--split", "development"
        ])

        #expect(options.split == "development")
        #expect(options.output == nil)
    }

    @Test func evaluationIsRefusedWithoutUnseal() {
        #expect(throws: StatedPriorityBaselineError.sealedSplit) {
            try StatedPriorityBaselineOptions(arguments: ["--fixture", "/tmp/fixture.json", "--split", "evaluation"])
        }
    }

    @Test func evaluationRunsOnlyWhenUnsealedExplicitly() throws {
        let options = try StatedPriorityBaselineOptions(arguments: [
            "--fixture", "/tmp/fixture.json", "--split", "evaluation", "--unseal"
        ])

        #expect(options.split == "evaluation")
    }

    @Test func ambiguousArgumentsAreRefused() {
        #expect(throws: StatedPriorityBaselineError.invalidSplit("all")) {
            try StatedPriorityBaselineOptions(arguments: ["--fixture", "/tmp/f.json", "--split", "all"])
        }
        #expect(throws: StatedPriorityBaselineError.duplicateOption("--split")) {
            try StatedPriorityBaselineOptions(arguments: [
                "--fixture", "/tmp/f.json", "--split", "development", "--split", "development"
            ])
        }
        #expect(throws: StatedPriorityBaselineError.unknownOption("--labels")) {
            try StatedPriorityBaselineOptions(arguments: ["--fixture", "/tmp/f.json", "--labels", "gold"])
        }
        #expect(throws: StatedPriorityBaselineError.outputMatchesFixture) {
            try StatedPriorityBaselineOptions(arguments: [
                "--fixture", "/tmp/f.json", "--split", "development", "--output", "/tmp/f.json"
            ])
        }
    }

    /// The digest the Python evaluator computes for the same document.
    @Test func canonicalDigestMatchesTheEvaluator() throws {
        let document = Data(#"{"b": [1, true, null], "a": "Señal / “x”", "c": {"z": 0, "y": "é"}}"#.utf8)

        #expect(try StatedPriorityQualityFixture.canonicalDigest(for: document)
            == "a6580d3516c4575713ad79183bf384adf7846bd815babb01a1985fef2a08dc4e")
    }

    @Test func developmentRoundTripEmitsGroundedObservations() throws {
        let fixture = try StatedPriorityQualityFixture.load(from: Self.fixtureURL)
        let document = StatedPriorityBaselineBenchmark.observations(fixture: fixture, split: "development")
        let development = try Self.developmentCases()

        #expect(document.fixtureSHA256 == StatedPriorityQualityFixture.canonicalDigest)
        #expect(document.arm == "linguistic-baseline-v1")
        #expect(document.observations.map(\.id) == development.map(\.id))
        for (observation, raw) in zip(document.observations, development) {
            let texts = Dictionary(uniqueKeysWithValues: raw.captions.map { ($0.id, $0.text) })
            if observation.decision == "abstain" {
                #expect(observation.reason != nil && observation.target == nil && observation.evidence.isEmpty)
                continue
            }
            #expect(observation.reason == nil)
            #expect(observation.evidence.contains(
                StatedPriorityObservationSpan(captionID: raw.focusCaptionID, quote: raw.focusSentence)))
            for span in observation.evidence {
                #expect(texts[span.captionID]?.components(separatedBy: span.quote).count == 2)
            }
            #expect(observation.decision != "priority" || raw.gold == "priority", "\(raw.id) promoted unsafely")
        }
    }

    @Test func encodedObservationsSpellOutNulls() throws {
        let document = StatedPriorityObservationsDocument(
            schemaVersion: 1, kind: "stated-priority-observations", fixtureSHA256: "0", split: "development",
            arm: "linguistic-baseline-v1",
            observations: [StatedPriorityObservation(
                id: "x", decision: "abstain", reason: "classified-neutral", target: nil, evidence: [])])
        let json = try #require(String(data: StatedPriorityBaselineBenchmark.encoded(document), encoding: .utf8))

        #expect(json.contains(#""probabilities":null"#))
        #expect(json.contains(#""target":null"#))
    }

    private struct RawCase {
        let id: String
        let gold: String
        let focusCaptionID: String
        let focusSentence: String
        let captions: [(id: String, text: String)]
    }

    /// Reads only development cases, so the sealed split is never inspected.
    private static func developmentCases() throws -> [RawCase] {
        let root = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: fixtureURL)) as? [String: Any])
        let cases = try #require(root["cases"] as? [[String: Any]])
        return try cases.filter { $0["split"] as? String == "development" }.map { value in
            let focus = try #require(value["focus"] as? [String: Any])
            let gold = try #require(value["gold"] as? [String: Any])
            let captions = try #require(value["captions"] as? [[String: Any]])
            return RawCase(
                id: try #require(value["id"] as? String),
                gold: try #require(gold["label"] as? String),
                focusCaptionID: try #require(focus["captionID"] as? String),
                focusSentence: try #require(focus["sentence"] as? String),
                captions: try captions.map {
                    (try #require($0["id"] as? String), try #require($0["text"] as? String))
                })
        }
    }
}
