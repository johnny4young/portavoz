import DiarizationKit
import Foundation
import PortavozCore

/// What the recording knows about its voices at one moment, rebuilt from the
/// live captions and the live diarizer's labels. Pure: a relabel that rewrites
/// any closed row yields the same result as if it had been the first pass.
public struct LiveVoiceSource: Sendable {
    public let captions: [TranscriptSegment]
    /// Row id → live label ("S1", "S2", "Me") from `LiveSpeakerLabeler`.
    public let labels: [UUID: String]
    /// The diarizer's newest turn; it names the still-open remote row.
    public let latestTurn: SpeakerTurn?
    /// The microphone carries speech right now.
    public var youSpeaking: Bool
    /// Seconds since the recording started.
    public let now: TimeInterval
    public let notes: [ContextItem]
    public let questions: [CompanionCard]

    public init(
        captions: [TranscriptSegment],
        labels: [UUID: String],
        latestTurn: SpeakerTurn?,
        youSpeaking: Bool = false,
        now: TimeInterval,
        notes: [ContextItem] = [],
        questions: [CompanionCard] = []
    ) {
        self.captions = captions
        self.labels = labels
        self.latestTurn = latestTurn
        self.youSpeaking = youSpeaking
        self.now = now
        self.notes = notes
        self.questions = questions
    }
}

/// Per-voice live turns, the voice columns they bin into, and time-stamped
/// ticks for your notes and the questions asked of you.
public struct LiveVoiceStage: Sendable, Equatable {
    /// Your microphone, and remote speech the voiceprint matched to you.
    public static let youKey = "you"
    /// Remote speech the diarizer has not labelled yet.
    public static let unlabelledKey = "remote"
    /// An open row last heard longer ago than this no longer names a speaker.
    public static let currentWindow: TimeInterval = 3

    public struct Voice: Sendable, Equatable, Identifiable {
        public let key: String
        /// Runs of this voice's rows that nobody else's row starts inside.
        public let turns: [ClosedRange<TimeInterval>]
        public let talkSeconds: TimeInterval
        public var lastHeard: TimeInterval { turns.last?.upperBound ?? 0 }
        public var isMe: Bool { key == LiveVoiceStage.youKey }
        public var id: String { key }
    }

    /// Every voice heard, first heard first.
    public let voices: [Voice]
    /// Who is speaking now, as a voice key.
    public let current: String?
    public let columns: LiveVoiceColumns
    /// Notes and questions in time order.
    public let ticks: [LiveVoiceTick]

    public static let empty = LiveVoiceStage(voices: [], current: nil, columns: LiveVoiceColumns(), ticks: [])

    public var isEmpty: Bool { voices.isEmpty && ticks.isEmpty }

    /// Voices heard so far; unlabelled remote speech is not one yet.
    public var voiceCount: Int { voices.count { $0.key != Self.unlabelledKey } }

    public func voice(_ key: String) -> Voice? { voices.first { $0.key == key } }

    /// The voice key of a live row: `you` for the microphone and the
    /// voiceprint's label, the live label, or `unlabelledKey`.
    public static func key(for row: TranscriptSegment, labels: [UUID: String]) -> String {
        key(channel: row.channel, label: labels[row.id])
    }

    private static func key(channel: AudioChannel, label: String?) -> String {
        if channel == .microphone { return youKey }
        guard let label else { return unlabelledKey }
        return label == PyannoteDiarizer.enrolledLabel ? youKey : label
    }

