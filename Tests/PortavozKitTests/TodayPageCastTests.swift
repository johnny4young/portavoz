import Foundation
import PortavozCore
import StorageKit
import XCTest

@testable import ApplicationKit

final class TodayPageCastTests: XCTestCase {
    private typealias Voice = MeetingVoiceColumns.Voice

    private let dayStart = Date(timeIntervalSince1970: 1_789_000_000)
    private var day: DateInterval { DateInterval(start: dayStart, duration: 24 * 3600) }
    private let marta = Person(preferredName: "Marta")
    /// Prefers Marta's hue, so only one of them may wear it.
    private lazy var rival: String = (1...200).map { "Person \($0)" }
        .first { VoiceHue.index(name: $0) == VoiceHue.index(name: "Marta") }!

    private func at(_ hour: Double) -> Date { dayStart.addingTimeInterval(hour * 3600) }

    private func voice(
        _ name: String?, isMe: Bool = false, person: PersonID? = nil, label: String = "S1",
        speaker: SpeakerID = SpeakerID()
    ) -> Voice {
        Voice(
            speakerID: speaker, isMe: isMe, label: label, displayName: name, personID: person,
            talkSeconds: 60, firstHeard: 0)
    }

    private func columns(_ voices: [Voice]) -> MeetingVoiceColumns {
        MeetingVoiceColumns(duration: 600, columns: Array(0..<UInt8(voices.count)), voices: voices)
    }

    private func today(_ meetings: [MeetingVoiceColumns], hero: UpcomingEvent) -> TodayVoices {
        TodayVoices(
            day: day, now: at(9),
            meetings: meetings.enumerated().map { index, columns in
                MeetingStore.LibraryMeetingRow(
                    meeting: Meeting(
                        title: "Today \(index)", startedAt: at(Double(8 + index) / 10 + 7),
                        endedAt: at(Double(8 + index) / 10 + 7.05), lifecycleState: .ready),
                    voiceColumns: columns)
            },
            events: [hero], people: ["Marta": [marta]])
    }

    func testOnePersonWearsOneTintAcrossHeroBriefToDoAndPickUp() throws {
        let rival = self.rival
        let hero = UpcomingEvent(
            id: "rollout", title: "Rollout", startDate: at(10), attendees: [rival, "Marta"], endDate: at(11))
        let design = columns([voice(nil, isMe: true), voice("Marta", person: marta.id)])
        let brief = (id: MeetingID(), speaker: SpeakerID())
        let todo = (id: MeetingID(), speaker: SpeakerID())
        let briefColumns = columns([voice(rival, speaker: brief.speaker), voice(nil, isMe: true)])
        let todoColumns = columns([
            voice(nil, isMe: true), voice(" \(rival.uppercased()) ", speaker: todo.speaker), voice("Bruno")
        ])
        let page = TodayPageCast(
            day: today([design], hero: hero), hero: hero,
            meetings: [(brief.id, VoiceStripSource(columns: briefColumns)), (todo.id, VoiceStripSource(columns: todoColumns))])

        let heroCast = try XCTUnwrap(page.hero)
        let martaTint = heroCast.voices.first { $0.name == "Marta" }?.tint
        let rivalVoice = try XCTUnwrap(heroCast.voices.first { $0.name == rival })
        let rivalTint = rivalVoice.tint
        XCTAssertEqual(martaTint, .hue(VoiceHue.index(name: "Marta")), "the day's voice keeps its hue")
        XCTAssertNotEqual(rivalTint, martaTint, "two people never share a hue while one is free")
        XCTAssertNotEqual(rivalTint, .grey)
        XCTAssertEqual(page.tint(for: brief.speaker, isMe: false, in: brief.id), rivalTint, "brief row")
        XCTAssertEqual(page.tint(for: todo.speaker, isMe: false, in: todo.id), rivalTint, "to-do source")
        let legend = try XCTUnwrap(page.strip(for: todo.id)).cast
        XCTAssertEqual(legend.voices.first { $0.key == rivalVoice.key }?.tint, rivalTint, "pick-up legend")
        XCTAssertEqual(page.tint(for: nil, isMe: true, in: todo.id), .you)

        let named = [heroCast, try XCTUnwrap(page.strip(for: brief.id)).cast, legend]
            .flatMap(\.voices).filter { !$0.isMe && $0.name != nil }
        let hues = Dictionary(named.map { ($0.key, $0.tint) }, uniquingKeysWith: { first, _ in first })
        XCTAssertEqual(Set(hues.values).count, hues.count, "every named person on the page has their own hue")
    }

