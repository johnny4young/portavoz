import AVFoundation
import Foundation
import PortavozCore
import XCTest

@testable import ModelStoreKit
@testable import TranscriptionKit

/// Real-model integration tests. Skipped unless PORTAVOZ_MODEL_TESTS=1 and
/// the Parakeet model is already installed (run `portavoz-cli models
/// download` first) — CI never downloads 483 MB.
final class ParakeetIntegrationTests: XCTestCase {
    private func loadedEngine() async throws -> ParakeetEngine {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["PORTAVOZ_MODEL_TESTS"] == "1",
            "set PORTAVOZ_MODEL_TESTS=1 (and install the model) to run")
        let store = ModelStore()
        let descriptor = ModelCatalog.parakeetTdtV3
        let report = await store.verify(descriptor)
        try XCTSkipUnless(report.isComplete, "model not installed; run: portavoz-cli models download")
        let directory = await store.directory(for: descriptor)
        return try await ParakeetEngine.load(fromVerifiedDirectory: directory)
    }

    /// Feeds a spoken WAV through the *live* sliding-window path in ~100 ms
    /// chunks (as the mic would) and expects streamed segments out.
    func testLiveSlidingWindowStreamsSegments() async throws {
        let wavPath = ProcessInfo.processInfo.environment["PORTAVOZ_TEST_WAV"]
        try XCTSkipUnless(wavPath != nil, "set PORTAVOZ_TEST_WAV to a spoken wav file")
        let engine = try await loadedEngine()

        let file = try AVAudioFile(forReading: URL(fileURLWithPath: wavPath!))
        let format = file.processingFormat
        let buffer = AVAudioPCMBuffer(
            pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        let samples = Array(
            UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))

        let (stream, continuation) = AsyncStream.makeStream(of: AudioChunk.self)
        let chunkSize = Int(format.sampleRate / 10)  // 100 ms
        Task {
            var offset = 0.0
            for start in stride(from: 0, to: samples.count, by: chunkSize) {
                let end = min(start + chunkSize, samples.count)
                continuation.yield(
                    AudioChunk(
                        channel: .microphone,
                        samples: Array(samples[start..<end]),
                        sampleRate: format.sampleRate,
                        timestamp: offset))
                offset += Double(end - start) / format.sampleRate
            }
            continuation.finish()
        }

        var segments: [TranscriptSegment] = []
        for try await segment in engine.transcribe(stream, hints: TranscriptionHints(language: "en")) {
            segments.append(segment)
        }

        XCTAssertFalse(segments.isEmpty, "expected live segments from spoken audio")
        let fullText = segments.map(\.text).joined(separator: " ").lowercased()
        XCTAssertTrue(
            fullText.contains("fox") || fullText.contains("transcription"),
            "unexpected live transcript: \(fullText)")
        // Times must be monotonic-ish and within the file duration (+ slack).
        let duration = Double(file.length) / format.sampleRate
        for segment in segments {
            XCTAssertGreaterThanOrEqual(segment.startTime, 0)
            XCTAssertLessThanOrEqual(segment.endTime, duration + 2.0)
        }
    }
}
