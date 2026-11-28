import Foundation
import PortavozCore
import StorageKit

/// One cast for everything Today draws. The day's voices claim tints first,
/// then the next meeting's invitees, then each listed meeting in order, so a
/// person keeps one colour on the page and two named people share a hue only
/// once all five are taken. Voices are keyed like `TodayVoices.Identity`.
public struct TodayPageCast: Sendable, Equatable {
    /// The next meeting's invitees with you last.
    public let hero: VoiceCast?
    private let strips: [MeetingID: VoiceStripColumns]
    private let sources: [MeetingID: VoiceStripSource]

    /// - Parameters:
    ///   - day: today's voices; without them the invitees seed the page.
    ///   - meetings: strips to recast, in the order they claim free hues.
    public init(
        day: TodayVoices?, hero event: UpcomingEvent?, meetings: [(id: MeetingID, source: VoiceStripSource)]
    ) {
        var page = day?.cast.page ?? .empty
        let names = day?.namesByKey ?? [:]
        let hero = event.map { event in
            ((day?.upcoming ?? []) + (day?.later ?? [])).first { $0.event == event }?.cast
                ?? TodayVoices.inviteeCast(
                    event.attendees.map { TodayVoices.Invitee(name: $0, personID: nil) }, page: page)
        }
        if let hero { page = page.adding(hero) }
        var strips: [MeetingID: VoiceStripColumns] = [:]
        var sources: [MeetingID: VoiceStripSource] = [:]
        for (id, source) in meetings where strips[id] == nil {
            let strip = TodayVoices.strip(of: source, page: page, names: names)
            strips[id] = strip
            sources[id] = source
            page = page.adding(strip.cast)
        }
        self.hero = hero
        self.strips = strips
        self.sources = sources
    }

    /// Strips alone, as a list outside Today shows them.
    public init(meetings: [(id: MeetingID, source: VoiceStripSource)]) {
        self.init(day: nil, hero: nil, meetings: meetings)
    }

    public func strip(for meeting: MeetingID) -> VoiceStripColumns? {
        strips[meeting]
    }

    /// A voice of a listed meeting; grey when the page never drew it.
    public func tint(for speaker: SpeakerID?, isMe: Bool, in meeting: MeetingID) -> VoiceCast.Tint {
        if isMe { return .you }
        guard let speaker, let key = sources[meeting]?.key(of: speaker), let strip = strips[meeting]
        else { return .grey }
        return strip.cast.tint(for: key)
    }
}

/// A stored strip whose voices carry their day identity, so a page can
/// recast it in its own colours.
public struct VoiceStripSource: Sendable, Equatable {
    public struct Voice: Sendable, Equatable {
        public let speakerID: SpeakerID
        public let identity: TodayVoices.Identity
        /// The diarization label an unnamed voice still wears.
        public let label: String
        public let name: String?
        public let talkSeconds: TimeInterval
        public var key: String { identity.key }
    }

    public let columns: [UInt8]
    /// First-heard order; `columns` index into it.
    public let voices: [Voice]
    public let duration: TimeInterval

    public init(columns: MeetingVoiceColumns) {
        self.columns = columns.columns
        self.voices = columns.voices.map { voice in
            let name = TodayVoices.name(of: voice)
            return Voice(
                speakerID: voice.speakerID, identity: TodayVoices.identity(of: voice, name: name),
                label: voice.label, name: name, talkSeconds: voice.talkSeconds)
        }
        self.duration = columns.duration
    }

    func key(of speaker: SpeakerID) -> String? {
        voices.first { $0.speakerID == speaker }?.key
    }
}
