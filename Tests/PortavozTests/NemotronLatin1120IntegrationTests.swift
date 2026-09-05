import AVFoundation
import Foundation
import PortavozCore
import XCTest

@testable import ModelStoreKit
@testable import TranscriptionKit

/// Optional real-model gate. CI and ordinary local suites never download the
/// ~588 MB challenger. Run with PORTAVOZ_NEMOTRON_MODEL_TESTS=1 and an already
/// installed descriptor plus PORTAVOZ_TEST_WAV.
final class NemotronLatin1120IntegrationTests: XCTestCase {
    func testVerifiedModelStreamsStableSegments() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["PORTAVOZ_NEMOTRON_MODEL_TESTS"] == "1",
            "set PORTAVOZ_NEMOTRON_MODEL_TESTS=1 to run")
        let wavPath = try XCTUnwrap(
            ProcessInfo.processInfo.environment["PORTAVOZ_TEST_WAV"],
            "set PORTAVOZ_TEST_WAV to a spoken English or Spanish file")

        let store = ModelStore()
        let descriptor = ModelCatalog.nemotronLatin1120
        let report = await store.verify(descriptor)
        try XCTSkipUnless(
            report.isComplete,
            "install the candidate with bench-live before running this gate")
        let directory = await store.directory(for: descriptor)
        let engine = try await NemotronLatin1120Engine.load(
            fromVerifiedDirectory: directory)

        let file = try AVAudioFile(forReading: URL(fileURLWithPath: wavPath))
        let format = file.processingFormat
        guard
            let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(file.length))
        else {
            XCTFail("could not allocate the WAV buffer")
            return
        }
        try file.read(into: buffer)
        guard let channel = buffer.floatChannelData?[0] else {
            XCTFail("test WAV is not Float32 PCM")
            return
        }
        let samples = Array(UnsafeBufferPointer(
            start: channel,
            count: Int(buffer.frameLength)))

        let (stream, continuation) = AsyncStream.makeStream(of: AudioChunk.self)
        let chunkSize = max(1, Int(format.sampleRate / 10))
        Task {
            var timestamp: TimeInterval = 0
            for start in stride(from: 0, to: samples.count, by: chunkSize) {
                let end = min(start + chunkSize, samples.count)
                continuation.yield(AudioChunk(
                    channel: .microphone,
                    samples: Array(samples[start..<end]),
                    sampleRate: format.sampleRate,
                    timestamp: timestamp))
                timestamp += Double(end - start) / format.sampleRate
            }
            continuation.finish()
        }

        var segments: [TranscriptSegment] = []
        for try await segment in engine.transcribe(
            stream,
            hints: TranscriptionHints(language: "en")) {
            segments.append(segment)
        }
        XCTAssertFalse(segments.isEmpty)
        XCTAssertTrue(segments.allSatisfy(\.isFinal))
        XCTAssertTrue(segments.allSatisfy { $0.language == "en" })
        XCTAssertFalse(segments.map(\.text).joined().isEmpty)
    }
}
