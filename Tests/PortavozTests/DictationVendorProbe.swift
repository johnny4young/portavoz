import FluidAudio
import Foundation
import os
import PortavozCore

@testable import TranscriptionKit
@testable import portavoz_app

/// Opt-in attribution experiment, NOT the production engine. It runs the pinned
/// manager/config and the actual mapper/coalescer while observing their boundary.
/// No raw text or tokens are encoded, and it does not alter shipping diagnostics.
enum DictationVendorProbe {
    struct ConsumerParity: Encodable, Equatable, Sendable {
        let nativeMatchesProduction: Bool
        let dictationMatchesNative: Bool
        let meetingMatchesNative: Bool
        let previewsCleared: Bool
    }

    struct Receipt: Encodable {
        let vendorFinal: DictationModelProbe.Score
        let mappedAndCoalesced: DictationModelProbe.Score
        let matchesProductionText: Bool
        let updateCount: Int
        let timingCount: Int
        let rejectedAtBoundary: Int
        let rejectedBeforeBoundary: Int
        let mappedSegmentCount: Int
        // Kept out of the existing shared receipt schema; the opt-in baseline
        // writes these content-free checks in a separate contract sidecar.
        let consumerParity: ConsumerParity

        private enum CodingKeys: String, CodingKey {
            case vendorFinal, mappedAndCoalesced, matchesProductionText, updateCount
            case timingCount, rejectedAtBoundary, rejectedBeforeBoundary, mappedSegmentCount
        }
    }

    struct Reduction: Sendable {
        private var stream = ParakeetSegmentMapper.LiveStream()
        var edge: Double { stream.endTime }
        var updateCount = 0
        var timingCount = 0
        var rejectedAtBoundary: Int { stream.replayedAtFrontier }
        var rejectedBeforeBoundary: Int { stream.replayedBeforeFrontier }
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
            let segment = try stream.segment(
                text: update.text, isConfirmed: update.isConfirmed, confidence: update.confidence,
                tokenTimings: update.tokenTimings, meetingID: meetingID, channel: .microphone,
                language: nil)
            if segment != nil {
                mappedSegmentCount += 1
            }
            return segment
        }
    }

    /// Independent native attribution uses the same producer-owned positions
    /// as serving. The legacy Reduction above remains a regression reference.
    private struct StrictReduction: Sendable {
        var stream = ParakeetSegmentMapper.RevisionStream()
        var updateCount = 0
        var timingCount = 0
        var mappedSegmentCount = 0
        var segments: [TranscriptSegment] = []
        let rejectedAtBoundary = 0
        let rejectedBeforeBoundary = 0
        private var payloadBytes = 0
        private let meetingID = MeetingID()

        mutating func apply(_ update: SlidingWindowTokenUpdate) throws -> [TranscriptSegment] {
            updateCount += 1
            timingCount += update.tokens.count
            payloadBytes += update.tokens.reduce(0) { $0 + $1.token.utf8.count }
            guard updateCount <= 10_000, payloadBytes <= 1_000_000,
                  update.tokens.count <= 10_000 else {
                throw DictationModelProbe.Failure.outputOverflow
            }
            let segments = try stream.segments(
                from: update, meetingID: meetingID, channel: .microphone, language: nil)
            mappedSegmentCount += segments.filter(\.isFinal).count
            self.segments.append(contentsOf: segments)
            return segments
        }
    }

    private struct State: Sendable {
        var reduction = StrictReduction()
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
                        let updates = await manager.tokenUpdates
                        consumer = Task {
                            for try await update in updates {
                                try Task.checkCancellation()
                                for segment in try state.withLock({ try $0.reduction.apply(update) }) {
                                    output.yield(segment)
                                }
                            }
                            try state.withLock { try $0.reduction.stream.finish() }
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
        let parity = await consumerParity(
            for: snapshot.reduction.segments, nativeText: snapshot.finalText, productionText: productionText)
        return Receipt(
            vendorFinal: try DictationModelProbe.score(
                hypothesis: snapshot.finalText, legacyCleanedText: snapshot.finalText, references: references),
            mappedAndCoalesced: try DictationModelProbe.score(result, references: references),
            matchesProductionText: productionText == result.hypothesis,
            updateCount: snapshot.reduction.updateCount, timingCount: snapshot.reduction.timingCount,
            rejectedAtBoundary: snapshot.reduction.rejectedAtBoundary,
            rejectedBeforeBoundary: snapshot.reduction.rejectedBeforeBoundary,
            mappedSegmentCount: snapshot.reduction.mappedSegmentCount, consumerParity: parity)
    }
    @MainActor
    static func consumerParity(
        for segments: [TranscriptSegment], nativeText: String, productionText: String
    ) -> ConsumerParity {
        var projection = DictationTranscriptProjection()
        let recording = RecordingController()
        for segment in segments {
            _ = projection.apply(segment)
            recording.receiveLiveCaption(segment)
        }
        return ConsumerParity(
            nativeMatchesProduction: nativeText == productionText,
            dictationMatchesNative: projection.finalText == nativeText,
            meetingMatchesNative: recording.captions.map(\.text).joined(separator: " ") == nativeText,
            previewsCleared: !projection.hasProvisionalPreview && recording.speechVolatileByChannel.isEmpty)
    }

}
