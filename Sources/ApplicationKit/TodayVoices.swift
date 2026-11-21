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

        var key: String {
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
        people: [String: [Person]]
    ) {
        let meetings = meetings.sorted { $0.meeting.startedAt < $1.meeting.startedAt }
        let totals = Self.talkTotals(meetings)
        let cast = VoiceCast(members: totals.map(\.member), ordering: .talkShare)
        let names = Dictionary(
            totals.compactMap { total in total.name.map { (total.identity, $0) } },
            uniquingKeysWith: { first, _ in first })
        let recorded = meetings.map { Self.recorded($0, now: now, cast: cast, names: names) }
        let upcoming = events
            .filter { Self.isStillAhead($0, day: day, now: now, recorded: recorded) }
            .sorted { $0.startDate < $1.startDate }
            .map { event in
                let invitees = Self.invitees(event.attendees, people: people, names: names)
                return UpcomingMeeting(
                    event: event, invitees: invitees, cast: Self.inviteeCast(invitees, day: cast))
            }
        let mine = totals.filter { $0.identity == .me }
        let others = totals.filter { $0.identity != .me }.sorted { $0.talkSeconds > $1.talkSeconds }
        self.init(
            day: day,
            talkers: (mine + others).map { $0.talker(tint: cast.tint(for: $0.identity.key)) },
            recorded: recorded,
            upcoming: upcoming,
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
        _ voices: [MeetingVoiceColumns.Voice], reference: MeetingReference? = nil, into totals: inout [Total]
    ) {
        for voice in voices {
            let name = name(of: voice)
            let identity = identity(of: voice, name: name)
            let index = totals.firstIndex { $0.identity == identity } ?? {
                totals.append(Total(identity: identity, name: name, label: voice.label))
                return totals.count - 1
            }()
            totals[index].name = name ?? totals[index].name
            totals[index].talkSeconds += voice.talkSeconds
            if let reference, totals[index].meetings.last?.id != reference.id {
                totals[index].meetings.append(reference)
            }
        }
    }

    private static func talkTotals(_ meetings: [MeetingStore.LibraryMeetingRow]) -> [Total] {
        var totals: [Total] = []
        for row in meetings {
            talkTotals(
                row.voiceColumns?.voices ?? [],
                reference: MeetingReference(id: row.meeting.id, title: row.meeting.title),
                into: &totals)
        }
        return totals
    }

    private static func name(of voice: MeetingVoiceColumns.Voice) -> String? {
        voice.isMe ? nil : voice.displayName.flatMap(PersonAliasNormalizer.displayName)
    }

    private static func identity(of voice: MeetingVoiceColumns.Voice, name: String?) -> Identity {
        if voice.isMe { return .me }
        if let person = voice.personID { return .person(person) }
        if let folded = name.flatMap(PersonAliasNormalizer.normalize) { return .name(folded) }
        return .unnamed(voice.speakerID)
    }

    private static func recorded(
        _ row: MeetingStore.LibraryMeetingRow, now: Date, cast: VoiceCast, names: [Identity: String]
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
            strip: row.voiceColumns.map { strip(of: $0, cast: cast, names: names) } ?? .empty)
    }

    /// The meeting's cast keyed by day identity with the day cast as its page,
    /// so each voice keeps its day tint and wears the day's name.
    private static func strip(
        of columns: MeetingVoiceColumns, cast: VoiceCast, names: [Identity: String]
    ) -> VoiceStripColumns {
        var totals: [Total] = []
        talkTotals(columns.voices, into: &totals)
        let meetingCast = VoiceCast(
            members: totals.map {
                VoiceCast.Member(
                    key: $0.identity.key, isMe: $0.identity == .me, name: names[$0.identity],
                    talkSeconds: $0.talkSeconds)
            },
            ordering: .talkShare,
            page: cast)
        return VoiceStripColumns(
            columns: columns.columns,
            tints: columns.voices.map { meetingCast.tint(for: identity(of: $0, name: name(of: $0)).key) },
            cast: meetingCast)
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
        _ attendees: [String], people: [String: [Person]], names: [Identity: String]
    ) -> [Invitee] {
        var seen = Set<PersonID>()
        return attendees.compactMap { attendee in
            guard let candidates = people[attendee], candidates.count == 1, let person = candidates.first
            else { return Invitee(name: attendee, personID: nil) }
            guard seen.insert(person.id).inserted else { return nil }
            return Invitee(name: names[.person(person.id)] ?? person.preferredName, personID: person.id)
        }
    }

    /// Invitees with you last, keyed like the day's voices so a person or a
    /// name heard today keeps its tint and nobody else takes it.
    private static func inviteeCast(_ invitees: [Invitee], day: VoiceCast) -> VoiceCast {
        var used = Set<String>()
        let members = invitees.enumerated().map { index, invitee in
            let identity: Identity? = invitee.personID.map(Identity.person)
                ?? PersonAliasNormalizer.normalize(invitee.name).map(Identity.name)
            // A repeated unresolved name gets its own key, so voice ids stay unique.
            let key = identity.map(\.key).flatMap { used.insert($0).inserted ? $0 : nil }
            return VoiceCast.Member(
                key: key ?? "invitee-\(index)", name: invitee.name, talkSeconds: 0)
        } + [VoiceCast.Member(key: Identity.me.key, isMe: true, name: nil, talkSeconds: 0)]
        return VoiceCast(members: members, ordering: .talkShare, page: day)
    }
}
