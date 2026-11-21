import Foundation
import PortavozCore

/// Who keeps a colour in one meeting: you in amber and at most five named
/// voices in a hue. Unnamed voices stay grey until named; past the five, the
/// rest are grey too and fold into "Others · n". Pure, so every surface that
/// draws voices agrees on the same colours and order.
public struct VoiceCast: Sendable, Equatable {
    public enum Ordering: Sendable {
        /// Live: the current speaker first, then whoever spoke last.
        case recency
        /// After Stop: most talk first.
        case talkShare
    }

    public enum Tint: Sendable, Hashable {
        case you
        case hue(Int)
        case grey
    }

    public struct Member: Sendable, Equatable {
        public let key: String
        public let isMe: Bool
        public let name: String?
        public let talkSeconds: TimeInterval
        public let lastHeard: TimeInterval?

        public init(
            key: String,
            isMe: Bool = false,
            name: String?,
            talkSeconds: TimeInterval,
            lastHeard: TimeInterval? = nil
        ) {
            self.key = key
            self.isMe = isMe
            let trimmed = name?.trimmingCharacters(in: .whitespaces)
            self.name = trimmed?.isEmpty == false ? trimmed : nil
            self.talkSeconds = max(0, talkSeconds)
            self.lastHeard = lastHeard
        }
    }

    public struct Voice: Sendable, Equatable, Identifiable {
        public let key: String
        public let isMe: Bool
        public let name: String?
        public let talkSeconds: TimeInterval
        /// Share of everyone's talk, 0…1.
        public let share: Double
        public let tint: Tint
        public var id: String { key }
    }

    /// Voices besides you that may hold a hue at once.
    private static let colouredVoices = VoiceHue.paletteSize

    /// You plus up to five promoted voices, in the cast's ordering.
    public let voices: [Voice]
    /// Everyone else, by talk share.
    public let others: [Voice]
    private let tints: [String: Tint]

    public func tint(for key: String) -> Tint {
        tints[key] ?? .grey
    }

    /// - Parameters:
    ///   - current: live key of whoever is speaking now; leads a `.recency` cast.
    ///   - previous: an earlier cast. Named voices keep the hue it gave their
    ///     key, else their name, so live re-ranking or relabelling never
    ///     recolours someone on screen.
    public init(
        members: [Member],
        ordering: Ordering,
        current: String? = nil,
        previous: VoiceCast? = nil
    ) {
        let total = members.reduce(0) { $0 + $1.talkSeconds }
        let appearance = Dictionary(
            members.enumerated().map { ($1.key, $0) }, uniquingKeysWith: { first, _ in first })
        let precedes = Self.order(ordering, current: current, appearance: appearance)

        let ranked = members.filter { !$0.isMe }.sorted(by: precedes)
        let promoted = Array(ranked.prefix(Self.colouredVoices))
        let folded = ranked.dropFirst(Self.colouredVoices)
        let hues = Self.assignHues(
            to: promoted
                .sorted { appearance[$0.key, default: 0] < appearance[$1.key, default: 0] }
                .compactMap { member in member.name.map { (key: member.key, name: $0) } },
            previous: previous)

        func voice(_ member: Member, tint: Tint) -> Voice {
            Voice(
                key: member.key, isMe: member.isMe, name: member.name,
                talkSeconds: member.talkSeconds,
                share: total > 0 ? member.talkSeconds / total : 0,
                tint: tint)
        }
        voices = (members.filter(\.isMe) + promoted).sorted(by: precedes).map { member in
            if member.isMe { return voice(member, tint: .you) }
            return voice(member, tint: hues[member.key].map(Tint.hue) ?? .grey)
        }
        others = folded
            .sorted(by: Self.order(.talkShare, current: nil, appearance: appearance))
            .map { voice($0, tint: .grey) }
        tints = Dictionary(
            (voices + others).map { ($0.key, $0.tint) }, uniquingKeysWith: { first, _ in first })
    }

