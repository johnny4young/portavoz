import Foundation
import PortavozCore
import StorageKit
import XCTest

@testable import ApplicationKit

final class TodayVoicesTests: XCTestCase {
    private typealias Row = MeetingStore.LibraryMeetingRow
    private typealias Voice = MeetingVoiceColumns.Voice

    private let dayStart = Date(timeIntervalSince1970: 1_789_000_000)
    private var day: DateInterval { DateInterval(start: dayStart, duration: 24 * 3600) }
    private let marta = Person(preferredName: "Marta")

    private func at(_ hour: Double) -> Date { dayStart.addingTimeInterval(hour * 3600) }

    private func voice(
        _ name: String?, isMe: Bool = false, person: PersonID? = nil, label: String = "S1",
        talk: TimeInterval, speaker: SpeakerID = SpeakerID()
    ) -> Voice {
        Voice(
            speakerID: speaker, isMe: isMe, label: label, displayName: name, personID: person,
            talkSeconds: talk, firstHeard: 0)
    }

    private func row(
        _ title: String, from start: Double, to end: Double?, state: MeetingLifecycleState = .ready,
        duration: TimeInterval? = nil, voices: [Voice]
    ) -> Row {
        let meeting = Meeting(
            title: title, startedAt: at(start), endedAt: end.map(at), lifecycleState: state)
        let length = duration ?? ((end ?? start) - start) * 3600
        return Row(
            meeting: meeting,
            voiceColumns: voices.isEmpty ? nil : MeetingVoiceColumns(
                duration: length, columns: Array(0..<UInt8(voices.count)), voices: voices))
    }

    private func event(
        _ id: String, from start: Double, to end: Double, _ attendees: [String] = []
    ) -> UpcomingEvent {
        UpcomingEvent(id: id, title: id, startDate: at(start), attendees: attendees, endDate: at(end))
    }

    /// Sprint demo, a 1:1 with Marta and a retro; Marta is one confirmed
    /// person behind two speakers, Nora is only a name, two voices are unnamed.
    private func dayOfMeetings() -> [Row] {
        [
            row("Retro", from: 14, to: 14.6, voices: [
                voice(nil, isMe: true, talk: 100),
                voice("Nora", talk: 200),
                voice(nil, label: "S2", talk: 90)
            ]),
            row("Sprint demo", from: 10, to: 10.7, voices: [
                voice(nil, isMe: true, talk: 300),
                voice("Marta", person: marta.id, talk: 600),
                voice(nil, label: "S3", talk: 120),
                voice(" nora ", talk: 60)
            ]),
            row("1:1", from: 12, to: 12.5, voices: [
                voice(nil, isMe: true, talk: 400),
                voice("Marta G.", person: marta.id, talk: 500)
            ])
        ]
    }

    func testTalkTimeGroupsConfirmedPeopleAndNamesAndKeepsUnnamedVoicesApart() throws {
        let today = TodayVoices(
            day: day, now: at(15.25), meetings: dayOfMeetings(), events: [], people: [:])

        XCTAssertEqual(today.talkers.map(\.identity), [
            .me, .person(marta.id), .name("nora"),
            .unnamed(try XCTUnwrap(today.talkers[3].identity.unnamedID)),
            .unnamed(try XCTUnwrap(today.talkers[4].identity.unnamedID))
        ])
        XCTAssertEqual(today.talkers.map(\.talkSeconds), [800, 1_100, 260, 120, 90], "you first, then most talk")
        XCTAssertEqual(today.talkers.map(\.name), [nil, "Marta G.", "Nora", nil, nil], "the latest name wins")
        XCTAssertEqual(today.talkers.map(\.meetings.count), [3, 2, 2, 1, 1])
        XCTAssertEqual(today.talkers[2].meetings.map(\.title), ["Sprint demo", "Retro"])
        XCTAssertEqual(today.talkers[3].label, "S3")
        XCTAssertEqual(today.talkers.map(\.isUnnamed), [false, false, false, true, true])
        XCTAssertEqual(today.talkers.map(\.tint).first, .you)
        XCTAssertEqual(today.talkers.suffix(2).map(\.tint), [.grey, .grey], "unnamed voices stay grey")
    }

    func testDayAxisPlacesEachRecordedMeetingAtItsTimeWithTheDayHues() throws {
        let today = TodayVoices(
            day: day, now: at(15.25), meetings: dayOfMeetings(), events: [], people: [:])

        XCTAssertEqual(today.recorded.map(\.title), ["Sprint demo", "1:1", "Retro"])
        XCTAssertEqual(today.recorded.map(\.startedAt), [at(10), at(12), at(14)])
        XCTAssertEqual(today.recorded.map(\.duration), [2_520, 1_800, 2_160])
        XCTAssertEqual(today.recordedSeconds, 6_480)
        let demo = today.recorded[0]
        XCTAssertEqual(demo.strip.columns, [0, 1, 2, 3])
        let martaTint = try XCTUnwrap(today.talkers.first { $0.identity == .person(marta.id) }?.tint)
        let noraTint = try XCTUnwrap(today.talkers.first { $0.identity == .name("nora") }?.tint)
        XCTAssertEqual(demo.strip.tints, [.you, martaTint, .grey, noraTint], "a person reads alike on the page")
    }

