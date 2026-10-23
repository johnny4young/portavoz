import Foundation
import ModelStoreKit
import os
import XCTest

@testable import PortavozCLIKit
@testable import TranscriptionKit

/// Explicit local lane: v3 and Ultra over the same public cells and feed. Both
/// models come from a selected scratch store; nothing here downloads.
final class DictationModelComparisonTests: XCTestCase {
    private struct CellReceipt: Encodable {
        let model: String
        let caseID: String
        let group: String
        let shape: String
        let critical: Bool
        let score: DictationModelProbe.Score?
        let failure: String?
        let inputSeconds: Double
        let firstUpdateSeconds: Double?
        let completionSeconds: Double?
        let inputEndSeconds: Double?
    }

    private struct ModelReceipt: Encodable {
        let model: String
        let revision: String
        let loadSeconds: Double
    }

    private struct Receipt: Encodable {
        let kind = "dictation-model-comparison-observation"
        let schemaVersion = 1
        let corpusSHA256 = DictationModelFixture.sourceDigest
        let manifestSHA256: String
        let feed = "realtime-100ms-bounded-pcm"
        let models: [ModelReceipt]
        let cells: [CellReceipt]
    }

    func testParakeetV3AgainstUltraOnPublicCells() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let audio = environment["PORTAVOZ_ASR_COMPARE_AUDIO"] else {
            throw XCTSkip("explicit local model comparison not requested")
        }
        #if DEBUG
        XCTFail("Real dictation models require Release: vendor DEBUG diagnostics can contain transcript text")
        #else
        do {
            guard let models = environment["PORTAVOZ_ASR_COMPARE_MODELS"], models.hasPrefix("/"),
                  let output = environment["PORTAVOZ_ASR_COMPARE_OUTPUT"], output.hasPrefix("/"),
                  !FileManager.default.fileExists(atPath: output) else {
                XCTFail("model comparison requires an absolute scratch model root and a new absolute output")
                return
            }
            let audioRoot = URL(fileURLWithPath: audio)
            let ids = try environment["PORTAVOZ_ASR_COMPARE_CASES"].map { $0.components(separatedBy: ",") }
                ?? DictationModelFixture.caseIDs(audioRoot: audioRoot)
            let fixture = try DictationModelFixture(audioRoot: audioRoot, selectedIDs: ids)
            for id in ids { _ = try fixture.cell(id) }
            let store = ModelStore(rootDirectory: URL(fileURLWithPath: models, isDirectory: true))
            var loaded: [ModelReceipt] = []
            var cells: [CellReceipt] = []
            let compared: [(ModelDescriptor, ParakeetCheckpoint)] = [
                (ModelCatalog.parakeetTdtV3, .v3), (ModelCatalog.parakeetUltra, .ultra)
            ]
            for (descriptor, checkpoint) in compared {
                guard let installation = await store.verifiedInstallation(descriptor) else {
                    XCTFail("a compared model did not pass pinned verification; nothing downloaded")
                    return
                }
                let started = ContinuousClock.now
                let engine = try await ParakeetEngine.load(
                    fromVerifiedDirectory: installation.directory, checkpoint: checkpoint)
                loaded.append(ModelReceipt(
                    model: descriptor.id, revision: installation.descriptorRevision,
                    loadSeconds: DictationModelProbe.seconds(started.duration(to: .now))))
                for id in ids {
                    cells.append(try await observe(id: id, model: descriptor.id, fixture: fixture, engine: engine))
                }
            }
            try CLIPrivateJSONWriter.write(
                Receipt(manifestSHA256: fixture.manifestDigest, models: loaded, cells: cells),
                to: URL(fileURLWithPath: output))
        } catch {
            // Never ask XCTest to interpolate provider errors or hypothesis text.
            XCTFail("model comparison failed; no successful receipt")
        }
        #endif
    }

    private func observe(
        id: String, model: String, fixture: DictationModelFixture, engine: ParakeetEngine
    ) async throws -> CellReceipt {
        let sequence = try fixture.sequence(id, repetitions: 1)
        let family = sequence.family
        let seconds = Double(sequence.samples.count) / 16_000
        do {
            let result = try await DictationModelProbe.run(samples: sequence.samples, transcribe: {
                engine.transcribe($0, hints: .init())
            })
            return CellReceipt(
                model: model, caseID: id, group: family.group, shape: family.shape, critical: family.critical,
                score: try DictationModelProbe.score(result, references: sequence.references), failure: nil,
                inputSeconds: seconds, firstUpdateSeconds: result.firstUpdateSeconds,
                completionSeconds: result.completionSeconds, inputEndSeconds: result.inputEndSeconds)
        } catch {
            // Only the error's type and probe case; provider messages can carry text.
            let failure = (error as? DictationModelProbe.Failure).map { "\($0)" } ?? String(describing: type(of: error))
            return CellReceipt(
                model: model, caseID: id, group: family.group, shape: family.shape, critical: family.critical,
                score: nil, failure: failure, inputSeconds: seconds, firstUpdateSeconds: nil,
                completionSeconds: nil, inputEndSeconds: nil)
        }
    }
}
