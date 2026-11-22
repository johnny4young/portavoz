import Foundation
import PortavozCore
import StorageKit

/// Who spoke today and the day axis: talk time per voice across today's
/// meetings, each recorded meeting at its real time and length, and the
/// events still to come with their invitees. One day cast colours the page,
/// so a person keeps the same hue in the totals, every strip and every invite.
public struct TodayVoices: Sendable, Equatable {
    public enum Identity: Hashable, Sendable {
        case me
        /// A user-confirmed person, whichever meeting-local speaker they were.
        case person(PersonID)
        /// A meeting-local name no person confirms, grouped by its folded form.
        case name(String)
        /// A voice nobody named; two meetings' unnamed voices never merge.
        case unnamed(SpeakerID)

        /// Stable across launches; keys the day cast and UI test identifiers.
        public var key: String {
            switch self {
            case .me: "me"
            case .person(let id): "person-\(id.rawValue.uuidString)"
            case .name(let folded): "name-\(folded)"
            case .unnamed(let id): "speaker-\(id.rawValue.uuidString)"
            }
        }
    }

    public struct MeetingReference: Sendable, Equatable, Identifiable {
        public let id: MeetingID
        public let title: String
    }

    public struct Talker: Sendable, Equatable, Identifiable {
        public let identity: Identity
        /// Nil for you and for a voice nobody named.
        public let name: String?
        /// The diarization label an unnamed voice still wears.
        public let label: String
        public let talkSeconds: TimeInterval
        /// The meetings this voice spoke in, earliest first.
        public let meetings: [MeetingReference]
        public let tint: VoiceCast.Tint
        public var id: Identity { identity }
        public var isMe: Bool { identity == .me }
        public var isUnnamed: Bool {
            if case .unnamed = identity { return true }
            return false
        }
    }

    public struct RecordedMeeting: Sendable, Equatable, Identifiable {
        public let id: MeetingID
        public let title: String
        public let startedAt: Date
        /// Up to now while it is still recording.
        public let duration: TimeInterval
        public let isRecording: Bool
        public let strip: VoiceStripColumns
    }

    public struct Invitee: Sendable, Equatable {
        /// The confirmed person's name when the calendar name resolves to one.
        public let name: String
        public let personID: PersonID?
    }

    public struct UpcomingMeeting: Sendable, Equatable, Identifiable {
        public let event: UpcomingEvent
        public let invitees: [Invitee]
        /// Invitees with you last, coloured by the day cast.
        public let cast: VoiceCast
        public var id: String { event.id }
    }

    public let day: DateInterval
    /// You first, then most talk first.
    public let talkers: [Talker]
    /// Earliest first.
    public let recorded: [RecordedMeeting]
    /// Today's events that have not ended and were not recorded, earliest first.
    public let upcoming: [UpcomingMeeting]
    /// The `later` events with their invitees, coloured by the day cast.
    public let later: [UpcomingMeeting]
    /// Upcoming events that have not started yet.
    public let toGo: Int
    public let cast: VoiceCast

    public var recordedSeconds: TimeInterval {
        recorded.reduce(0) { $0 + $1.duration }
    }
}

extension TodayVoices {
    /// - Parameter people: exact-alias candidates per invitee name; only a
    ///   single candidate resolves an invitee, so ambiguity stays a plain name.
    public init(
        day: DateInterval,
        now: Date,
        meetings: [MeetingStore.LibraryMeetingRow],
        events: [UpcomingEvent],
        later: [UpcomingEvent] = [],
        people: [String: [Person]]
    ) {
        let meetings = meetings.sorted { $0.meeting.startedAt < $1.meeting.startedAt }
            .map { (row: $0, source: $0.voiceColumns.map(VoiceStripSource.init(columns:))) }
        var totals: [Total] = []
        for (row, source) in meetings {
            Self.talkTotals(
                source?.voices ?? [], reference: MeetingReference(id: row.meeting.id, title: row.meeting.title),
                into: &totals)
        }
        let cast = VoiceCast(members: totals.map(\.member), ordering: .talkShare)
        let names = Self.names(totals)
        let recorded = meetings.map {
            Self.recorded($0.row, source: $0.source, now: now, page: cast.page, names: names)
        }
        func meeting(_ event: UpcomingEvent) -> UpcomingMeeting {
            let invitees = Self.invitees(event.attendees, people: people, names: names)
            return UpcomingMeeting(event: event, invitees: invitees, cast: Self.inviteeCast(invitees, page: cast.page))
        }
        let upcoming = events
            .filter { Self.isStillAhead($0, day: day, now: now, recorded: recorded) }
            .sorted { $0.startDate < $1.startDate }
            .map(meeting)
        let mine = totals.filter { $0.identity == .me }
        let others = totals.filter { $0.identity != .me }.sorted { $0.talkSeconds > $1.talkSeconds }
        self.init(
            day: day,
            talkers: (mine + others).map { $0.talker(tint: cast.tint(for: $0.identity.key)) },
            recorded: recorded,
            upcoming: upcoming,
            later: later.map(meeting),
            toGo: upcoming.count { $0.event.startDate > now },
            cast: cast)
    }

    private struct Total {
        let identity: Identity
        var name: String?
        var label: String
        var talkSeconds: TimeInterval = 0
        var meetings: [MeetingReference] = []

        var member: VoiceCast.Member {
            VoiceCast.Member(
                key: identity.key, isMe: identity == .me, name: name, talkSeconds: talkSeconds)
        }

        func talker(tint: VoiceCast.Tint) -> Talker {
            Talker(
                identity: identity, name: name, label: label, talkSeconds: talkSeconds,
                meetings: meetings, tint: tint)
        }
    }

