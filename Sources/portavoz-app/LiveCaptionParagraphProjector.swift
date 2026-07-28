import Foundation
import PortavozCore

/// Builds readable live paragraphs without changing captured evidence.
///
/// The coalescer and diarizer own raw caption identity because translation,
/// Companion, and the rolling summary consume those rows. This projector is
/// presentation-only: it groups consecutive rows only when Portavoz knows
/// they belong to the same voice, then keeps the first source id stable for
/// SwiftUI diffing. Generic `Them` rows are never grouped because two
/// back-to-back people may still be waiting for a live diarization label.
enum LiveCaptionParagraphProjector {
    struct Projection {
        let segments: [TranscriptSegment]
        let translations: [UUID: String]
    }

    static func project(
        captions: [TranscriptSegment],
        liveSpeakerLabels: [UUID: String],
        translations: [UUID: String],
        maxGapSeconds: TimeInterval = 4,
        maxCharacters: Int = 420
    ) -> Projection {
        var projected: [TranscriptSegment] = []
        var sourceIDsByParagraph: [[UUID]] = []
        var voiceKeys: [String?] = []

        for caption in captions {
            let voiceKey = voiceKey(for: caption, labels: liveSpeakerLabels)
            if let index = projected.indices.last,
                let voiceKey,
                voiceKeys[index] == voiceKey,
                caption.startTime - projected[index].endTime <= maxGapSeconds,
                projected[index].text.count + caption.text.count + 1 <= maxCharacters {
                let previous = projected[index]
                projected[index] = TranscriptSegment(
                    id: previous.id,
                    meetingID: previous.meetingID,
                    speakerID: previous.speakerID ?? caption.speakerID,
                    channel: previous.channel,
                    text: join(previous.text, caption.text),
                    language: previous.language == caption.language
                        ? previous.language : nil,
                    startTime: previous.startTime,
                    endTime: max(previous.endTime, caption.endTime),
                    confidence: previous.confidence,
                    isFinal: caption.isFinal)
                sourceIDsByParagraph[index].append(caption.id)
            } else {
                projected.append(caption)
                sourceIDsByParagraph.append([caption.id])
                voiceKeys.append(voiceKey)
            }
        }

        var projectedTranslations: [UUID: String] = [:]
        for (index, segment) in projected.enumerated() {
            let pieces = sourceIDsByParagraph[index].compactMap { translations[$0] }
            if !pieces.isEmpty {
                projectedTranslations[segment.id] = pieces.joined(separator: " ")
            }
        }
        return Projection(segments: projected, translations: projectedTranslations)
    }

    private static func voiceKey(
        for segment: TranscriptSegment,
        labels: [UUID: String]
    ) -> String? {
        if segment.channel == .microphone { return "Me" }
        return labels[segment.id]
    }

    private static func join(_ head: String, _ tail: String) -> String {
        guard let first = tail.first else { return head }
        if ".,;:!?…)".contains(first) { return head + tail }
        return head + " " + tail
    }
}
