import Foundation
import IntelligenceKit
import ModelStoreKit
import XCTest

@testable import portavoz_app

@MainActor
final class LiveAssistValidationRunnerTests: XCTestCase {
    func testMLXSmokeModelSelectionIsExactAndFailsOnAmbiguity() async throws {
        XCTAssertEqual(
            try BenchMode.mlxSmokeDescriptor(arguments: []).id,
            ModelCatalog.mlxQwen35.id)
        XCTAssertEqual(
            try BenchMode.mlxSmokeDescriptor(arguments: ["qwen35-0.8b"]).id,
            ModelCatalog.mlxQwen35Point8BChallenger.id)
        XCTAssertEqual(
            try BenchMode.mlxSmokeDescriptor(arguments: ["qwen35-2b"]).id,
            ModelCatalog.mlxQwen35TwoBChallenger.id)
        XCTAssertThrowsError(try BenchMode.mlxSmokeDescriptor(
            arguments: ["qwen35-0.8b", "qwen35-2b"])) { error in
                XCTAssertEqual(
                    error as? BenchMode.MLXSmokeSelectionError,
                    .conflictingModels)
            }
    }

    func testConfigurationIsStrictAndKeepsInstalledModelOptInExplicit() async throws {
        let arguments = validArguments()
        let configuration = try XCTUnwrap(
            LiveAssistValidationConfiguration.requested(arguments: arguments))
        XCTAssertEqual(configuration.adapter, .releasedPrefilter)
        XCTAssertEqual(configuration.iterations, 5)
        XCTAssertEqual(configuration.sourceState, "dirty")

        XCTAssertThrowsError(
            try LiveAssistValidationConfiguration.requested(
                arguments: arguments + ["--live-assist-output", "/tmp/other"])
        ) { error in
            XCTAssertEqual(error as? LiveAssistValidationError, .invalidArguments)
        }
        XCTAssertThrowsError(
            try LiveAssistValidationConfiguration.requested(
                arguments: replacing(
                    "released-prefilter",
                    with: "automatic",
                    in: arguments))
        ) { error in
            XCTAssertEqual(error as? LiveAssistValidationError, .invalidAdapter)
        }
    }

    func testFrozenFixtureFeedsExactReleasedPoliciesWithoutExpectedOutputs() async throws {
        let fixture = try LiveAssistValidationFixture.load(from: fixtureURL)
        let oracle = try JSONDecoder().decode(
            LiveAssistValidationOracle.self,
            from: Data(contentsOf: fixtureURL))

        let interviews = LiveAssistValidationPolicy.interviews(
            fixture.interviewScenarios)
        let summaries = LiveAssistValidationPolicy.summaries(
            fixture.rollingSummaryScenarios)
        let translations = LiveAssistValidationPolicy.translations(
            fixture.translationScenarios)

        XCTAssertEqual(
            interviews,
            oracle.interviewScenarios.map {
                .init(
                    scenarioID: $0.id,
                    questionID: $0.expectedQuestionID?.liveAssistReceiptID,
                    evidenceIDs: $0.expectedEvidenceIDs.map(\.liveAssistReceiptID))
            })
        XCTAssertEqual(summaries.count, oracle.rollingSummaryScenarios.count)
        for (summary, expected) in zip(
            summaries,
            oracle.rollingSummaryScenarios
        ) {
            let selected = expected.expectedSelectedIDs.map(\.liveAssistReceiptID)
            XCTAssertEqual(summary.scenarioID, expected.id)
            XCTAssertEqual(summary.selectedIDs, selected)
            XCTAssertEqual(summary.hasBacklog, expected.expectedBacklog)
            XCTAssertEqual(summary.checkpointIDs, selected)
            XCTAssertEqual(summary.checkpointLanguage, expected.language)
            XCTAssertGreaterThan(summary.checkpointCharacterCount, 0)
            XCTAssertLessThanOrEqual(
                summary.checkpointCharacterCount,
                DeterministicLiveSummary.maximumCharacters)
        }
        XCTAssertEqual(translations.count, oracle.translationScenarios.count)
        for (translation, expected) in zip(
            translations,
            oracle.translationScenarios
        ) {
            XCTAssertEqual(translation.scenarioID, expected.id)
            XCTAssertEqual(translation.pair, expected.expectedPair)
            XCTAssertEqual(
                translation.pendingIDs,
                expected.expectedPendingIDs.map(\.liveAssistReceiptID))
            XCTAssertEqual(translation.installedAssetAction, "translate")
            XCTAssertEqual(
                translation.downloadableAssetAction,
                "requestDownloadConsent")
            XCTAssertEqual(
                translation.retryDelaysMilliseconds,
                [1_000, 2_000, 4_000, 8_000, 8_000])
            XCTAssertEqual(translation.invalidPublicationCount, 0)
        }
    }

