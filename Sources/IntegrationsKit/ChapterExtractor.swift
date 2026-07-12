import Foundation
import PortavozCore

/// Derives chapter markers from the attributed transcript — 100% local,
/// no model. A chapter starts at a natural break: a long pause between
/// segments, or once the running chapter has grown past a cap so a long
/// unbroken stretch still gets split. Each label is a REAL excerpt (the
/// opening segment's first sentence) — never invented content.
public enum ChapterExtractor {
    public struct Chapter: Sendable, Equatable, Identifiable {
        public let startTime: TimeInterval
        public let title: String
        public var id: TimeInterval { startTime }
    }

    /// A pause at least this long between two segments can open a chapter.
    static let pauseThreshold: TimeInterval = 10
    /// …but never sooner than this after the last chapter, so a run of
    /// short, spaced-out turns doesn't shatter into a chapter each.
    static let minChapterSpacing: TimeInterval = 120
    /// A chapter that has run this long splits at the next segment anyway,
    /// so a gap-free stretch still gets chaptered.
    static let maxChapterLength: TimeInterval = 300
    /// Labels are trimmed to a scannable length.
    static let maxTitleLength = 60

    public static func chapters(from segments: [TranscriptSegment]) -> [Chapter] {
        let ordered = segments
            .filter { $0.endTime > $0.startTime && !$0.text.isEmpty }
            .sorted { $0.startTime < $1.startTime }
        guard let first = ordered.first else { return [] }

        var chapters: [Chapter] = [
            Chapter(startTime: first.startTime, title: title(from: first.text))
        ]
        var chapterStart = first.startTime
        var previousEnd = first.endTime

        for segment in ordered.dropFirst() {
            let pause = segment.startTime - previousEnd
            let sinceChapter = segment.startTime - chapterStart
            let breakByPause = pause >= pauseThreshold && sinceChapter >= minChapterSpacing
            let breakByLength = sinceChapter >= maxChapterLength
            if breakByPause || breakByLength {
                chapters.append(
                    Chapter(startTime: segment.startTime, title: title(from: segment.text)))
                chapterStart = segment.startTime
            }
            previousEnd = segment.endTime
        }
        // A single chapter tells the reader nothing the header didn't — a
        // rail earns its place only once the meeting actually breaks up.
        return chapters.count > 1 ? chapters : []
    }

    /// The opening segment's first sentence, trimmed — a real line from the
    /// meeting, not a summary of it.
    private static func title(from text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let sentenceEnd = trimmed.firstIndex { ".!?".contains($0) }
        let sentence = sentenceEnd.map { String(trimmed[..<$0]) } ?? trimmed
        let clean = sentence.trimmingCharacters(in: .whitespaces)
        if clean.count <= maxTitleLength { return clean }
        let cut = clean.prefix(maxTitleLength).trimmingCharacters(in: .whitespaces)
        return "\(cut)…"
    }
}
