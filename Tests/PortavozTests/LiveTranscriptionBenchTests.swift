import AVFoundation
import Foundation
import XCTest

@testable import TranscriptionKit

final class LiveTranscriptionBenchTests: XCTestCase {
    private enum ProbeError: Error {
        case failed
    }

    func testRejectsInvalidDurationBeforeOpeningAFile() async {
        do {
            _ = try await LiveTranscriptionBench.run(
                file: URL(fileURLWithPath: "/does/not/exist"),
                seconds: 0,
                transcribe: { _ in AsyncThrowingStream { $0.finish() } },
                log: { _ in })
            XCTFail("expected an invalid-duration failure")
        } catch {
            XCTAssertEqual(
                error as? LiveTranscriptionBench.BenchError,
                .invalidDuration(0))
        }
    }

    func testPropagatesEngineFailureInsteadOfPublishingPartialEvidence() async throws {
        let file = try makeAudioFile(duration: 2)
        defer { try? FileManager.default.removeItem(at: file) }

        do {
            _ = try await LiveTranscriptionBench.run(
                file: file,
                seconds: 2,
                transcribe: { _ in
                    AsyncThrowingStream { continuation in
                        continuation.finish(throwing: ProbeError.failed)
                    }
                },
                log: { _ in })
            XCTFail("expected the engine failure")
        } catch {
            guard case ProbeError.failed = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testEarlyEngineCompletionCancelsTheRealTimeFeeder() async throws {
        let file = try makeAudioFile(duration: 2)
        defer { try? FileManager.default.removeItem(at: file) }

        do {
            _ = try await LiveTranscriptionBench.run(
                file: file,
                seconds: 2,
                transcribe: { _ in AsyncThrowingStream { $0.finish() } },
                log: { _ in })
            XCTFail("expected early completion to fail closed")
        } catch {
            XCTAssertEqual(
                error as? LiveTranscriptionBench.BenchError,
                .engineEndedBeforeInput)
        }
    }

    private func makeAudioFile(duration: TimeInterval) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("portavoz-live-bench-\(UUID().uuidString).caf")
        do {
            guard let format = AVAudioFormat(
                standardFormatWithSampleRate: 16_000,
                channels: 1)
            else { throw LiveTranscriptionBench.BenchError.invalidAudioFormat }
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            let frameCount = AVAudioFrameCount(duration * format.sampleRate)
            guard
                let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: frameCount),
                let samples = buffer.floatChannelData?[0]
            else { throw LiveTranscriptionBench.BenchError.invalidAudioFormat }
            buffer.frameLength = frameCount
            samples.initialize(
                repeating: 0,
                count: Int(frameCount))
            try file.write(from: buffer)
            return url
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }
}
