import Foundation
import os
import PortavozCore
import XCTest

final class DictationModelProbeTests: XCTestCase {
    private enum Injected: Error { case afterPartial }

    func testRealStreamConsumerCoalescesBothLanguagesAndKeepsLiteralAndCleanupDistinct() async throws {
        for text in ["Um, don’t pay 0.5", "Eh, no pagues 0,5", "El envío is not approved", ""] {
            let result = try await DictationModelProbe.run(
                samples: [Float](repeating: 0, count: 1_601),
                transcribe: consuming([text]), pace: { _ in })
            let score = try DictationModelProbe.score(result, references: [text])
            XCTAssertEqual(result.frames, 1_601)
            XCTAssertEqual(score.wordErrorRate, 0)
            XCTAssertEqual(score.exactReferenceMatch, true)
            XCTAssertEqual(score.legacyCleanupChangedText, text.hasPrefix("Um") || text.hasPrefix("Eh"))
            XCTAssertGreaterThanOrEqual(result.completionSeconds, result.inputEndSeconds)
        }
    }

    func testActualPacingFeedsShortLastBufferAfterItsCaptureDeadline() async throws {
        let received = OSAllocatedUnfairLock<[AudioChunk]>(initialState: [])
        let result = try await DictationModelProbe.run(
            samples: [Float](repeating: 0.1, count: 1_601),
            transcribe: consuming(["hola"], received: received))
        let chunks = received.withLock { $0 }
        XCTAssertEqual(chunks.map { $0.samples.count }, [1_600, 1])
        XCTAssertEqual(chunks.map(\.timestamp), [0, 0.1])
        XCTAssertTrue(chunks.allSatisfy { $0.channel == .microphone && $0.sampleRate == 16_000 })
        XCTAssertGreaterThanOrEqual(result.inputEndSeconds, 1_601.0 / 16_000)
    }

    func testMissingInputAndNonfiniteSamplesNeverInvokeProvider() async {
        for samples in [[Float](), [.nan], [.infinity], [1.01], [-1.01]] {
            do {
                _ = try await DictationModelProbe.run(samples: samples, transcribe: { _ in
                    XCTFail("invalid PCM reached the provider")
                    return AsyncThrowingStream { $0.finish() }
                })
                XCTFail("invalid PCM admitted")
            } catch { XCTAssertEqual(error as? DictationModelProbe.Failure, .invalidInput) }
        }
    }

    func testPartialThenFailureNeverReturnsSuccessfulQuality() async {
        do {
            _ = try await DictationModelProbe.run(samples: [0], transcribe: { _ in
                AsyncThrowingStream { output in
                    output.yield(Self.segment("do not pay"))
                    output.finish(throwing: Injected.afterPartial)
                }
            }, pace: { _ in })
            XCTFail("partial failure admitted")
        } catch { XCTAssertTrue(error is Injected) }
    }

    func testEarlyEngineCompletionCancelsAStillSleepingProducer() async {
        do {
            _ = try await DictationModelProbe.run(
                samples: [0], transcribe: { _ in AsyncThrowingStream { $0.finish() } },
                pace: { _ in try await Task.sleep(for: .seconds(60)) })
            XCTFail("early completion admitted")
        } catch { XCTAssertEqual(error as? DictationModelProbe.Failure, .engineEndedEarly) }
    }

    func testInputOverflowEndsTheActualBoundedFeedWithoutMarkingCompletion() async {
        let (input, feed) = AsyncStream.makeStream(of: AudioChunk.self, bufferingPolicy: .bufferingOldest(128))
        let end = OSAllocatedUnfairLock<ContinuousClock.Instant?>(initialState: nil)
        do {
            try await DictationModelProbe.produce(
                samples: [Float](repeating: 0, count: 1_600 * 129), feed: feed,
                started: .now, pace: { _ in }, end: end)
            XCTFail("dropped input admitted")
        } catch { XCTAssertEqual(error as? DictationModelProbe.Failure, .inputOverflow) }
        XCTAssertNil(end.withLock { $0 })
        var count = 0
        for await _ in input { count += 1 }
        XCTAssertEqual(count, 128)
    }

    func testInputFailureCannotBecomeSuccessfulEmptyOutput() async {
        do {
            _ = try await DictationModelProbe.run(
                samples: [0], transcribe: consuming([]), pace: { _ in throw Injected.afterPartial })
            XCTFail("failed feeder admitted")
        } catch { XCTAssertTrue(error is Injected) }
    }

    func testScoreReceiptContainsMetricsButNeverRecognizedTextOrReferences() async throws {
        let text = "Confidential-looking synthetic identifier 84921"
        let result = try await DictationModelProbe.run(
            samples: [0], transcribe: consuming([text]), pace: { _ in })
        let score = try DictationModelProbe.score(result, references: ["wrong", text])
        XCTAssertEqual(score.wordErrorRate, 0)
        let encoded = String(decoding: try JSONEncoder().encode(score), as: UTF8.self)
        XCTAssertFalse(encoded.contains("84921"))
        XCTAssertFalse(encoded.contains("wrong"))
        XCTAssertThrowsError(try DictationModelProbe.score(result, references: []))
        let silence = try DictationModelProbe.score(result, references: [""])
        XCTAssertEqual(silence.wordErrorRate, 1)
        XCTAssertGreaterThan(silence.hypothesisWords, 0)
    }

    private func consuming(
        _ texts: [String], received: OSAllocatedUnfairLock<[AudioChunk]>? = nil
    ) -> DictationModelProbe.Engine {
        { input in
            AsyncThrowingStream { output in
                let task = Task {
                    for await chunk in input { received?.withLock { $0.append(chunk) } }
                    for text in texts { output.yield(Self.segment(text)) }
                    output.finish()
                }
                output.onTermination = { _ in task.cancel() }
            }
        }
    }

    private static func segment(_ text: String) -> TranscriptSegment {
        TranscriptSegment(meetingID: MeetingID(), channel: .microphone,
                          text: text, startTime: 0, endTime: 0.1, isFinal: true)
    }
}