    /// Rebuilds the stage. Columns recompute only from the first second whose
    /// attribution changed since `previous`.
    public static func updating(_ previous: LiveVoiceStage, with source: LiveVoiceSource) -> LiveVoiceStage {
        let open = source.captions.last
        func key(_ row: TranscriptSegment) -> String {
            let label = source.labels[row.id]
                ?? (row.id == open?.id ? openLabel(row, turn: source.latestTurn) : nil)
            return Self.key(channel: row.channel, label: label)
        }
        // A growing caption can end past the clock; nothing live is drawn or counted past now.
        let now = source.now.isFinite && source.now > 0 ? source.now : TimeInterval.infinity
        var attributed: [VoiceRow] = []
        attributed.reserveCapacity(source.captions.count)
        var sorted = true
        var lastEnd: TimeInterval = 0
        for row in source.captions where row.startTime.isFinite && row.endTime.isFinite && row.endTime > row.startTime {
            let end = min(row.endTime, now)
            guard end > row.startTime else { continue }
            if let last = attributed.last, (last.start, last.end) > (row.startTime, end) { sorted = false }
            attributed.append(VoiceRow(key: key(row), start: row.startTime, end: end))
            lastEnd = max(lastEnd, end)
        }
        if !sorted { attributed.sort { ($0.start, $0.end) < ($1.start, $1.end) } }

        let current: String? = if source.youSpeaking {
            youKey
        } else if let open, open.startTime < now, source.now - open.endTime <= currentWindow {
            key(open)
        } else {
            nil
        }
        return LiveVoiceStage(
            voices: voices(attributed),
            current: current,
            columns: previous.columns.updating(turns: attributed, duration: max(source.now, lastEnd)),
            ticks: ticks(notes: source.notes, questions: source.questions) { id in
                source.captions.last { $0.id == id }.map(key)
            })
    }

    /// The labeler never names the growing row; the newest diarizer turn does
    /// when it reaches into it.
    private static func openLabel(_ row: TranscriptSegment, turn: SpeakerTurn?) -> String? {
        guard let turn, turn.endTime > row.startTime, turn.startTime < row.endTime else { return nil }
        return turn.voiceLabel
    }

    private static func voices(_ attributed: [VoiceRow]) -> [Voice] {
        // Overlapping rows of one voice (your microphone and its voiceprint echo) count once.
        var seconds: [String: TimeInterval] = [:]
        var reach: [String: TimeInterval] = [:]
        for row in attributed {
            let from = max(row.start, reach[row.key] ?? row.start)
            if row.end > from { seconds[row.key, default: 0] += row.end - from }
            reach[row.key] = max(reach[row.key] ?? row.end, row.end)
        }
        let merged = VoiceTurnRuns.merge(attributed.map { (key: $0.key, start: $0.start, end: $0.end) })
        return merged.order.map {
            Voice(key: $0, turns: merged.turns[$0] ?? [], talkSeconds: seconds[$0] ?? 0)
        }
    }

    private static func ticks(
        notes: [ContextItem], questions: [CompanionCard], asker: (UUID) -> String?
    ) -> [LiveVoiceTick] {
        let noted = notes.filter { $0.kind == .note }.map {
            LiveVoiceTick(id: $0.id, kind: .note, time: max(0, $0.timestamp))
        }
        let asked = questions.map { card in
            let by = card.evidence?.questionSegmentIDs.lazy.compactMap(asker).first
            return LiveVoiceTick(id: card.id, kind: .askedYou(by: by), time: max(0, card.askedAt))
        }
        return (noted + asked).sorted { ($0.time, $0.id.uuidString) < ($1.time, $1.id.uuidString) }
    }
}

extension LiveVoiceStage {
    /// The live cast: you first while speaking, then whoever spoke last.
    /// Live voices are unnamed, so every voice but you stays grey.
    public func cast(previous: VoiceCast? = nil) -> VoiceCast {
        VoiceCast(
            members: voices.map {
                VoiceCast.Member(
                    key: $0.key, isMe: $0.isMe, name: nil,
                    talkSeconds: $0.talkSeconds, lastHeard: $0.lastHeard)
            },
            ordering: .recency,
            current: current,
            previous: previous)
    }

