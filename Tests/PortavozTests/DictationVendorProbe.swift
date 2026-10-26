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

/// The rejected timestamp adapter, kept only to characterize why serving uses revisions.
extension ParakeetSegmentMapper {
    enum LiveFailure: Error { case missingTimings, invalidTimings }

    private struct LiveToken: Hashable, Sendable {
        let id: Int
        let piece: String
    }

    /// One reducer per native job. Starts identify emission positions; ends are
    /// display durations synthesized from the next token, not ownership cursors.
    /// Everything before the frontier is already owned. At the frontier, retain
    /// occurrence counts so equal-time subwords survive while replay is consumed
    /// only once. Retained state is limited to the current emission position.
    struct LiveStream: Sendable {
        private var frontier: TimeInterval?
        private var occurrences: [LiveToken: Int] = [:]
        private(set) var endTime: TimeInterval = 0
        private(set) var replayedAtFrontier = 0
        private(set) var replayedBeforeFrontier = 0

        mutating func segment( // swiftlint:disable:this function_parameter_count
            text: String,
            isConfirmed: Bool,
            confidence: Float,
            tokenTimings: [TokenTiming],
            meetingID: MeetingID,
            channel: AudioChannel,
            language: String?
        ) throws -> TranscriptSegment? {
            guard !tokenTimings.isEmpty else {
                guard text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw LiveFailure.missingTimings
                }
                return nil
            }
            guard tokenTimings.allSatisfy({
                $0.startTime.isFinite && $0.endTime.isFinite && $0.startTime >= 0 && $0.endTime >= $0.startTime
            }), zip(tokenTimings, tokenTimings.dropFirst()).allSatisfy({ $0.startTime <= $1.startTime }) else {
                throw LiveFailure.invalidTimings
            }

            var observed: [LiveToken: Int] = [:]
            var fresh: [TokenTiming] = []
            var nextFrontier = frontier
            var nextOccurrences = occurrences
            for timing in tokenTimings {
                if let frontier, timing.startTime < frontier {
                    replayedBeforeFrontier += 1
                    continue
                }
                let token = LiveToken(id: timing.tokenId, piece: timing.token)
                if timing.startTime == frontier {
                    observed[token, default: 0] += 1
                    if observed[token, default: 0] <= occurrences[token, default: 0] {
                        replayedAtFrontier += 1
                        continue
                    }
                }
                fresh.append(timing)
                if nextFrontier != timing.startTime {
                    nextFrontier = timing.startTime
                    nextOccurrences = [:]
                }
                nextOccurrences[token, default: 0] += 1
            }
            guard let first = fresh.first else { return nil }
            let end = fresh.reduce(first.endTime) { max($0, $1.endTime) }
            frontier = nextFrontier
            occurrences = nextOccurrences
            endTime = max(endTime, end)
            let body = joinedText(of: fresh)
            guard !body.isEmpty else { return nil }
            let startsWord = first.token.hasPrefix("▁") || first.token.first?.isWhitespace == true
            return TranscriptSegment(
                meetingID: meetingID, channel: channel, text: body, language: language,
                startTime: first.startTime, endTime: end,
                confidence: Double(confidence), isFinal: isConfirmed,
                liveUpdateMode: startsWord ? .tokenDelta : .tokenContinuation)
        }
    }
}