    func testReleasedRunnerWritesContentFreeNonReplacingObservation() async throws {
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PortavozLiveAssist-\(UUID().uuidString)",
            isDirectory: true)
        try FileManager.default.createDirectory(
            at: workspace,
            withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let output = workspace.appendingPathComponent("observations.json")
        let configuration = LiveAssistValidationConfiguration(
            fixtureURL: fixtureURL,
            outputURL: output,
            adapter: .releasedPrefilter,
            commit: String(repeating: "a", count: 40),
            build: "debug-tests",
            sourceState: "dirty",
            iterations: 5)

        try await LiveAssistValidationRunner.run(configuration: configuration)

        let data = try Data(contentsOf: output)
        let observations = try JSONDecoder().decode(
            LiveAssistValidationObservations.self,
            from: data)
        XCTAssertEqual(observations.questionEvents.count, 32)
        XCTAssertEqual(observations.interviewScenarios.count, 7)
        XCTAssertEqual(observations.rollingSummaryScenarios.count, 5)
        XCTAssertEqual(observations.translationScenarios.count, 6)
        XCTAssertEqual(observations.faultScenarios.count, 8)
        XCTAssertEqual(
            observations.faultScenarios.map(\.latePublicationCount),
            Array(repeating: 0, count: 8))
        XCTAssertEqual(observations.resources.iterations, 5)
        XCTAssertGreaterThanOrEqual(
            observations.resources.peakPhysicalFootprintBytes,
            max(
                observations.resources.initialPhysicalFootprintBytes,
                observations.resources.finalPhysicalFootprintBytes))
        XCTAssertEqual(try permissions(of: output), 0o600)

        let encoded = try XCTUnwrap(String(data: data, encoding: .utf8))
        let fixture = try LiveAssistValidationFixture.load(from: fixtureURL)
        let firstEventID = try XCTUnwrap(
            fixture.questionSessions.first?.events.first?.id)
        XCTAssertTrue(encoded.contains(firstEventID.liveAssistReceiptID))
        XCTAssertFalse(encoded.contains(firstEventID.uuidString))
        let raw = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        let rawInterviews = try XCTUnwrap(
            raw["interviewScenarios"] as? [[String: Any]])
        let rawTranslations = try XCTUnwrap(
            raw["translationScenarios"] as? [[String: Any]])
        let rawSummaries = try XCTUnwrap(
            raw["rollingSummaryScenarios"] as? [[String: Any]])
        XCTAssertTrue(rawInterviews.allSatisfy { $0.keys.contains("questionID") })
        XCTAssertTrue(rawInterviews.contains { $0["questionID"] is NSNull })
        XCTAssertTrue(rawTranslations.allSatisfy { $0.keys.contains("pair") })
        XCTAssertTrue(rawTranslations.contains { $0["pair"] is NSNull })
        XCTAssertTrue(rawSummaries.allSatisfy {
            $0.keys.contains("checkpointIDs")
                && $0.keys.contains("checkpointCharacterCount")
        })
        XCTAssertTrue(rawTranslations.allSatisfy {
            $0.keys.contains("retryDelaysMilliseconds")
                && $0.keys.contains("invalidPublicationCount")
        })
        for forbidden in [
            "Could you explain",
            "El presupuesto",
            "referenceSummary",
            "expectedDecision",
            "answerText",
        ] {
            XCTAssertFalse(encoded.contains(forbidden), forbidden)
        }
        await XCTAssertThrowsErrorAsync(
            try await LiveAssistValidationRunner.run(
                configuration: configuration),
            expected: .outputAlreadyExists)
    }

    func testPreServiceBenchModesNeverConstructAppServices() async {
        for flag in ["--bench-live", "--mlx-smoke", "--bench-live-assist"] {
            var constructionCount = 0
            let model = AppLaunchModel(
                arguments: ["Portavoz", flag],
                environment: [:],
                servicesFactory: {
                    constructionCount += 1
                    throw LiveAssistValidationError.invalidArguments
                })
            XCTAssertEqual(constructionCount, 0, flag)
            XCTAssertNil(model.services, flag)
            guard case .opening = model.phase else {
                return XCTFail("\(flag) must keep the ordinary app shell unopened")
            }
        }
        XCTAssertFalse(BenchMode.runsBeforeAppServices(arguments: ["Portavoz"]))
    }

    private var fixtureURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(
                "Fixtures/LiveAssistValidation/public-bilingual-v1.json")
    }

    private func validArguments() -> [String] {
        [
            "Portavoz",
            "--bench-live-assist",
            "--live-assist-fixture", fixtureURL.path,
            "--live-assist-output", "/tmp/live-assist.json",
            "--live-assist-adapter", "released-prefilter",
            "--live-assist-commit", String(repeating: "a", count: 40),
            "--live-assist-build", "debug-tests",
            "--live-assist-source-state", "dirty",
        ]
    }

    private func replacing(
        _ value: String,
        with replacement: String,
        in arguments: [String]
    ) -> [String] {
        arguments.map { $0 == value ? replacement : $0 }
    }

    private func permissions(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(
            atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    private func XCTAssertThrowsErrorAsync(
        _ operation: @autoclosure () async throws -> Void,
        expected: LiveAssistValidationError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await operation()
            XCTFail("Expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(
                error as? LiveAssistValidationError,
                expected,
                file: file,
                line: line)
        }
    }
}

private struct LiveAssistValidationOracle: Decodable {
    struct Interview: Decodable {
        let id: String
        let expectedQuestionID: UUID?
        let expectedEvidenceIDs: [UUID]
    }

    struct Summary: Decodable {
        let id: String
        let language: String
        let expectedSelectedIDs: [UUID]
        let expectedBacklog: Bool
    }

    struct Translation: Decodable {
        let id: String
        let expectedPair: LiveAssistValidationLanguagePair?
        let expectedPendingIDs: [UUID]
    }

    let interviewScenarios: [Interview]
    let rollingSummaryScenarios: [Summary]
    let translationScenarios: [Translation]
}
