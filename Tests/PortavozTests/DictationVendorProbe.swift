import FluidAudio
import Foundation
import os
import PortavozCore

@testable import TranscriptionKit

/// Opt-in attribution experiment, NOT the production engine. It runs the pinned
/// manager/config and the actual mapper/coalescer while observing their boundary.
/// No raw text or tokens are encoded, and it does not alter shipping diagnostics.
enum DictationVendorProbe {
    struct Receipt: Encodable {
        let vendorFinal: DictationModelProbe.Score
        let mappedAndCoalesced: DictationModelProbe.Score
        let matchesProductionText: Bool
        let updateCount: Int
        let timingCount: Int
        let rejectedAtBoundary: Int
        let rejectedBeforeBoundary: Int
        let mappedSegmentCount: Int
    }

    struct Reduction: Sendable {
        var edge = 0.0
        var updateCount = 0
        var timingCount = 0
        var rejectedAtBoundary = 0
        var rejectedBeforeBoundary = 0
        var mappedSegmentCount = 0
        private var payloadBytes = 0
        private let meetingID = MeetingID()

        mutating func apply(_ update: SlidingWindowTranscriptionUpdate) throws -> TranscriptSegment? {
            updateCount += 1
            payloadBytes += update.text.utf8.count
            guard updateCount <= 10_000, payloadBytes <= 1_000_000,
                  update.tokenTimings.count <= 10_000 else {
                throw DictationModelProbe.Failure.outputOverflow
            }
            timingCount += update.tokenTimings.count
            rejectedAtBoundary += update.tokenTimings.filter { $0.startTime == edge }.count
            rejectedBeforeBoundary += update.tokenTimings.filter { $0.startTime < edge }.count
            let segment = ParakeetSegmentMapper.segment(
                text: update.text, isConfirmed: update.isConfirmed, confidence: update.confidence,
                tokenTimings: update.tokenTimings, meetingID: meetingID, channel: .microphone,
                language: nil, fallbackTime: edge)
            if let segment {
                edge = segment.endTime
                mappedSegmentCount += 1
            }
            return segment
        }
    }

    private struct State: Sendable {
        var reduction = Reduction()
        var finalText = ""
    }

    static func run(
        samples: [Float], models: AsrModels, references: [String], productionText: String
    ) async throws -> Receipt {
        let state = OSAllocatedUnfairLock(initialState: State())
        let result = try await DictationModelProbe.run(samples: samples) { audio in
            AsyncThrowingStream { output in
                let task = Task {
                    let manager = SlidingWindowAsrManager(config: ParakeetEngine.liveWindowConfig)
                    var consumer: Task<Void, Error>?
                    do {
                        try await manager.loadModels(models)
                        try await manager.startStreaming(source: .microphone)
                        let updates = await manager.transcriptionUpdates
                        consumer = Task {
                            for await update in updates {
                                try Task.checkCancellation()
                                let segment = try state.withLock { try $0.reduction.apply(update) }
                                if let segment { output.yield(segment) }
                            }
                        }
                        for await chunk in audio {
                            try Task.checkCancellation()
                            guard let buffer = chunk.pcmBuffer() else {
                                throw DictationModelProbe.Failure.invalidInput
                            }
                            await manager.streamAudio(buffer)
                        }
                        try Task.checkCancellation()
                        let finalText = try await manager.finish()
                        guard finalText.utf8.count <= 1_000_000 else {
                            throw DictationModelProbe.Failure.outputOverflow
                        }
                        state.withLock { $0.finalText = finalText }
                        await manager.cancel()
                        try await consumer?.value
                        await manager.cleanup()
                        output.finish()
                    } catch {
                        await manager.cancel()
                        consumer?.cancel()
                        _ = try? await consumer?.value
                        await manager.cleanup()
                        output.finish(throwing: error)
                    }
                }
                output.onTermination = { _ in task.cancel() }
            }
        }
        let snapshot = state.withLock { $0 }
        return Receipt(
            vendorFinal: try DictationModelProbe.score(
                hypothesis: snapshot.finalText, legacyCleanedText: snapshot.finalText, references: references),
            mappedAndCoalesced: try DictationModelProbe.score(result, references: references),
            matchesProductionText: productionText == result.hypothesis,
            updateCount: snapshot.reduction.updateCount, timingCount: snapshot.reduction.timingCount,
            rejectedAtBoundary: snapshot.reduction.rejectedAtBoundary,
            rejectedBeforeBoundary: snapshot.reduction.rejectedBeforeBoundary,
            mappedSegmentCount: snapshot.reduction.mappedSegmentCount)
    }
}
