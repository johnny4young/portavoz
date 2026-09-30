import Foundation
import os
import PortavozCore
import TranscriptionKit
import XCTest

@testable import portavoz_app

@MainActor
final class DictationControllerModelProbeTests: XCTestCase {
    func testActualControllerProducesLiteralOutputWithoutDispatchAndReleasesItsLease() async throws {
        for text in ["Um, don’t pay 0.5", "Eh no pagues 0,5", "", "… !!!"] {
            var finished = 0
            let received = OSAllocatedUnfairLock(initialState: 0)
            let result = try await DictationControllerModelProbe.run(
                samples: Array(repeating: 0.1, count: 16_001),
                acquireRuntime: {
                    LiveTranscriptionRuntime(engine: Engine(text: text, received: received)) { finished += 1 }
                }, usage: Self.usage)
            XCTAssertTrue(result.inputCompleted)
            XCTAssertEqual(result.frames, 16_001)
            XCTAssertEqual(received.withLock { $0 }, result.frames)
            XCTAssertEqual(finished, 1, "A measurement must not return with its acquired lease still active")
            XCTAssertFalse(result.measurement.verifiedDeliveryMeasured)
            let empty = text == "" || text == "… !!!"
            XCTAssertEqual(result.proposedText, empty ? "" : text)
            XCTAssertEqual(result.measurement.outcome, empty ? .empty : .deliveryRejected)
            XCTAssertNotNil(result.measurement.elapsedSeconds["stopRequested"])
            XCTAssertGreaterThanOrEqual(result.measurement.terminalSeconds, 1)
            XCTAssertEqual(result.footprint.baselineBytes, 100)
            XCTAssertEqual(result.footprint.peakObservedBytes, 100)
            XCTAssertGreaterThan(result.footprint.sampleCount, 2)
        }
    }

    func testShortAudioKeepsRealMinimumCapturePolicyInsteadOfForgingTime() async throws {
        let result = try await DictationControllerModelProbe.run(
            samples: [0], acquireRuntime: { LiveTranscriptionRuntime(engine: Engine(text: "Yes"), completion: {}) },
            usage: Self.usage)
        XCTAssertEqual(result.frames, 1)
        XCTAssertEqual(result.measurement.outcome, .cancelled)
        XCTAssertTrue(result.proposedText.isEmpty)
        XCTAssertNil(result.measurement.elapsedSeconds["deliveryStarted"])
    }

    func testInputFailureIsExplicitEvenWhenTheControllerSwallowsCaptureErrors() async throws {
        let result = try await DictationControllerModelProbe.run(
            samples: Array(repeating: 0, count: 16_000),
            acquireRuntime: { LiveTranscriptionRuntime(engine: Engine(text: "A partial is not success"), completion: {}) },
            pace: { _ in throw Failure.synthetic }, usage: Self.usage)
        XCTAssertFalse(result.inputCompleted, "The model receipt must refuse this row even if the controller returns a terminal result")
        XCTAssertEqual(result.frames, 0)
        XCTAssertFalse(result.measurement.verifiedDeliveryMeasured)
    }

    func testPreparationFailureDoesNotWaitForAMicrophoneThatNeverStarted() async throws {
        let result = try await DictationControllerModelProbe.run(
            samples: [0], acquireRuntime: { throw Failure.synthetic }, usage: Self.usage)
        XCTAssertFalse(result.inputCompleted)
        XCTAssertEqual(result.frames, 0)
        XCTAssertEqual(result.measurement.outcome, .pipelineFailed)
    }

    func testInvalidPCMDoesNotLoadAnyRuntimeOrSampleTheHost() async {
        for samples in [[Float](), [.nan], [.infinity], [1.01]] {
            do {
                _ = try await DictationControllerModelProbe.run(samples: samples, acquireRuntime: {
                    XCTFail("Invalid PCM reached runtime acquisition"); throw Failure.synthetic
                }, usage: { XCTFail("Invalid PCM reached resource sampling"); return Self.usage() })
                XCTFail("Invalid PCM was accepted")
            } catch { XCTAssertEqual(error as? DictationModelProbe.Failure, .invalidInput) }
        }
    }

    func testFootprintFailureIsNotAnInventedZeroMemorySample() async {
        let calls = OSAllocatedUnfairLock(initialState: 0)
        do {
            _ = try await DictationControllerModelProbe.run(
                samples: Array(repeating: 0, count: 16_000),
                acquireRuntime: { LiveTranscriptionRuntime(engine: Engine(text: "Hello"), completion: {}) },
                usage: {
                    let call = calls.withLock { $0 += 1; return $0 }
                    if call == 2 { throw Failure.synthetic }
                    return Self.usage()
                })
            XCTFail("A failed sampler cannot certify memory")
        } catch { XCTAssertEqual(error as? DictationModelProbe.Failure, .invalidInput) }
    }

    nonisolated static func usage() -> ResourceProbeUsage {
        .init(cpuAbsoluteTime: 0, physicalFootprintBytes: 100, energyNanojoules: 0,
              diskReadBytes: 0, diskWrittenBytes: 0, availableDiskBytes: 1_000,
              thermalState: .nominal, powerSource: .unknown, lowPowerModeEnabled: false)
    }

    private enum Failure: Error { case synthetic }

    private struct Engine: TranscriptionEngine {
        let text: String
        var received = OSAllocatedUnfairLock(initialState: 0)
        let descriptor = EngineDescriptor(
            id: "controller-probe-double", displayName: "Controller probe double",
            realTimeFactor: 0, runsOnDevice: true, approximateMemoryMB: 0)

        func transcribe(_ audio: AsyncStream<AudioChunk>, hints: TranscriptionHints) -> AsyncThrowingStream<TranscriptSegment, Error> {
            AsyncThrowingStream { output in
                let task = Task {
                    for await chunk in audio { received.withLock { $0 += chunk.samples.count } }
                    output.yield(TranscriptSegment(
                        meetingID: hints.meetingID ?? MeetingID(), channel: .microphone,
                        text: text, startTime: 0, endTime: 1, isFinal: true))
                    output.finish()
                }
                output.onTermination = { _ in task.cancel() }
            }
        }
    }
}
