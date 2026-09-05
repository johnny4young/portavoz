import Foundation
import PortavozCore

/// Renders attributed transcripts into prompt text and slices them into
/// model-sized chunks. Pure functions — the shapes (labels, budgets,
/// boundaries) are unit-testable without any model.
public enum TranscriptFormatter {
    public struct EvidenceMaterial: Sendable {
        public let text: String
        public let segmentIDsByTag: [String: UUID]

        public init(text: String, segmentIDsByTag: [String: UUID]) {
            self.text = text
            self.segmentIDsByTag = segmentIDsByTag
        }
    }

    /// Character budget per map-phase chunk for the on-device model. Its
    /// context window is 4096 tokens *including* instructions and output;
    /// 6,000 and later 4,500 chars overflowed it in practice as OS-owned
    /// instructions/tokenization evolved; notes output also shares the
    /// window. Four thousand chars keeps the 250-token result at a bounded
    /// 4× compression target while reserving model-call headroom.
    public static let onDeviceChunkBudget = 4000

    /// Material cap for the final structured pass, tighter than the map
    /// budget: guided generation adds the response schema to the prompt
    /// and the structured output itself needs headroom.
    public static let onDeviceReduceBudget = 3000

    /// Finite floor for retrying a map chunk after the framework reports a
    /// context overflow. A failure at this size propagates instead of looping.
    public static let onDeviceRetryFloor = 500

    public static func nextOnDeviceRetryBudget(for characterCount: Int) -> Int? {
        guard characterCount > onDeviceRetryFloor else { return nil }
        let budget = max(onDeviceRetryFloor, characterCount / 2)
        return budget < characterCount ? budget : nil
    }

    /// `[mm:ss] Label: text` — labels come from the attribution pass;
    /// unattributed segments show the channel instead ("system?").
    public static func format(segments: [TranscriptSegment], speakers: [Speaker]) -> String {
        let labelsByID = Dictionary(uniqueKeysWithValues: speakers.map { ($0.id, displayLabel($0)) })
        return TranscriptContentPolicy.retainLexicalSegments(segments).map { segment in
            let label = segment.speakerID.flatMap { labelsByID[$0] } ?? "\(segment.channel.rawValue)?"
            return "[\(timestamp(segment.startTime))] \(label): \(segment.text)"
        }.joined(separator: "\n")
    }

    /// Provider-only transcript shape. Compact stable tags let a model cite
    /// exact request segments without exposing UUID noise in the prompt.
    public static func formatWithEvidence(
        segments: [TranscriptSegment],
        speakers: [Speaker]
    ) -> EvidenceMaterial {
        let labelsByID = Dictionary(uniqueKeysWithValues: speakers.map { ($0.id, displayLabel($0)) })
        var idsByTag: [String: UUID] = [:]
        let lexicalSegments = TranscriptContentPolicy.retainLexicalSegments(segments)
        let lines = lexicalSegments.enumerated().map { index, segment in
            let tag = "E\(index + 1)"
            idsByTag[tag] = segment.id
            let rawLabel = segment.speakerID.flatMap { labelsByID[$0] }
                ?? "\(segment.channel.rawValue)?"
            let label = escapeEvidenceTags(in: rawLabel)
            let text = escapeEvidenceTags(in: segment.text)
            return "[\(tag)] [\(timestamp(segment.startTime))] \(label): \(text)"
        }
        return EvidenceMaterial(
            text: lines.joined(separator: "\n"),
            segmentIDsByTag: idsByTag)
    }

    /// Accepts only tags that were actually emitted for this request,
    /// deduplicates in model order, and bounds the evidence shown in UI.
    public static func resolveEvidenceTags(
        _ tags: [String],
        segmentIDsByTag: [String: UUID],
        limit: Int = 4
    ) -> [UUID] {
        guard limit > 0 else { return [] }
        var seen: Set<UUID> = []
        var resolved: [UUID] = []
        for tag in tags.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }) {
            guard let id = segmentIDsByTag[tag], seen.insert(id).inserted else { continue }
            resolved.append(id)
            if resolved.count == limit { break }
        }
        return resolved
    }

    /// Prevents transcript text, speaker names, or user notes from looking
    /// like provider-owned source tags inside one prompt.
    static func escapeEvidenceTags(in text: String) -> String {
        text.replacingOccurrences(
            of: #"\[E([0-9]+)\]"#,
            with: "[quoted-E$1]",
            options: .regularExpression)
    }

    /// Splits transcript text into chunks of at most `budget` characters,
    /// keeping line boundaries whenever the utterance itself fits. A single
    /// oversized utterance is split at Character boundaries instead of being
    /// allowed to exceed the model window. Nonpositive inputs use a
    /// one-character preservation floor rather than dropping material.
    public static func chunk(_ transcript: String, budget: Int) -> [String] {
        let effectiveBudget = max(1, budget)
        guard transcript.count > effectiveBudget else {
            return transcript.isEmpty ? [] : [transcript]
        }
        var chunks: [String] = []
        var current = ""
        for line in transcript.split(separator: "\n", omittingEmptySubsequences: true) {
            if line.count > effectiveBudget {
                if !current.isEmpty {
                    chunks.append(current)
                    current = ""
                }
                var start = line.startIndex
                while start < line.endIndex {
                    let end = line.index(
                        start,
                        offsetBy: effectiveBudget,
                        limitedBy: line.endIndex) ?? line.endIndex
                    let slice = String(line[start..<end])
                    if end == line.endIndex {
                        current = slice
                    } else {
                        chunks.append(slice)
                    }
                    start = end
                }
                continue
            }
            if !current.isEmpty, current.count + line.count + 1 > effectiveBudget {
                chunks.append(current)
                current = ""
            }
            current += current.isEmpty ? String(line) : "\n\(line)"
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    static func displayLabel(_ speaker: Speaker) -> String {
        speaker.displayName ?? speaker.label
    }

    static func timestamp(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