    func testWithoutTodaysVoicesTheInviteesSeedThePage() throws {
        let rival = self.rival
        let hero = UpcomingEvent(
            id: "rollout", title: "Rollout", startDate: at(10), attendees: ["Marta", rival], endDate: at(11))
        let brief = (id: MeetingID(), speaker: SpeakerID())
        let page = TodayPageCast(
            day: nil, hero: hero,
            meetings: [(brief.id, VoiceStripSource(columns: columns([voice(nil, isMe: true), voice(rival, speaker: brief.speaker)])))])

        let heroTint = try XCTUnwrap(page.hero?.voices.first { $0.name == rival }?.tint)
        XCTAssertNotEqual(heroTint, .hue(VoiceHue.index(name: "Marta")), "Marta was invited first")
        XCTAssertEqual(page.tint(for: brief.speaker, isMe: false, in: brief.id), heroTint)
    }

    func testAConfirmedPersonKeepsTheirDayHueInTomorrowsHero() throws {
        let rival = self.rival
        let tomorrow = UpcomingEvent(
            id: "tomorrow", title: "Sync", startDate: at(34), attendees: ["Marta"], endDate: at(35))
        let day = TodayVoices(
            day: day, now: at(9),
            meetings: [MeetingStore.LibraryMeetingRow(
                meeting: Meeting(title: "Today", startedAt: at(8), endedAt: at(8.5), lifecycleState: .ready),
                voiceColumns: columns([voice(rival), voice("Marta G.", person: marta.id)]))],
            events: [], later: [tomorrow], people: ["Marta": [marta]])
        let dayTint = day.cast.tint(for: TodayVoices.Identity.person(marta.id).key)
        XCTAssertNotEqual(dayTint, .grey)

        let hero = try XCTUnwrap(TodayPageCast(day: day, hero: tomorrow, meetings: []).hero)
        XCTAssertEqual(hero.voices.first?.tint, dayTint, "the invitee resolves to the person heard today")
    }

    func testTheHeroBeingRecordedKeepsItsInviteesDayHues() throws {
        let rival = self.rival
        let hero = UpcomingEvent(
            id: "rollout", title: "Rollout", startDate: at(9), attendees: [rival, "Marta"], endDate: at(10))
        let day = TodayVoices(
            day: day, now: at(9.25),
            meetings: [MeetingStore.LibraryMeetingRow(
                meeting: Meeting(title: "Rollout", startedAt: at(9), endedAt: nil, lifecycleState: .recording),
                voiceColumns: columns([voice(nil, isMe: true), voice("Marta G.", person: marta.id)]))],
            events: [hero], people: ["Marta": [marta]])
        XCTAssertTrue(day.upcoming.isEmpty, "the event under way is its recording")
        let dayTint = day.cast.tint(for: TodayVoices.Identity.person(marta.id).key)

        let cast = try XCTUnwrap(TodayPageCast(day: day, hero: hero, meetings: []).hero)
        XCTAssertEqual(cast.voices.first { $0.name == "Marta G." }?.tint, dayTint, "the invitee resolves to the voice heard")
        XCTAssertEqual(cast.voices.map(\.name), [rival, "Marta G.", nil])
    }

    func testTomorrowsInviteesKeepCalendarOrderWithYouLast() throws {
        let event = UpcomingEvent(
            id: "tomorrow", title: "Sync", startDate: at(34), attendees: ["Marta", "Ilarion"], endDate: at(35))
        let cast = try XCTUnwrap(TodayPageCast(day: nil, hero: event, meetings: []).hero)
        XCTAssertEqual(cast.voices.map(\.name), ["Marta", "Ilarion", nil])
        XCTAssertEqual(cast.voices.last?.tint, .you)
        XCTAssertEqual(
            cast.voices.first?.tint, .hue(VoiceHue.index(name: "Marta")),
            "an invitee wears the hue their name has in recorded meetings")
    }

    func testInviteesPastTheCastFoldIntoOthers() throws {
        let event = UpcomingEvent(
            id: "all-hands", title: "All hands", startDate: at(10),
            attendees: (1...7).map { "Person \($0)" }, endDate: at(11))
        let cast = try XCTUnwrap(TodayPageCast(day: nil, hero: event, meetings: []).hero)
        XCTAssertEqual(cast.voices.count, VoiceHue.paletteSize + 1)
        XCTAssertEqual(cast.others.map(\.name), ["Person 6", "Person 7"])
    }

    func testAnUnnamedVoiceAndAnUnlistedMeetingStayGrey() {
        let id = MeetingID()
        let unnamed = SpeakerID()
        let page = TodayPageCast(
            day: nil, hero: nil, meetings: [(id, VoiceStripSource(columns: columns([voice(nil, label: "S2", speaker: unnamed)])))])
        XCTAssertNil(page.hero)
        XCTAssertEqual(page.tint(for: unnamed, isMe: false, in: id), .grey)
        XCTAssertEqual(page.tint(for: SpeakerID(), isMe: false, in: MeetingID()), .grey)
        XCTAssertNil(page.strip(for: MeetingID()))
    }
}
