import AVFoundation
import Foundation
import PortavozCore
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

    func testPropagatesEngineFailureAfterPartialInsteadOfPublishingEvidence() async throws {
        let file = try makeAudioFile(duration: 2)
        defer { try? FileManager.default.removeItem(at: file) }

        do {
            _ = try await LiveTranscriptionBench.run(
                file: file,
                seconds: 2,
                transcribe: { _ in
                    AsyncThrowingStream { continuation in
                        continuation.yield(TranscriptSegment(
                            meetingID: MeetingID(), channel: .microphone,
                            text: "Do not send the draft", startTime: 0,
                            endTime: 0.5, isFinal: false))
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

    func testExactWAVEndWithPartialLastChunkDoesNotAttemptAnotherRead() async throws {
        // 63_773 / 16_000 differs from 3 + 15_773 / 16_000 by one ULP.
        // The old seconds-based loop re-entered after all frames were fed,
        // and AVAudioFile throws at EOF instead of returning an empty buffer.
        let frameCount: AVAudioFrameCount = 63_773
        let file = try makeAudioFile(frameCount: frameCount, fileExtension: "wav")
        defer { try? FileManager.default.removeItem(at: file) }

        let result = try await LiveTranscriptionBench.run(
            file: file,
            seconds: 8,
            transcribe: { audio in
                AsyncThrowingStream { continuation in
                    Task {
                        var received = 0
                        for await chunk in audio { received += chunk.samples.count }
                        continuation.yield(TranscriptSegment(
                            meetingID: MeetingID(), channel: .microphone,
                            text: "frames \(received)", startTime: 0,
                            endTime: Double(received) / 16_000, isFinal: true))
                        continuation.finish()
                    }
                }
            },
            log: { _ in })

        XCTAssertEqual(result.hypothesis, "frames \(frameCount)")
        XCTAssertEqual(result.finals, 1)
    }

    func testSpanishPartialAndFinalUseTheDictationCallSiteRatherThanFinalsAlone() async throws {
        let meeting = MeetingID()
        let updates = [
            segment("No autorices el pago", meeting: meeting, start: 0, end: 0.4),
            segment("pago hasta el viernes.", meeting: meeting, start: 0.4, end: 0.8),
            segment("Gracias.", meeting: meeting, start: 0.8, end: 1, isFinal: true),
        ]
        let result = try await runSyntheticUpdates(updates)

        XCTAssertEqual(result.hypothesis, "Gracias.")
        XCTAssertEqual(result.dictationRecognizedText, "No autorices el pago hasta el viernes. Gracias.")
        XCTAssertEqual(result.finals, 1)
        let reference = "No autorices el pago hasta el viernes. Gracias."
        XCTAssertGreaterThan(
            TranscriptionAccuracy.report(reference: reference, hypothesis: result.hypothesis).wordErrorRate,
            0)
        XCTAssertEqual(
            TranscriptionAccuracy.report(
                reference: reference, hypothesis: result.dictationRecognizedText).wordErrorRate,
            0)
    }

    func testEnglishVolatileOnlyStillContributesToDictationAccuracy() async throws {
        let meeting = MeetingID()
        let result = try await runSyntheticUpdates([
            segment("I said don’t", meeting: meeting, start: 0, end: 0.4),
            segment("don’t erase it", meeting: meeting, start: 0.4, end: 0.9),
        ])

        XCTAssertTrue(result.finalTexts.isEmpty)
        XCTAssertEqual(result.hypothesis, "")
        XCTAssertEqual(result.dictationRecognizedText, "I said don’t erase it")
        XCTAssertEqual(
            TranscriptionAccuracy.report(
                reference: "I said don’t erase it", hypothesis: result.dictationRecognizedText).wordErrorRate,
            0)
    }

    func testEmptyAndPunctuationOnlyOutputsCannotBecomeDictationSpeech() async throws {
        let empty = try await runSyntheticUpdates([])
        XCTAssertEqual(empty.dictationRecognizedText, "")

        let noise = try await runSyntheticUpdates([
            segment("...", meeting: MeetingID(), start: 0, end: 0.5, isFinal: true),
        ])
        XCTAssertEqual(noise.hypothesis, "...")
        XCTAssertEqual(noise.dictationRecognizedText, "")
    }

    private func runSyntheticUpdates(
        _ updates: [TranscriptSegment]
    ) async throws -> LiveTranscriptionBench.Result {
        let file = try makeAudioFile(duration: 1)
        defer { try? FileManager.default.removeItem(at: file) }
        return try await LiveTranscriptionBench.run(
            file: file,
            seconds: 1,
            transcribe: { audio in
                AsyncThrowingStream { continuation in
                    Task {
                        for await _ in audio {}
                        for update in updates { continuation.yield(update) }
                        continuation.finish()
                    }
                }
            },
            log: { _ in })
    }

    private func segment(
        _ text: String,
        meeting: MeetingID,
        start: TimeInterval,
        end: TimeInterval,
        isFinal: Bool = false
    ) -> TranscriptSegment {
        TranscriptSegment(
            meetingID: meeting,
            channel: .microphone,
            text: text,
            startTime: start,
            endTime: end,
            isFinal: isFinal)
    }

    private func makeAudioFile(duration: TimeInterval) throws -> URL {
        try makeAudioFile(
            frameCount: AVAudioFrameCount(duration * 16_000),
            fileExtension: "caf")
    }

    private func makeAudioFile(
        frameCount: AVAudioFrameCount,
        fileExtension: String
    ) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("portavoz-live-bench-\(UUID().uuidString).\(fileExtension)")
        do {
            guard let format = AVAudioFormat(
                standardFormatWithSampleRate: 16_000,
                channels: 1)
            else { throw LiveTranscriptionBench.BenchError.invalidAudioFormat }
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
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
