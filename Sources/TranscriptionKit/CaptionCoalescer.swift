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
        // Low mic signal produces character noise ("DDDDD") — never a row.
        if TranscriptionTextFilter.isCharacterNoise(text) { return }

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
            text.contains(where: { ".!?…".contains($0) }),
            // A real sentence closer is 1-3 characters ("." / "?!" / "…");
            // longer runs ("....") are low-signal noise, not punctuation.
            text.count <= 3
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
    ///
    /// The live engine re-emits the tail of the previous chunk at every
    /// chunk boundary ("we added" + "ed a select all" + "all button"), so a
    /// naive concatenation stutters — a real 56-min meeting had the echo in
    /// 54% of its rows. The overlap trim below removes the longest character
    /// overlap between the row's end and the delta's start before joining.
    static func join(_ head: String, _ tail: String) -> String {
        let (trimmed, continuesWord) = trimOverlap(head: head, tail: tail)
        guard let first = trimmed.first else { return head }
        if continuesWord || ".,;:!?…)".contains(first) {
            return head + trimmed
        }
        return head + " " + trimmed
    }

    /// Longest suffix of `head` that the delta re-emits as its prefix,
    /// capped at 30 characters, minimum 3 ("select all" + "all button",
    /// "subscription" + "criptions page", "percent" + "cent now"). The
    /// deliberate trade-off is that a REAL immediate repetition ("very very
    /// good") also collapses — far rarer than the engine's chunk echo.
    /// Returns the delta with the echoed overlap removed, plus whether the
    /// leftover continues the head's last word ("subscription" +
    /// "criptions page" → rest "s page" glues: "subscriptions page").
    static func trimOverlap(head: String, tail: String) -> (rest: String, continuesWord: Bool) {
        let headCompare = head.lowercased()
        let tailCompare = tail.lowercased()
        let maxOverlap = min(30, headCompare.count, tailCompare.count)
        for length in stride(from: maxOverlap, through: 3, by: -1) {
            let suffix = headCompare.suffix(length)
            guard tailCompare.hasPrefix(suffix) else { continue }
            var rest = String(tail.dropFirst(length))
            if rest.first == " " {
                rest.removeFirst()
                return (rest, false)
            }
            // Mid-word cut: the leftover letters finish the head's word.
            return (rest, rest.first?.isLetter == true)
        }
        return (trimSplitWordEcho(head: headCompare, tail: tail), false)
    }

    /// English/Spanish words the split-word rule must never eat: they are
    /// legitimate sentence starters that happen to be common word suffixes
    /// ("the plan" + "an idea", "I said" + "id number").
    private static let protectedShortWords: Set<Substring> = [
        "an", "at", "as", "in", "on", "it", "is", "id", "be", "he", "me", "we",
        "do", "go", "no", "so", "to", "up", "or", "of", "us", "my", "by", "if",
        "es", "en", "un", "el", "la", "lo", "de", "se", "te", "si", "ya", "ha", "le"
    ]

    /// The engine also splits WORDS at chunk boundaries and re-emits the
    /// fragment: "we added" + "ed a select…". The 2-character overlap is
    /// below the general minimum, so this narrower rule handles it: drop
    /// the tail's first token when it is a strict suffix of the head's last
    /// word AND not a real short word on its own.
    private static func trimSplitWordEcho(head: String, tail: String) -> String {
        let token = tail.lowercased().prefix { $0.isLetter }
        guard token.count >= 2, token.count <= 10,
            !protectedShortWords.contains(token),
            let lastWord = head.split(whereSeparator: { !$0.isLetter }).last,
            lastWord.count > token.count,
            lastWord.hasSuffix(token)
        else { return tail }
        var rest = String(tail.dropFirst(token.count))
        if rest.first == " " { rest.removeFirst() }
        return rest
    }
}