    /// The stage's columns ready to draw with `cast`'s tints.
    public func strip(cast: VoiceCast) -> VoiceStripColumns {
        VoiceStripColumns(
            columns: columns.values,
            tints: columns.keys.map { $0 == Self.youKey ? .you : cast.tint(for: $0) },
            cast: cast,
            duration: columns.duration)
    }
}

/// A moment on the live strip: one of your notes or a question asked of you.
public struct LiveVoiceTick: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable {
        case note
        /// Who asked, as a voice key, when the question's row is known.
        case askedYou(by: String?)
    }

    public let id: UUID
    public let kind: Kind
    public let time: TimeInterval

    public init(id: UUID, kind: Kind, time: TimeInterval) {
        self.id = id
        self.kind = kind
        self.time = time
    }
}

/// One attributed live row.
struct VoiceRow: Sendable, Equatable {
    let key: String
    let start: TimeInterval
    let end: TimeInterval
}

/// One column per second of the recording. Voice indexes are assigned on first
/// sight and never move, so a change only rebins the columns after it.
public struct LiveVoiceColumns: Sendable, Equatable {
    /// Index into `keys` per second, or `VoiceColumns.silence`.
    public private(set) var values: [UInt8] = []
    /// Voice key per index, in first-seen order.
    public private(set) var keys: [String] = []
    /// The first second the last update rebinned; nil when none.
    public private(set) var rebinnedFrom: Int?
    private var turns: [VoiceRow] = []

    public init() {}

    public var duration: TimeInterval { Double(values.count) }

    func updating(turns next: [VoiceRow], duration: TimeInterval) -> LiveVoiceColumns {
        let count = duration.isFinite && duration > 0 ? Int(duration.rounded(.up)) : 0
        var result = self
        result.turns = next
        var seen = Set(keys)
        var first = values.count
        for turn in next where !seen.contains(turn.key) {
            seen.insert(turn.key)
            result.keys.append(turn.key)
        }
        if result.keys.count > VoiceColumns.maximumVoices {
            // Too many keys over time: start over with only today's voices, first
            // seen first, and leave any past the cap as silence.
            result.keys = []
            var current = Set<String>()
            for turn in next where !current.contains(turn.key) && result.keys.count < VoiceColumns.maximumVoices {
                current.insert(turn.key)
                result.keys.append(turn.key)
            }
            first = 0
        } else if let changed = Self.firstDifference(turns, next) {
            let start = [turns, next].compactMap { $0.indices.contains(changed) ? $0[changed].start : nil }.min() ?? 0
            first = min(first, max(0, Int(start)))
        }
        first = min(first, count)
        result.values = Array(values.prefix(first))
        result.rebinnedFrom = first < count ? first : nil
        guard first < count else { return result }

        let index = Dictionary(result.keys.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        // `bin` draws at most `maximumCount` columns per call; turns are sorted
        // by start, so each chunk skips those that already ended.
        var chunkStart = first
        var skipped = 0
        while chunkStart < count {
            let span = min(VoiceColumns.maximumCount, count - chunkStart)
            let offset = Double(chunkStart)
            let piece = next[skipped...].compactMap { turn -> VoiceColumns.Turn? in
                guard turn.end > offset, turn.start < offset + Double(span), let voice = index[turn.key]
                else { return nil }
                return VoiceColumns.Turn(voice: voice, start: turn.start - offset, end: turn.end - offset)
            }
            result.values += VoiceColumns.bin(piece, duration: Double(span), count: span)
            chunkStart += span
            while skipped < next.count, next[skipped].end <= Double(chunkStart) {
                skipped += 1
            }
        }
        return result
    }

    private static func firstDifference(_ old: [VoiceRow], _ new: [VoiceRow]) -> Int? {
        for index in 0..<min(old.count, new.count) where old[index] != new[index] { return index }
        return old.count == new.count ? nil : min(old.count, new.count)
    }

    /// `rebinnedFrom` reports work done, not content.
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.values == rhs.values && lhs.keys == rhs.keys && lhs.turns == rhs.turns
    }
}
