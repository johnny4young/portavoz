import Foundation
import PortavozCore

/// One entry of the transcript as a document: a chapter heading placed before
/// the first row it covers, or a row marked where a new speaker's turn begins.
public enum TranscriptReadingItem: Sendable, Equatable, Identifiable {
    case chapter(MeetingTranscriptContent.Chapter)
    case row(MeetingTranscriptContent.Row, startsTurn: Bool)

    public enum Key: Hashable, Sendable {
        case chapter(TimeInterval)
        case row(UUID)
    }

    public var id: Key {
        switch self {
        case .chapter(let chapter): .chapter(chapter.id)
        case .row(let row, _): .row(row.id)
        }
    }

    /// A turn runs until another voice speaks; a chapter heading opens a new one.
    static func items(
        rows: [MeetingTranscriptContent.Row],
        chapters: [MeetingTranscriptContent.Chapter]
    ) -> [TranscriptReadingItem] {
        var items: [TranscriptReadingItem] = []
        items.reserveCapacity(rows.count + chapters.count)
        var pending = chapters[...]
        var previousVoice: Voice?
        for row in rows {
            var headed = false
            while let chapter = pending.first, chapter.startTime <= row.startTime {
                items.append(.chapter(chapter))
                pending = pending.dropFirst()
                headed = true
            }
            let voice = Voice(row)
            items.append(.row(row, startsTurn: headed || voice != previousVoice))
            previousVoice = voice
        }
        return items
    }

    /// The row right after each heading, mapped to that heading's start.
    static func chapterOpenings(in items: [TranscriptReadingItem]) -> [UUID: TimeInterval] {
        var openings: [UUID: TimeInterval] = [:]
        for (heading, next) in zip(items, items.dropFirst()) {
            if case .chapter(let chapter) = heading, case .row(let row, _) = next {
                openings[row.id] = chapter.startTime
            }
        }
        return openings
    }

    /// Unattributed rows still change turn when the channel does.
    private struct Voice: Equatable {
        let speakerID: SpeakerID?
        let channel: AudioChannel?

        init(_ row: MeetingTranscriptContent.Row) {
            speakerID = row.speakerID
            channel = row.speakerID == nil ? row.channel : nil
        }
    }
}