    private static func order(
        _ ordering: Ordering, current: String?, appearance: [String: Int]
    ) -> (Member, Member) -> Bool {
        { lhs, rhs in
            let tie = appearance[lhs.key, default: 0] < appearance[rhs.key, default: 0]
            switch ordering {
            case .talkShare:
                if lhs.talkSeconds != rhs.talkSeconds { return lhs.talkSeconds > rhs.talkSeconds }
                return tie
            case .recency:
                if (lhs.key == current) != (rhs.key == current) { return lhs.key == current }
                let left = lhs.lastHeard ?? -.infinity
                let right = rhs.lastHeard ?? -.infinity
                if left != right { return left > right }
                return tie
            }
        }
    }

    /// Previous hues first, by key and then by name for a relabelled voice;
    /// then each name's stable hue, or the next free one when taken.
    private static func assignHues(
        to named: [(key: String, name: String)], previous: VoiceCast?
    ) -> [String: Int] {
        var keptByKey: [String: Int] = [:]
        var keptByName: [String: Int] = [:]
        for voice in previous?.voices ?? [] {
            if case .hue(let index) = voice.tint, let name = voice.name {
                keptByKey[voice.key] = index
                keptByName[VoiceHue.normalized(name)] = index
            }
        }
        var taken = Set<Int>()
        var result: [String: Int] = [:]
        for kept in [{ keptByKey[$0.key] }, { keptByName[VoiceHue.normalized($0.name)] }]
            as [((key: String, name: String)) -> Int?] {
            for member in named where result[member.key] == nil {
                guard let index = kept(member), !taken.contains(index) else { continue }
                result[member.key] = index
                taken.insert(index)
            }
        }
        for member in named where result[member.key] == nil {
            let preferred = VoiceHue.index(name: member.name)
            guard let free = (0..<VoiceHue.paletteSize)
                .map({ (preferred + $0) % VoiceHue.paletteSize })
                .first(where: { !taken.contains($0) })
            else { break }
            result[member.key] = free
            taken.insert(free)
        }
        return result
    }
}

extension VoiceCast {
    /// A finished meeting's cast, ranked by attributed talk. Members are
    /// passed in first-heard order, so a hue clash goes to whoever spoke first.
    public init(speakers: [Speaker], segments: [TranscriptSegment]) {
        var seconds: [SpeakerID: TimeInterval] = [:]
        var firstHeard: [SpeakerID: TimeInterval] = [:]
        for segment in segments where segment.endTime > segment.startTime {
            guard let id = segment.speakerID else { continue }
            seconds[id, default: 0] += segment.endTime - segment.startTime
            firstHeard[id] = min(firstHeard[id] ?? segment.startTime, segment.startTime)
        }
        let heardOrder = speakers.enumerated().sorted { lhs, rhs in
            let left = firstHeard[lhs.element.id] ?? .infinity
            let right = firstHeard[rhs.element.id] ?? .infinity
            return left != right ? left < right : lhs.offset < rhs.offset
        }.map(\.element)
        self.init(
            members: heardOrder.map {
                Member(
                    key: Self.key($0.id), isMe: $0.isMe, name: $0.displayName,
                    talkSeconds: seconds[$0.id, default: 0])
            },
            ordering: .talkShare)
    }

    /// Calendar invitees in calendar order with you last.
    public init(invitees: [String]) {
        let members = invitees.enumerated().map { index, name in
            Member(key: "invitee-\(index)", name: name, talkSeconds: 0)
        } + [Member(key: "me", isMe: true, name: nil, talkSeconds: 0)]
        self.init(members: members, ordering: .talkShare)
    }

    public static func key(_ id: SpeakerID) -> String { id.rawValue.uuidString }

    public func tint(for speaker: Speaker) -> Tint {
        speaker.isMe ? .you : tint(for: speaker.id)
    }

    public func tint(for id: SpeakerID) -> Tint {
        tint(for: Self.key(id))
    }
}
