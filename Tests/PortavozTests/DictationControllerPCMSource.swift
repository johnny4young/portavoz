import AudioCaptureKit
import Foundation
import os
import PortavozCore

/// EOF asks the driver to press Stop; only controller-owned Stop closes input.
actor DictationControllerPCMSource: AudioCaptureSource {
    nonisolated let channel = AudioChannel.microphone
    nonisolated let completion: AsyncStream<Bool>
    private let completed: AsyncStream<Bool>.Continuation
    private let samples: [Float]
    private let pace: DictationModelProbe.Pace
    private var input: AsyncThrowingStream<AudioChunk, Error>.Continuation?
    private var producer: Task<Void, Never>?
    private let fedFrames = OSAllocatedUnfairLock(initialState: 0)
    private(set) var starts = 0
    private(set) var stops = 0

    init(samples: [Float], pace: @escaping DictationModelProbe.Pace) {
        self.samples = samples
        self.pace = pace
        (completion, completed) = AsyncStream.makeStream(of: Bool.self, bufferingPolicy: .bufferingOldest(1))
    }

    func start() async throws -> AsyncThrowingStream<AudioChunk, Error> {
        guard starts == 0 else { throw DictationModelProbe.Failure.invalidInput }
        starts += 1
        let (stream, input) = AsyncThrowingStream.makeStream(
            of: AudioChunk.self, bufferingPolicy: .bufferingOldest(128))
        self.input = input
        let started = ContinuousClock.now
        producer = Task { [samples, pace, fedFrames, completed] in
            do {
                try await DictationPCMFeeder.feed(samples: samples, started: started, pace: pace) { chunk in
                    switch input.yield(chunk) {
                    case .enqueued: fedFrames.withLock { $0 += chunk.samples.count }
                    case .dropped: throw DictationModelProbe.Failure.inputOverflow
                    case .terminated: throw DictationModelProbe.Failure.engineEndedEarly
                    @unknown default: throw DictationModelProbe.Failure.inputOverflow
                    }
                }
                completed.yield(true)
            } catch {
                input.finish(throwing: error)
                completed.yield(false)
            }
            completed.finish()
        }
        return stream
    }

    func stop() async {
        stops += 1
        producer?.cancel()
        input?.finish()
        await producer?.value
        producer = nil
        input = nil
        completed.finish()
    }

    nonisolated var frames: Int { fedFrames.withLock { $0 } }
}
