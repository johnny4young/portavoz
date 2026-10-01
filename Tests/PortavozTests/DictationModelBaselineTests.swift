import FluidAudio
import Foundation
import ModelStoreKit
import os
import TranscriptionKit
import XCTest

@testable import portavoz_cli

final class DictationModelBaselineTests: XCTestCase {
    private struct CellReceipt: Encodable {
        let caseID: String
        let audioSHA256: String
        let group: String
        let cohort: String
        let shape: String
        let split: String
        let critical: Bool
        let pass: Int
        let repetitions: Int
        let score: DictationModelProbe.Score
        let adapterDeltas: DictationModelProbe.Score
        let inputSeconds: Double
        let firstUpdateSeconds: Double?
        let completionSeconds: Double
        let inputEndSeconds: Double
        let work: ParakeetLiveWorkSample
        let stageAttribution: DictationVendorProbe.Receipt?
    }

    private struct Receipt: Encodable {
        let kind = "dictation-installed-model-observation"
        let schemaVersion = 2
        let corpusSHA256 = DictationModelFixture.sourceDigest
        let manifestSHA256: String
        let modelID: String
        let modelRevision: String
        let modelVerificationSeconds: Double
        let modelLoadSeconds: Double
        let loadState = "new-engine-uncontrolled-coreml-disk-cache"
        let localeMode = "automatic-no-vocabulary"
        let feed = "realtime-100ms-bounded-pcm"
        let qualityMeasured = true
        let controllerMeasured = false
        let verifiedDeliveryMeasured = false
        let memoryMeasured = false
        let backendWindowFailureCoverageMeasured = false
        let repetitions: Int
        let cells: [CellReceipt]
    }

    func testInstalledParakeetOnExplicitPublicCells() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let audio = environment["PORTAVOZ_DICTATION_BASELINE_AUDIO"] else {
            throw XCTSkip("explicit local dictation baseline not requested")
        }
        #if DEBUG
        XCTFail("Real dictation models require Release: vendor DEBUG diagnostics can contain transcript text")
        #else
        do {
            guard let ids = environment["PORTAVOZ_DICTATION_BASELINE_CASES"],
                  let output = environment["PORTAVOZ_DICTATION_BASELINE_OUTPUT"], output.hasPrefix("/"),
                  !FileManager.default.fileExists(atPath: output) else {
                XCTFail("dictation baseline requires selected public cells and new absolute output")
                return
            }
            guard let repetitions = Int(environment["PORTAVOZ_DICTATION_REPETITIONS"] ?? "1"),
                  (1...12).contains(repetitions) else {
                XCTFail("dictation repetitions must be within 1...12")
                return
            }
            let fixture = try DictationModelFixture(
                audioRoot: URL(fileURLWithPath: audio), selectedIDs: ids.components(separatedBy: ","))
            // Verify selected PCM before model compilation/loading, not after it.
            for id in fixture.selectedIDs { _ = try fixture.sequence(id, repetitions: repetitions) }
            let store = ModelStore()
            let descriptor = ModelCatalog.parakeetTdtV3
            let verificationStarted = ContinuousClock.now
            guard let installation = await store.verifiedInstallation(descriptor) else {
                XCTFail("installed Parakeet assets did not pass pinned verification; nothing downloaded")
                return
            }
            let verified = ContinuousClock.now
            let engine = try await ParakeetEngine.load(fromVerifiedDirectory: installation.directory)
            let loaded = ContinuousClock.now
            let attributionModels: AsrModels?
            if environment["PORTAVOZ_DICTATION_ATTRIBUTE_LIVE"] == "1" {
                attributionModels = try await AsrModels.load(
                    from: installation.directory, version: .v3, encoderPrecision: .int8)
            } else {
                attributionModels = nil
            }
            var results: [CellReceipt] = []
            // Two same-process passes measure repeated execution, not independent cold starts.
            for pass in 1...2 {
                for id in fixture.selectedIDs {
                    results.append(try await observe(id: id, pass: pass, fixture: fixture, repetitions: repetitions, engine: engine, attributionModels: attributionModels))
                }
            }
            let receipt = Receipt(
                manifestSHA256: fixture.manifestDigest, modelID: installation.descriptorID,
                modelRevision: installation.descriptorRevision,
                modelVerificationSeconds: DictationModelProbe.seconds(verificationStarted.duration(to: verified)),
                modelLoadSeconds: DictationModelProbe.seconds(verified.duration(to: loaded)), repetitions: repetitions, cells: results)
            try CLIPrivateJSONWriter.write(receipt, to: URL(fileURLWithPath: output))
        } catch {
            // Never ask XCTest to interpolate provider errors or hypothesis text.
            XCTFail("dictation model observation failed; no successful baseline receipt")
        }
        #endif
    }

    private func observe(
        id: String, pass: Int, fixture: DictationModelFixture, repetitions: Int, engine: ParakeetEngine, attributionModels: AsrModels?
    ) async throws -> CellReceipt {
        let sequence = try fixture.sequence(id, repetitions: repetitions)
        let family = sequence.family
        let entry = sequence.entry
        let samples = sequence.samples
        let terminal = OSAllocatedUnfairLock<[ParakeetLiveWorkSample]>(initialState: [])
        let observed = engine.observingLiveWork { value in terminal.withLock { $0.append(value) } }
        let result = try await DictationModelProbe.run(samples: samples, transcribe: {
            observed.transcribe($0, hints: .init())
        })
        let observations = terminal.withLock { $0 }
        guard observations.count == 1, let work = observations.first,
              work.valid, work.outcome == .completed, work.inputFrames == samples.count,
              work.rejectedBuffers == 0, work.finishCalls == 1 else {
            throw DictationModelProbe.Failure.invalidInput
        }
        let attribution: DictationVendorProbe.Receipt?
        if let attributionModels {
            attribution = try await DictationVendorProbe.run(
                samples: samples, models: attributionModels, references: sequence.references,
                productionText: result.hypothesis)
        } else {
            attribution = nil
        }
        return CellReceipt(
            caseID: id, audioSHA256: entry.audioSHA256, group: family.group,
            cohort: family.cohort, shape: family.shape, split: family.split, critical: family.critical,
            pass: pass, repetitions: repetitions, score: try DictationModelProbe.score(result, references: sequence.references),
            adapterDeltas: try DictationModelProbe.score(
                hypothesis: result.mappedDeltas, legacyCleanedText: result.mappedDeltas, references: sequence.references),
            inputSeconds: Double(samples.count) / 16_000, firstUpdateSeconds: result.firstUpdateSeconds,
            completionSeconds: result.completionSeconds, inputEndSeconds: result.inputEndSeconds, work: work,
            stageAttribution: attribution)
    }
}