    /// Totals in first-heard order; the latest meeting's name wins. Within one
    /// meeting, speakers sharing an identity fold into one total.
    private static func talkTotals(
        _ voices: [VoiceStripSource.Voice], reference: MeetingReference? = nil, into totals: inout [Total]
    ) {
        for voice in voices {
            let index = totals.firstIndex { $0.identity == voice.identity } ?? {
                totals.append(Total(identity: voice.identity, name: voice.name, label: voice.label))
                return totals.count - 1
            }()
            totals[index].name = voice.name ?? totals[index].name
            totals[index].talkSeconds += voice.talkSeconds
            if let reference, totals[index].meetings.last?.id != reference.id {
                totals[index].meetings.append(reference)
            }
        }
    }

    private static func names(_ totals: [Total]) -> [String: String] {
        Dictionary(
            totals.compactMap { total in total.name.map { (total.identity.key, $0) } },
            uniquingKeysWith: { first, _ in first })
    }

    /// Named voices by identity key, as the day's totals name them.
    var namesByKey: [String: String] {
        Dictionary(
            talkers.compactMap { talker in talker.name.map { (talker.identity.key, $0) } },
            uniquingKeysWith: { first, _ in first })
    }

    static func name(of voice: MeetingVoiceColumns.Voice) -> String? {
        voice.isMe ? nil : voice.displayName.flatMap(PersonAliasNormalizer.displayName)
    }

    static func identity(of voice: MeetingVoiceColumns.Voice, name: String?) -> Identity {
        if voice.isMe { return .me }
        if let person = voice.personID { return .person(person) }
        if let folded = name.flatMap(PersonAliasNormalizer.normalize) { return .name(folded) }
        return .unnamed(voice.speakerID)
    }

    private static func recorded(
        _ row: MeetingStore.LibraryMeetingRow, source: VoiceStripSource?, now: Date, page: VoiceCast.Page,
        names: [String: String]
    ) -> RecordedMeeting {
        let meeting = row.meeting
        let isRecording = meeting.lifecycleState == .recording
        let end = meeting.endedAt ?? (isRecording ? now : meeting.startedAt)
        return RecordedMeeting(
            id: meeting.id,
            title: meeting.title,
            startedAt: meeting.startedAt,
            duration: max(0, end.timeIntervalSince(meeting.startedAt), row.voiceColumns?.duration ?? 0),
            isRecording: isRecording,
            strip: source.map { strip(of: $0, page: page, names: names) } ?? .empty)
    }

    /// The meeting's cast keyed by day identity on the page's tints, so each
    /// voice keeps its page tint and wears the day's name when it has one.
    static func strip(
        of source: VoiceStripSource, page: VoiceCast.Page, names: [String: String]
    ) -> VoiceStripColumns {
        var totals: [Total] = []
        talkTotals(source.voices, into: &totals)
        let cast = VoiceCast(
            members: totals.map {
                VoiceCast.Member(
                    key: $0.identity.key, isMe: $0.identity == .me, name: names[$0.identity.key] ?? $0.name,
                    talkSeconds: $0.talkSeconds)
            },
            ordering: .talkShare,
            page: page)
        return VoiceStripColumns(
            columns: source.columns, tints: source.voices.map { cast.tint(for: $0.key) }, cast: cast,
            duration: source.duration)
    }

    /// Starts today and has not ended; one already under way is dropped when a
    /// recording began from shortly before its start, because that is its strip.
    /// How early a recording may start and still be the event's own.
    static let recordingLead: TimeInterval = 15 * 60

    private static func isStillAhead(
        _ event: UpcomingEvent, day: DateInterval, now: Date, recorded: [RecordedMeeting]
    ) -> Bool {
        guard day.start <= event.startDate, event.startDate < day.end else { return false }
        let end = event.endDate ?? event.startDate
        guard end > now else { return false }
        guard event.startDate <= now else { return true }
        return !recorded.contains {
            $0.startedAt >= event.startDate.addingTimeInterval(-recordingLead) && $0.startedAt < end
        }
    }

    private static func invitees(
        _ attendees: [String], people: [String: [Person]], names: [String: String]
    ) -> [Invitee] {
        var seen = Set<PersonID>()
        return attendees.compactMap { attendee in
            guard let candidates = people[attendee], candidates.count == 1, let person = candidates.first
            else { return Invitee(name: attendee, personID: nil) }
            guard seen.insert(person.id).inserted else { return nil }
            return Invitee(name: names[Identity.person(person.id).key] ?? person.preferredName, personID: person.id)
        }
    }

    /// Invitees with you last, keyed like the day's voices so a person or a
    /// name heard today keeps its tint and nobody else takes it.
    static func inviteeCast(_ invitees: [Invitee], page: VoiceCast.Page) -> VoiceCast {
        var used = Set<String>()
        let members = invitees.enumerated().map { index, invitee in
            let identity: Identity? = invitee.personID.map(Identity.person)
                ?? PersonAliasNormalizer.normalize(invitee.name).map(Identity.name)
            // A repeated unresolved name gets its own key, so voice ids stay unique.
            let key = identity.map(\.key).flatMap { used.insert($0).inserted ? $0 : nil }
            return VoiceCast.Member(
                key: key ?? "invitee-\(index)", name: invitee.name, talkSeconds: 0)
        } + [VoiceCast.Member(key: Identity.me.key, isMe: true, name: nil, talkSeconds: 0)]
        return VoiceCast(members: members, ordering: .talkShare, page: page)
    }
}
