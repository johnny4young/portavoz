import Darwin
import Foundation
import ModelStoreKit
import PortavozCore
import TranscriptionKit
import XCTest

@testable import portavoz_app
@testable import portavoz_cli

/// Explicit local lane: the production speech-gate rule over every public cell.
/// The model comes only from the selected scratch store, never the app's.
final class DictationSpeechGateCorpusTests: XCTestCase {
    private struct CellReceipt: Encodable {
        let caseID: String
        let shape: String
        let profile: String
        let audioSeconds: Double
        let heardSpeech: Bool
        let firstSpeechSeconds: Double?
        let maximumProbability: Float
        let cpuSeconds: Double
        let slowestChunkSeconds: Double
    }

    private struct Receipt: Encodable {
        let kind = "dictation-speech-gate-observation"
        let schemaVersion = 1
        let corpusSHA256 = DictationModelFixture.sourceDigest
        let manifestSHA256: String
        let modelRevision: String
        let threshold = DictationSpeechGate.speechProbabilityThreshold
        let feed = "unpaced-100ms-16khz-full-pass"
        let optimized: Bool
        let cells: [CellReceipt]
    }

    func testSpeechGateOverEveryPublicCell() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let audio = environment["PORTAVOZ_SPEECH_GATE_AUDIO"] else {
            throw XCTSkip("explicit local speech-gate corpus run not requested")
        }
        guard let models = environment["PORTAVOZ_SPEECH_GATE_MODELS"], models.hasPrefix("/"),
              let output = environment["PORTAVOZ_SPEECH_GATE_OUTPUT"], output.hasPrefix("/"),
              !FileManager.default.fileExists(atPath: output) else {
            XCTFail("speech-gate run requires an absolute scratch model root and a new absolute output")
            return
        }
        let store = ModelStore(rootDirectory: URL(fileURLWithPath: models, isDirectory: true))
        if environment["PORTAVOZ_SPEECH_GATE_INSTALL"] == "1" {
            _ = try await store.ensureAvailable(ModelCatalog.sileroVAD)
        }
        guard let installation = await store.verifiedInstallation(ModelCatalog.sileroVAD) else {
            XCTFail("Silero did not pass pinned verification in the selected store")
            return
        }
        let ids = try DictationModelFixture.caseIDs(audioRoot: URL(fileURLWithPath: audio))
        let fixture = try DictationModelFixture(audioRoot: URL(fileURLWithPath: audio), selectedIDs: ids)
        var cells: [CellReceipt] = []
        for id in ids {
            let (family, entry, samples) = try fixture.cell(id)
            let detector = try await SileroVoiceActivityDetector.load(from: store, channel: .microphone)
            cells.append(try await observe(
                id: id, shape: family.shape, frames: entry.frames, samples: samples, detector: detector))
        }
        #if DEBUG
        let optimized = false
        #else
        let optimized = true
        #endif
        let receipt = Receipt(
            manifestSHA256: fixture.manifestDigest, modelRevision: installation.descriptorRevision,
            optimized: optimized, cells: cells)
        try CLIPrivateJSONWriter.write(receipt, to: URL(fileURLWithPath: output))
    }

    private func observe(
        id: String, shape: String, frames: Int, samples: [Float], detector: SileroVoiceActivityDetector
    ) async throws -> CellReceipt {
        let step = 1_600
        var firstSpeech: Double?
        var maximum: Float = 0
        var slowest = 0.0
        let cpuStart = Self.processCPUSeconds()
        for start in stride(from: 0, to: samples.count, by: step) {
            let chunk = AudioChunk(
                channel: .microphone, samples: Array(samples[start..<min(start + step, samples.count)]),
                sampleRate: 16_000, timestamp: Double(start) / 16_000)
            let began = ContinuousClock.now
            let batch = try await detector.process(chunk)
            slowest = max(slowest, DictationModelProbe.seconds(began.duration(to: .now)))
            maximum = max(maximum, batch.observations.map(\.speechProbability).max() ?? 0)
            if firstSpeech == nil, DictationSpeechGate.heardSpeech(batch) {
                firstSpeech = batch.observations.first {
                    $0.isSpeechActive || $0.speechProbability >= DictationSpeechGate.speechProbabilityThreshold
                }?.frameEnd
            }
        }
        return CellReceipt(
            caseID: id, shape: shape, profile: String(id.split(separator: ".").last ?? ""),
            audioSeconds: Double(frames) / 16_000, heardSpeech: firstSpeech != nil,
            firstSpeechSeconds: firstSpeech, maximumProbability: maximum,
            cpuSeconds: Self.processCPUSeconds() - cpuStart, slowestChunkSeconds: slowest)
    }

    private static func processCPUSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let user = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6
        let system = Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6
        return user + system
    }
}
