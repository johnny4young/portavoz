import Foundation
import PortavozCore

/// APUN-005 stage 0 (D138): the deterministic end-of-turn endpointer.
///
/// Closing a caption row is delta-driven — a row closes only when the NEXT
/// Parakeet delta appends a new one. Silence therefore never closes a row,
/// and a question followed by silence would never produce an Apuntador card
/// during the meeting: the one moment the prompter is most needed is the one
/// moment it structurally cannot act. This policy decides when the still-open
/// remote row may be treated as a finished turn so detection can run early.
///
/// Deterministic by design. The semantic end-of-turn model this stage was
/// researched around (pipecat smart-turn v3: 8.7 MB, BSD-2, ~12 ms, 23
/// languages) ships ONNX-only today, so adopting it means either an
/// onnxruntime dependency or a self-hosted CoreML conversion — neither is
/// worth it while this heuristic covers the transcribable cases. The model's
/// slot and revisit trigger live in GAPS.
public enum TurnEndpointPolicy {
    /// Seconds without a new Parakeet delta before the open remote row is
    /// treated as a finished turn. The live window's worst-case structural
    /// latency is 1.4 s (1.0 s chunk + 0.4 s right context), so 2.0 s of
    /// delta silence implies the speaker actually stopped ≥ 0.6 s ago — the
    /// same sentence pause that would have closed the row had anyone kept
    /// talking (`CaptionCoalescer.systemSentencePauseSeconds`).
    public static let silenceSeconds: TimeInterval = 2.0

    /// Whether the open row is worth a speculative detection once the
    /// deadline fires. Mirrors the real-close gates exactly — remote
    /// channel, not noise, question-shaped or an owner mention — so
    /// speculation can never surface something a real close would not.
    public static func isTurnEndCandidate(
        channel: AudioChannel,
        text: String,
        confidence: Double?,
        ownerName: String?
    ) -> Bool {
        guard channel == .system else { return false }
        guard !TranscriptNoiseFilter.isLikelyNoise(text: text, confidence: confidence)
        else { return false }
        return QuestionHeuristic.looksLikeQuestion(text)
            || ownerName.map { QuestionHeuristic.mentions($0, in: text) } == true
    }

    /// One detection per (row, text length). The row stays OPEN after a
    /// speculative detection — presentation is untouched, and a late delta
    /// can still extend it. When the row later closes for real with the
    /// same text, re-detecting adds nothing; when the text grew, the
    /// candidate is genuinely new and detection must run again.
    public static func shouldDetect(
        after mark: SpeculativeTurnMark?,
        rowID: UUID,
        textCount: Int
    ) -> Bool {
        guard let mark, mark.rowID == rowID else { return true }
        return mark.textCount != textCount
    }
}

/// The receipt of one speculative detection: which row, at what text length.
public struct SpeculativeTurnMark: Equatable, Sendable {
    public let rowID: UUID
    public let textCount: Int

    public init(rowID: UUID, textCount: Int) {
        self.rowID = rowID
        self.textCount = textCount
    }
}
