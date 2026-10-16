import FluidAudio
import Foundation
import PortavozCore

/// Pure mapping from FluidAudio results to domain `TranscriptSegment`s.
/// Kept side-effect free so the shapes (timing fallbacks, pause splitting)
/// are unit-testable without models.
enum ParakeetSegmentMapper {
    /// A new segment starts after this much silence between tokens. Note:
    /// TDT timings rarely show real gaps (a token's end extends to the next
    /// token's start), so in practice punctuation does most of the cutting.
    static let pauseSplitSeconds: TimeInterval = 0.5
    /// …or when the current segment grows past this duration.
    static let maxSegmentSeconds: TimeInterval = 15
    /// …or right after sentence-final punctuation (Parakeet v3 emits it).
    /// Sentence-sized segments are what makes speaker attribution work:
    /// a multi-sentence segment usually spans several diarization turns.
    static let sentenceTerminators: Set<Character> = [".", "?", "!", "…"]

    enum RevisionFailure: Error { case mismatchedJobOrChannel }

    /// Serving path: only producer positions decide ownership. The older
    /// LiveStream remains a characterization of the rejected timestamp adapter.
    struct RevisionStream: Sendable {
        private var reducer = ParakeetTokenRevisionReducer()
        private let previewID = UUID()
        private var jobID: UUID?
        private var binding: (MeetingID, AudioChannel)?

        func finish() throws { try reducer.finish() }

        mutating func segments(
            from update: SlidingWindowTokenUpdate, meetingID: MeetingID,
            channel: AudioChannel, language: String?
        ) throws -> [TranscriptSegment] {
            let revision = update.revision
            guard jobID == nil || jobID == revision.jobID,
                  binding == nil || (binding?.0 == meetingID && binding?.1 == channel) else {
                throw RevisionFailure.mismatchedJobOrChannel
            }
            let tokens = update.tokens.map {
                ParakeetTokenRevisionReducer.Token(
                    id: $0.tokenId, piece: $0.token, start: $0.startTime,
                    end: $0.endTime, confidence: $0.confidence)
            }
            let projection = try reducer.apply(tokens, revision: .init(
                ordinal: revision.ordinal, previousTokenCount: revision.previousTokenCount,
                retainedTokenCount: revision.retainedTokenCount,
                stableTokenCount: revision.stableTokenCount,
                window: revision.window, center: revision.center, isTerminal: revision.isTerminal))
            jobID = revision.jobID
            binding = (meetingID, channel)
            var segments: [TranscriptSegment] = []
            if let first = projection.committed.first {
                segments.append(segment(
                    projection.committed, first: first, meetingID: meetingID,
                    channel: channel, language: language, preview: false))
            }
            // Empty preview is an explicit clear, even when no tokens commit.
            let empty = ParakeetTokenRevisionReducer.Token(
                id: 0, piece: "", start: Double(revision.center.upperBound) / Double(ASRConstants.sampleRate),
                end: Double(revision.center.upperBound) / Double(ASRConstants.sampleRate), confidence: 0)
            segments.append(segment(
                projection.provisional, first: projection.provisional.first ?? empty,
                meetingID: meetingID, channel: channel, language: language, preview: true))
            return segments
        }

        private func segment(
            _ tokens: [ParakeetTokenRevisionReducer.Token],
            first: ParakeetTokenRevisionReducer.Token, meetingID: MeetingID,
            channel: AudioChannel, language: String?, preview: Bool
        ) -> TranscriptSegment {
            let startsWord = first.piece.hasPrefix("▁") || first.piece.first?.isWhitespace == true
            let body = tokens.map(\.piece).joined().replacingOccurrences(of: "▁", with: " ")
                .split(separator: " ").joined(separator: " ")
            let confidence: Double? = tokens.isEmpty ? nil
                : Double(tokens.reduce(Float(0)) { $0 + $1.confidence }) / Double(tokens.count)
            return TranscriptSegment(
                id: preview ? previewID : UUID(), meetingID: meetingID, channel: channel,
                text: preview && startsWord && !body.isEmpty ? " " + body : body,
                language: language, startTime: first.start,
                endTime: tokens.reduce(first.end) { max($0, $1.end) },
                confidence: confidence,
                isFinal: !preview,
                liveUpdateMode: preview ? .tokenPreview : (startsWord ? .tokenDelta : .tokenContinuation))
        }
    }

    // Stable internal signature: every parameter is a distinct batch datum.
    /// Splits a batch result into segments at pauses (or a max duration),
    /// rebuilding each segment's text from its SentencePiece tokens. With no
    /// timings available the whole file becomes a single segment.
    static func segments( // swiftlint:disable:this function_parameter_count
        fromBatchText text: String,
        tokenTimings: [TokenTiming],
        audioDuration: TimeInterval,
        confidence: Double,
        meetingID: MeetingID,
        channel: AudioChannel,
        language: String?
    ) -> [TranscriptSegment] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        guard !tokenTimings.isEmpty else {
            return [
                TranscriptSegment(
                    meetingID: meetingID,
                    channel: channel,
                    text: trimmed,
                    language: language,
                    startTime: 0,
                    endTime: audioDuration,
                    confidence: confidence,
                    isFinal: true
                )
            ]
        }

        var groups: [[TokenTiming]] = []
        var current: [TokenTiming] = []
        for timing in tokenTimings {
            if let last = current.last,
                let first = current.first,
                timing.startTime - last.endTime > pauseSplitSeconds
                    || timing.endTime - first.startTime > maxSegmentSeconds
                    || endsSentence(last) {
                groups.append(current)
                current = []
            }
            current.append(timing)
        }
        if !current.isEmpty { groups.append(current) }

        return groups.compactMap { group in
            guard let first = group.first, let last = group.last else { return nil }
            let text = joinedText(of: group)
            guard !text.isEmpty else { return nil }
            let meanConfidence =
                group.map { Double($0.confidence) }.reduce(0, +) / Double(group.count)
            return TranscriptSegment(
                meetingID: meetingID,
                channel: channel,
                text: text,
                language: language,
                startTime: first.startTime,
                endTime: max(first.startTime, last.endTime),
                confidence: meanConfidence,
                isFinal: true
            )
        }
    }

    static func endsSentence(_ timing: TokenTiming) -> Bool {
        guard let last = timing.token.trimmingCharacters(in: .whitespaces).last else {
            return false
        }
        return sentenceTerminators.contains(last)
    }

    /// SentencePiece pieces use "▁" as the word boundary; some FluidAudio
    /// paths pre-normalize it to a space. Handle both, then collapse runs.
    static func joinedText(of timings: [TokenTiming]) -> String {
        timings.map(\.token).joined()
            .replacingOccurrences(of: "▁", with: " ")
            .split(separator: " ")
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
