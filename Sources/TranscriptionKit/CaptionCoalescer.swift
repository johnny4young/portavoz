import Foundation
import PortavozCore

/// Merges live caption deltas into readable, sentence-shaped rows.
///
/// The live path emits sub-sentence deltas (one per ~1 s chunk); as list rows
/// they read as noise ("ration of" / "ation overall") and explode the row
/// count on long meetings. The coalescer grows the newest row while it stays
/// on the same channel, so one intervention reads as one line, and starts a
/// new row when the sentence closed and the speaker actually paused.
///
/// Only the newest row ever grows — everything before it is frozen, which is
/// what lets consumers (live translation) treat closed rows as immutable.
public struct CaptionCoalescer: Sendable {
    /// A silence this long always starts a new row, even mid-sentence.
    public var maxGapSeconds: TimeInterval
    /// After a closed sentence, a pause this long starts a new row; quicker
    /// follow-ups keep flowing speech together.
    public var sentencePauseSeconds: TimeInterval
    /// Remote/system audio contains every non-user speaker. Without live
    /// diarization, a shorter post-sentence pause keeps back-to-back people
    /// visible as separate "Ellos" rows before the refine pass.
    public var systemSentencePauseSeconds: TimeInterval
    /// A row longer than this closes at the next delta regardless, keeping
    /// rows scannable.
    public var maxRowCharacters: Int

    public init(
        maxGapSeconds: TimeInterval = 6.0,
        sentencePauseSeconds: TimeInterval = 2.0,
        systemSentencePauseSeconds: TimeInterval = 0.6,
        maxRowCharacters: Int = 280
    ) {
        self.maxGapSeconds = maxGapSeconds
        self.sentencePauseSeconds = sentencePauseSeconds
        self.systemSentencePauseSeconds = systemSentencePauseSeconds
        self.maxRowCharacters = maxRowCharacters
    }

    /// Folds one live delta into the caption list: extends the newest row
    /// when it belongs to the same channel and is still "open", appends a
    /// fresh row otherwise. The merged row keeps its identity (`id`,
    /// `startTime`) so UI diffing and translation caches stay stable.
    public func apply(_ segment: TranscriptSegment, to captions: inout [TranscriptSegment]) {
        let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let hasLexicalContent = TranscriptionTextFilter.hasLexicalContent(text)
        if !hasLexicalContent {
            appendPunctuationOnlyDelta(text, from: segment, to: &captions)
            return
        }

        guard let last = captions.last, last.channel == segment.channel,
            shouldExtend(last, with: segment)
        else {
            var fresh = segment
            fresh.text = text
            captions.append(fresh)
            return
        }

        captions[captions.count - 1] = TranscriptSegment(
            id: last.id,
            meetingID: last.meetingID,
            speakerID: last.speakerID,
            channel: last.channel,
            text: Self.join(last.text, text),
            language: last.language ?? segment.language,
            startTime: last.startTime,
            endTime: max(last.endTime, segment.endTime),
            confidence: last.confidence,
            isFinal: segment.isFinal
        )
    }

    private func shouldExtend(_ last: TranscriptSegment, with segment: TranscriptSegment) -> Bool {
        let gap = segment.startTime - last.endTime
        guard gap < maxGapSeconds else { return false }
        guard last.text.count < maxRowCharacters else { return false }
        if Self.endsSentence(last.text) {
            return gap < sentencePauseSeconds(for: last.channel)
        }
        return true
    }

    private func sentencePauseSeconds(for channel: AudioChannel) -> TimeInterval {
        switch channel {
        case .system, .room:
            systemSentencePauseSeconds
        case .microphone:
            sentencePauseSeconds
        }
    }

    private func appendPunctuationOnlyDelta(
        _ text: String,
        from segment: TranscriptSegment,
        to captions: inout [TranscriptSegment]
    ) {
        guard
            let last = captions.last,
            last.channel == segment.channel,
            shouldExtend(last, with: segment),
            text.contains(where: { ".!?…".contains($0) })
        else { return }

        captions[captions.count - 1] = TranscriptSegment(
            id: last.id,
            meetingID: last.meetingID,
            speakerID: last.speakerID,
            channel: last.channel,
            text: Self.join(last.text, text),
            language: last.language ?? segment.language,
            startTime: last.startTime,
            endTime: max(last.endTime, segment.endTime),
            confidence: last.confidence,
            isFinal: segment.isFinal
        )
    }

    static func endsSentence(_ text: String) -> Bool {
        guard let final = text.trimmingCharacters(in: .whitespacesAndNewlines).last else {
            return false
        }
        return ".!?…".contains(final)
    }

    /// Deltas that open with punctuation glue onto the row; words get a space.
    static func join(_ head: String, _ tail: String) -> String {
        guard let first = tail.first else { return head }
        if ".,;:!?…)".contains(first) {
            return head + tail
        }
        return head + " " + tail
    }
}