    func testAVoiceGreyOnThePageStaysGreyInItsStrip() throws {
        let crowd = (1...VoiceHue.paletteSize).map { voice("Person \($0)", talk: Double(100 * $0)) }
        let today = TodayVoices(
            day: day, now: at(15.25),
            meetings: [
                row("All hands", from: 9, to: 10, voices: crowd),
                row("Quick chat", from: 11, to: 11.25, voices: [voice("Zed", talk: 10)])
            ],
            events: [], people: [:])

        let zed = try XCTUnwrap(today.talkers.first { $0.name == "Zed" })
        XCTAssertEqual(zed.tint, .grey)
        XCTAssertEqual(today.recorded[1].strip.tints, [.grey], "a folded voice takes no hue another person holds")
    }

    func testAnUnresolvedInviteeNeverWearsAConfirmedPersonsHue() throws {
        let twoMartas = [marta, Person(preferredName: "Marta")]
        let today = TodayVoices(
            day: day, now: at(15.25), meetings: dayOfMeetings(),
            events: [event("Sync", from: 16, to: 17, ["Marta G."])], people: ["Marta G.": twoMartas])

        let martaTint = try XCTUnwrap(today.talkers.first { $0.identity == .person(marta.id) }?.tint)
        let invitee = try XCTUnwrap(today.upcoming.first?.cast.voices.first)
        XCTAssertEqual(today.upcoming.first?.invitees.first?.personID, nil)
        XCTAssertNotEqual(invitee.tint, martaTint)
    }

    func testAnEarlierRecordingThatRanOverDoesNotHideAMeetingUnderWay() {
        let overran = row("Planning", from: 14, to: 15.1, voices: [voice(nil, isMe: true, talk: 60)])
        let today = TodayVoices(
            day: day, now: at(15.3), meetings: [overran],
            events: [event("Review", from: 15, to: 16)], people: [:])

        XCTAssertEqual(today.upcoming.map(\.id), ["Review"])
        XCTAssertEqual(today.toGo, 0)
    }

    func testRepeatedInviteeNamesKeepDistinctVoices() {
        let today = TodayVoices(
            day: day, now: at(9), meetings: [],
            events: [event("Sync", from: 10, to: 11, ["Ilarion", "ilarion"])], people: [:])

        let ids = today.upcoming.first?.cast.voices.map(\.id) ?? []
        XCTAssertEqual(ids.count, 3)
        XCTAssertEqual(Set(ids).count, ids.count)
    }

    func testARecordingRunsToNow() {
        let recording = row(
            "Live", from: 15, to: nil, state: .recording, duration: 600,
            voices: [voice(nil, isMe: true, talk: 400)])
        let today = TodayVoices(
            day: day, now: at(15.25), meetings: [recording],
            events: [event("Under way", from: 15, to: 15.5)], people: [:])

        XCTAssertEqual(today.recorded.map(\.duration), [900])
        XCTAssertEqual(today.recorded.map(\.isRecording), [true])
        XCTAssertTrue(today.upcoming.isEmpty, "an event under way that is being recorded is its strip")
    }

    func testUpcomingKeepsTodaysEventsAheadAndResolvesInviteesToPeople() {
        let ana = [Person(preferredName: "Ana"), Person(preferredName: "Ana")]
        let today = TodayVoices(
            day: day, now: at(15.25), meetings: dayOfMeetings(),
            events: [
                event("Kickoff", from: 17.5, to: 18, ["Marta", "Marta Gómez", "Ilarion"]),
                event("Sync", from: 16, to: 16.75, ["Marta Gómez", "Ana", "nora"]),
                event("Done", from: 9, to: 9.5),
                event("Late", from: 15, to: 15.5),
                event("Tomorrow", from: 25, to: 26)
            ],
            people: ["Marta": [marta], "Marta Gómez": [marta], "Ana": ana])

        XCTAssertEqual(today.upcoming.map(\.id), ["Late", "Sync", "Kickoff"])
        XCTAssertEqual(today.toGo, 2, "one already under way is not still to go")
        let sync = today.upcoming[1]
        XCTAssertEqual(sync.invitees, [
            TodayVoices.Invitee(name: "Marta G.", personID: marta.id),
            TodayVoices.Invitee(name: "Ana", personID: nil),
            TodayVoices.Invitee(name: "nora", personID: nil)
        ], "a single candidate resolves a name, to the one the day already shows")
        XCTAssertEqual(today.upcoming[2].invitees.map(\.name), ["Marta G.", "Ilarion"], "one person invited once")
        XCTAssertEqual(
            sync.cast.voices.first?.tint,
            today.talkers.first { $0.identity == .person(marta.id) }?.tint)
        XCTAssertEqual(
            sync.cast.voices[2].tint, today.talkers.first { $0.identity == .name("nora") }?.tint,
            "an unconfirmed name heard today keeps its hue")
        XCTAssertEqual(sync.cast.voices.last?.tint, .you)
    }

