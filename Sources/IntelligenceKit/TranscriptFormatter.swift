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
    /// 6000 chars overflowed it in practice (meeting text runs ~2.5–3
    /// chars/token, and notes output shares the window).
    public static let onDeviceChunkBudget = 4500

    /// Material cap for the final structured pass, tighter than the map
    /// budget: guided generation adds the response schema to the prompt
    /// and the structured output itself needs headroom.
    public static let onDeviceReduceBudget = 3000

    /// `[mm:ss] Label: text` — labels come from the attribution pass;
    /// unattributed segments show the channel instead ("system?").
    public static func format(segments: [TranscriptSegment], speakers: [Speaker]) -> String {
        let labelsByID = Dictionary(uniqueKeysWithValues: speakers.map { ($0.id, displayLabel($0)) })
        return segments.map { segment in
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
        let lines = segments.enumerated().map { index, segment in
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
    /// cutting only at line boundaries (a segment never straddles chunks).
    public static func chunk(_ transcript: String, budget: Int) -> [String] {
        guard transcript.count > budget else {
            return transcript.isEmpty ? [] : [transcript]
        }
        var chunks: [String] = []
        var current = ""
        for line in transcript.split(separator: "\n", omittingEmptySubsequences: true) {
            if !current.isEmpty, current.count + line.count + 1 > budget {
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
