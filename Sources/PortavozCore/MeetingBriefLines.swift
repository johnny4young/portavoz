import Foundation

/// What each person said in the previous occurrence of an upcoming event.
public struct MeetingBriefLines: Sendable, Equatable {
    /// The app's six-voice rule, most talkative first.
    public static let maximumPeople = 6
    public static let maximumLinesPerPerson = 3
    /// Quotes only fill a person up to this many lines.
    public static let quoteFillCount = 2
    private static let minimumQuoteWords = 4
    public static let maximumQuoteLength = 160

    /// One occurrence of a calendar event; recurring events share `eventID`.
    public struct Occurrence: Sendable, Hashable {
        public let eventID: String
        public let startAt: Date

        public init(eventID: String, startAt: Date) {
            self.eventID = eventID
            self.startAt = startAt
        }
    }

    /// An occurrence's chosen source and when its lines were built.
    public struct SourceState: Sendable, Equatable {
        public let sourceMeetingID: MeetingID
        /// Nil while a change waits for the next read to rebuild the lines.
        public let linesBuiltAt: Date?

        public init(sourceMeetingID: MeetingID, linesBuiltAt: Date?) {
            self.sourceMeetingID = sourceMeetingID
            self.linesBuiltAt = linesBuiltAt
        }
    }

    public enum Kind: String, Sendable, Equatable {
        case quote
        case commitment
        case question
    }

    public enum Status: Sendable, Equatable {
        case said
        case unresolved
        case open(due: Date?)
        case closed

        public var isPending: Bool {
            switch self {
            case .unresolved, .open: true
            case .said, .closed: false
            }
        }
    }

    public struct Line: Sendable, Equatable {
        public let kind: Kind
        public let text: String
        /// nil when the line has no transcript evidence to seek to.
        public let segmentID: UUID?
        public let time: TimeInterval
        public let status: Status

        public init(kind: Kind, text: String, segmentID: UUID?, time: TimeInterval, status: Status) {
            self.kind = kind
            self.text = text
            self.segmentID = segmentID
            self.time = time
            self.status = status
        }
    }

    public struct Person: Sendable, Equatable {
        public let speakerID: SpeakerID
        public let personID: PersonID?
        public let isMe: Bool
        public let label: String
        public let displayName: String?
        public let lines: [Line]

        public init(
            speakerID: SpeakerID, personID: PersonID?, isMe: Bool, label: String,
            displayName: String?, lines: [Line]
        ) {
            self.speakerID = speakerID
            self.personID = personID
            self.isMe = isMe
            self.label = label
            self.displayName = displayName
            self.lines = lines
        }

        /// The one line a preview shows: the earliest still pending, else the
        /// earliest commitment or question, else the first quote.
        public var lead: Line? {
            lines.first(where: \.status.isPending)
                ?? lines.first { $0.kind != .quote }
                ?? lines.first
        }
    }

    public let occurrence: Occurrence
    public let sourceMeetingID: MeetingID
    public let preparedAt: Date
    /// Most talkative first; a person without lines is absent.
    public let people: [Person]

    public init(
        occurrence: Occurrence, sourceMeetingID: MeetingID, preparedAt: Date, people: [Person]
    ) {
        self.occurrence = occurrence
        self.sourceMeetingID = sourceMeetingID
        self.preparedAt = preparedAt
        self.people = people
    }

    /// One readable line a person spoke.
    public struct Spoken: Sendable, Equatable {
        public let segmentID: UUID?
        public let text: String
        public let start: TimeInterval

        public init(segmentID: UUID?, text: String, start: TimeInterval) {
            self.segmentID = segmentID
            self.text = text
            self.start = start
        }
    }

    /// Per person, at most `maximumPeople` of `speakers`: pending lines first
    /// within a kind, then quotes up to the fill count, returned in time order.
    /// `tracked` holds commitments then questions per speaker.
    public static func select(
        speakers: [SpeakerID],
        tracked: [SpeakerID: [Line]],
        spoken: [SpeakerID: [Spoken]]
    ) -> [(speakerID: SpeakerID, lines: [Line])] {
        speakers.prefix(maximumPeople).compactMap { speaker in
            var chosen = Array((tracked[speaker] ?? []).prefix(maximumLinesPerPerson))
            let used = Set(chosen.compactMap(\.segmentID))
            let quotes = (spoken[speaker] ?? [])
                .filter { line in line.segmentID.map { !used.contains($0) } ?? true }
                .compactMap { line in quote(line.text).map { (line: line, text: $0) } }
                .sorted { ($1.line.text.count, $0.line.start) < ($0.line.text.count, $1.line.start) }
            chosen += quotes.prefix(max(0, quoteFillCount - chosen.count)).map {
                Line(kind: .quote, text: $0.text, segmentID: $0.line.segmentID,
                     time: max(0, $0.line.start), status: .said)
            }
            guard !chosen.isEmpty else { return nil }
            // A stable sort keeps the priority order between lines at the same time.
            let ordered = chosen.enumerated()
                .sorted { ($0.element.time, $0.offset) < ($1.element.time, $1.offset) }
                .map(\.element)
            return (speaker, ordered)
        }
    }

    /// What is still pending goes first, so the per-person cap keeps it.
    public static func pendingFirst(_ lines: [Line]) -> [Line] {
        lines.enumerated()
            .sorted { first, second in
                let pending = (first.element.status != .closed, second.element.status != .closed)
                if pending.0 != pending.1 { return pending.0 }
                return (first.element.time, first.offset) < (second.element.time, second.offset)
            }
            .map(\.element)
    }

    /// A verbatim quote cut at a word boundary, or nil when it is too short to say anything.
    public static func quote(_ text: String) -> String? {
        let words = text.split(whereSeparator: \.isWhitespace)
        guard words.count >= minimumQuoteWords else { return nil }
        var result = ""
        for word in words {
            let next = result.isEmpty ? String(word) : result + " " + word
            guard next.count <= maximumQuoteLength else {
                return result.isEmpty ? String(next.prefix(maximumQuoteLength)) + "…" : result + "…"
            }
            result = next
        }
        return result
    }

    /// Titles compared like `foldedKey`, without the date an event-linked
    /// recording puts in front of its title.
    public static func titleKey(_ title: String) -> String {
        foldedKey(TitleTemplate.withoutDatePrefix(title))
    }

    /// Text compared without case, diacritics or spacing differences.
    public static func foldedKey(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }
}
