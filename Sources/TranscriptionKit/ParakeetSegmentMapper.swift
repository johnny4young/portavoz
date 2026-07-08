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

    // Firma interna estable: cada parámetro es un dato distinto del update.
    /// One live sliding-window update → one segment holding only the *new*
    /// audio's tokens. Once the window slides, FluidAudio re-decodes the
    /// whole left context per update and its token dedup misses most of it
    /// (verified 2026-07-06 with 1.2 s chunks: every confirmed update
    /// repeated ~11 s of text) — so we cut the overlap ourselves using the
    /// stream-absolute token timings: keep tokens starting strictly after
    /// the last emitted edge, rebuild the text from what's left. Returns
    /// nil for silence windows and pure re-decodes.
    static func segment( // swiftlint:disable:this function_parameter_count
        text: String,
        isConfirmed: Bool,
        confidence: Float,
        tokenTimings: [TokenTiming],
        meetingID: MeetingID,
        channel: AudioChannel,
        language: String?,
        fallbackTime: TimeInterval
    ) -> TranscriptSegment? {
        let start: TimeInterval
        let end: TimeInterval
        let body: String

        if tokenTimings.isEmpty {
            // Rare timing-less update: trust the text, anchor to the edge.
            body = text.trimmingCharacters(in: .whitespacesAndNewlines)
            start = fallbackTime
            end = fallbackTime
        } else {
            let fresh = tokenTimings.filter { $0.startTime > fallbackTime }
            guard !fresh.isEmpty else { return nil }
            body = joinedText(of: fresh)
            start = fresh.map(\.startTime).min() ?? fallbackTime
            end = fresh.map(\.endTime).max() ?? fallbackTime
        }
        guard !body.isEmpty else { return nil }

        return TranscriptSegment(
            meetingID: meetingID,
            channel: channel,
            text: body,
            language: language,
            startTime: start,
            endTime: max(start, end),
            confidence: Double(confidence),
            isFinal: isConfirmed
        )
    }

    // Firma interna estable: cada parámetro es un dato distinto del batch.
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
