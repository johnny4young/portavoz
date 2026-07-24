import Foundation
import PortavozCore

/// Renders a diarized transcript as SRT or WebVTT. Cue discipline over raw
/// dumping: consecutive same-speaker rows merge only while the cue stays
/// caption-sized, the arrow separator can never appear inside cue text, and
/// timestamps carry millisecond precision in each format's exact notation —
/// SRT uses a comma, VTT a period, and players reject the wrong one.
public enum SubtitleExport {
    public enum Format: String, Sendable {
        case srt
        case vtt
    }

    /// A merged cue longer than this many seconds stops absorbing rows —
    /// subtitle guidelines cap display time well below long paragraphs.
    static let maximumCueSeconds: TimeInterval = 6
    /// Two caption lines of ~42 characters; beyond it a cue reads as a wall.
    static let maximumCueCharacters = 84

    public static func render(
        _ format: Format,
        segments: [TranscriptSegment],
        speakers: [Speaker]
    ) -> String {
        let cues = cues(segments: segments, speakers: speakers)
        switch format {
        case .srt:
            return cues.enumerated().map { index, cue in
                "\(index + 1)\n"
                    + "\(timestamp(cue.start, separator: ",")) --> "
                    + "\(timestamp(cue.end, separator: ","))\n"
                    + cue.displayText
            }.joined(separator: "\n\n") + "\n"
        case .vtt:
            let body = cues.map { cue in
                "\(timestamp(cue.start, separator: ".")) --> "
                    + "\(timestamp(cue.end, separator: "."))\n"
                    + cue.displayText
            }.joined(separator: "\n\n")
            return "WEBVTT\n\n" + body + "\n"
        }
    }

    struct Cue: Equatable {
        var start: TimeInterval
        var end: TimeInterval
        var speakerID: SpeakerID?
        var speaker: String?
        var text: String

        var displayText: String {
            guard let speaker else { return text }
            return "\(speaker): \(text)"
        }
    }

    /// Lexical rows only (the transcript-wide minimum bar), merged while the
    /// same speaker keeps talking AND the cue stays caption-sized in both
    /// duration and characters.
    static func cues(
        segments: [TranscriptSegment],
        speakers: [Speaker]
    ) -> [Cue] {
        let names = Dictionary(uniqueKeysWithValues: speakers.map {
            ($0.id, speakerName($0))
        })
        var cues: [Cue] = []
        for segment in segments {
            let text = inlineText(segment.text)
            guard TranscriptContentPolicy.hasLexicalContent(text) else { continue }
            let speaker = segment.speakerID.flatMap { names[$0] }
            if var last = cues.last,
                last.speakerID == segment.speakerID,
                segment.endTime - last.start <= maximumCueSeconds,
                last.displayText.count + text.count + 1 <= maximumCueCharacters {
                last.end = max(last.end, segment.endTime)
                last.text += " " + text
                cues[cues.count - 1] = last
            } else {
                cues.append(Cue(
                    start: segment.startTime,
                    end: max(segment.endTime, segment.startTime),
                    speakerID: segment.speakerID,
                    speaker: speaker,
                    text: text))
            }
        }
        return cues
    }

    /// Subtitle payload is line-oriented. Collapse every whitespace run so a
    /// transcript or user-assigned speaker name cannot inject a second line or
    /// cue, and neutralize the timestamp arrow in both fields.
    static func inlineText(_ value: String) -> String {
        value
            .replacingOccurrences(of: "-->", with: "->")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private static func speakerName(_ speaker: Speaker) -> String {
        let preferred = speaker.isMe
            ? (speaker.displayName ?? "Me")
            : (speaker.displayName ?? speaker.label)
        let normalized = inlineText(preferred)
        if !normalized.isEmpty { return normalized }
        return speaker.isMe ? "Me" : inlineText(speaker.label)
    }

    /// Milliseconds from seconds without float drift at the boundary: the
    /// classic subtitle bug class is unit slippage (centiseconds read as
    /// milliseconds), so the math stays in integer milliseconds throughout.
    static func timestamp(_ seconds: TimeInterval, separator: String) -> String {
        let totalMilliseconds = Int((max(0, seconds) * 1000).rounded())
        let milliseconds = totalMilliseconds % 1000
        let totalSeconds = totalMilliseconds / 1000
        return String(
            format: "%02d:%02d:%02d%@%03d",
            totalSeconds / 3600, (totalSeconds / 60) % 60, totalSeconds % 60,
            separator, milliseconds)
    }
}