    func testAnEmptyDayHasNothingToShow() {
        let today = TodayVoices(day: day, now: at(9), meetings: [], events: [], people: [:])
        XCTAssertTrue(today.talkers.isEmpty)
        XCTAssertTrue(today.recorded.isEmpty)
        XCTAssertEqual(today.recordedSeconds, 0)
        XCTAssertEqual(today.toGo, 0)
    }

    func testLoadReadsTodayAndLooksUpTodaysInviteesOnce() async throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let now = at(15.25)
        let expectedDay = try XCTUnwrap(calendar.dateInterval(of: .day, for: now))
        let store = FakeTodayStore(rows: [], people: ["Marta": [marta]])
        let today = try await LoadTodayVoices(store: store).execute(.init(
            now: now,
            events: [
                UpcomingEvent(
                    id: "a", title: "a", startDate: expectedDay.start.addingTimeInterval(20 * 3600),
                    attendees: ["Marta", "Marta"]),
                UpcomingEvent(
                    id: "b", title: "b", startDate: expectedDay.end.addingTimeInterval(3600),
                    attendees: ["Ilarion"])
            ],
            later: [UpcomingEvent(
                id: "hero", title: "hero", startDate: expectedDay.end.addingTimeInterval(7200),
                attendees: ["Marta", "Nora"])],
            calendar: calendar))

        let calls = await store.calls
        XCTAssertEqual(calls.intervals, [expectedDay])
        XCTAssertEqual(calls.aliases, [["Marta", "Nora"]], "only today's and the later hero's invitees")
        XCTAssertEqual(today.upcoming.map(\.id), ["a"])
        XCTAssertEqual(
            today.later.first?.invitees,
            [TodayVoices.Invitee(name: "Marta", personID: marta.id), TodayVoices.Invitee(name: "Nora", personID: nil)])
        XCTAssertEqual(
            today.upcoming.first?.invitees, [TodayVoices.Invitee(name: "Marta", personID: marta.id)],
            "nobody spoke today, so the person's own name")

        let failing = FakeTodayStore(rows: [], people: [:], failsLookup: true)
        let degraded = try await LoadTodayVoices(store: failing).execute(.init(
            now: now, events: [UpcomingEvent(
                id: "a", title: "a", startDate: expectedDay.start.addingTimeInterval(20 * 3600),
                attendees: ["Marta"])],
            calendar: calendar))
        XCTAssertEqual(
            degraded.upcoming.first?.invitees, [TodayVoices.Invitee(name: "Marta", personID: nil)],
            "a failed lookup leaves plain names")

        let quiet = FakeTodayStore(rows: [], people: [:])
        _ = try await LoadTodayVoices(store: quiet).execute(.init(now: now, events: [], calendar: calendar))
        let quietAliases = await quiet.calls.aliases
        XCTAssertTrue(quietAliases.isEmpty, "no invitees, no lookup")
    }
}

private extension TodayVoices.Identity {
    var unnamedID: SpeakerID? {
        if case .unnamed(let id) = self { return id }
        return nil
    }
}

private actor FakeTodayStore: TodayVoicesReading {
    struct Calls {
        var intervals: [DateInterval] = []
        var aliases: [[String]] = []
    }

    let rows: [MeetingStore.LibraryMeetingRow]
    let people: [String: [Person]]
    let failsLookup: Bool
    var calls = Calls()

    init(rows: [MeetingStore.LibraryMeetingRow], people: [String: [Person]], failsLookup: Bool = false) {
        self.rows = rows
        self.people = people
        self.failsLookup = failsLookup
    }

    func meetingRows(startedIn interval: DateInterval) async throws -> [MeetingStore.LibraryMeetingRow] {
        calls.intervals.append(interval)
        return rows
    }

    func people(matchingAliases aliases: [String]) async throws -> [String: [Person]] {
        calls.aliases.append(aliases)
        if failsLookup { throw CocoaError(.fileReadCorruptFile) }
        return people.filter { aliases.contains($0.key) }
    }
}
