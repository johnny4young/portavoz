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
        #if DEBUG
        let requiresPrivacySafeReleaseBuild = true
        #else
        let requiresPrivacySafeReleaseBuild = false
        #endif
        try XCTSkipIf(
            requiresPrivacySafeReleaseBuild,
            "real Parakeet integration requires a Release build; FluidAudio mirrors "
                + "transcript-bearing DEBUG diagnostics to stderr")
        guard let wavPath = ProcessInfo.processInfo.environment["PORTAVOZ_TEST_WAV"] else {
            throw XCTSkip("set PORTAVOZ_TEST_WAV to a spoken wav file")
        }
        let engine = try await loadedEngine()

        let file = try AVAudioFile(forReading: URL(fileURLWithPath: wavPath))
        let format = file.processingFormat
        guard file.length > 0,
              file.length <= AVAudioFramePosition(AVAudioFrameCount.max),
              format.sampleRate.isFinite,
              format.sampleRate >= 10,
              format.channelCount > 0
        else {
            XCTFail("expected bounded readable PCM audio metadata")
            return
        }
        let duration = Double(file.length) / format.sampleRate
        guard duration <= 600 else {
            XCTFail("spoken integration fixture exceeds the 10-minute memory bound")
            return
        }
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length))
        else {
            XCTFail("could not allocate the bounded PCM integration buffer")
            return
        }
        try file.read(into: buffer)
        guard let channelData = buffer.floatChannelData else {
            XCTFail("expected float PCM channel data")
            return
        }
        let samples = Array(
            UnsafeBufferPointer(start: channelData[0], count: Int(buffer.frameLength)))

        let (stream, continuation) = AsyncStream.makeStream(of: AudioChunk.self)
        let chunkSize = max(1, Int(format.sampleRate / 10))  // 100 ms
        let producer = Task {
            var offset = 0.0
            for start in stride(from: 0, to: samples.count, by: chunkSize) {
                guard !Task.isCancelled else { break }
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
        defer {
            producer.cancel()
            continuation.finish()
        }

        var segments: [TranscriptSegment] = []
        for try await segment in engine.transcribe(stream, hints: TranscriptionHints(language: "en")) {
            segments.append(segment)
        }
        await producer.value

        XCTAssertFalse(segments.isEmpty, "expected live segments from spoken audio")
        let fullText = segments.map(\.text).joined(separator: " ").lowercased()
        let lexicalCharacterCount = fullText.unicodeScalars.reduce(into: 0) { count, scalar in
            if CharacterSet.letters.contains(scalar) { count += 1 }
        }
        XCTAssertGreaterThanOrEqual(
            lexicalCharacterCount,
            8,
            "expected lexical output from spoken audio; "
                + "segments=\(segments.count) lexicalCharacters=\(lexicalCharacterCount)")
        // Times must be monotonic-ish and within the file duration (+ slack).
        for segment in segments {
            XCTAssertGreaterThanOrEqual(segment.startTime, 0)
            XCTAssertLessThanOrEqual(segment.endTime, duration + 2.0)
        }
    }
}
