import PortavozCore
import StorageKit
import XCTest

@testable import ApplicationKit

final class VoiceCastTests: XCTestCase {
    private typealias Member = VoiceCast.Member

    func testThreeVoicesEachKeepTheirStableHueOrderedByTalk() {
        let cast = VoiceCast(
            members: [
                Member(key: "me", isMe: true, name: nil, talkSeconds: 31),
                Member(key: "s1", name: "Marta", talkSeconds: 40),
                Member(key: "s2", name: "Ilarion", talkSeconds: 29)
            ],
            ordering: .talkShare)

        XCTAssertEqual(cast.voices.map(\.key), ["s1", "me", "s2"])
        XCTAssertEqual(cast.voices.map(\.tint), [
            .hue(VoiceHue.index(name: "Marta")),
            .you,
            .hue(VoiceHue.index(name: "Ilarion"))
        ], "without a clash each name keeps the hue it has always had")
        XCTAssertTrue(cast.others.isEmpty)
        XCTAssertEqual(cast.voices.map(\.share), [0.4, 0.31, 0.29])
    }

    func testSixVoicesAllKeepADistinctColour() {
        let names = ["Marta", "Ilarion", "Nora", "Diego", "Carla"]
        let cast = VoiceCast(
            members: [Member(key: "me", isMe: true, name: nil, talkSeconds: 10)]
                + names.enumerated().map { Member(key: "s\($0)", name: $1, talkSeconds: Double(20 - $0)) },
            ordering: .talkShare)

        XCTAssertEqual(cast.voices.count, 6)
        XCTAssertTrue(cast.others.isEmpty)
        let hues = cast.voices.compactMap { voice -> Int? in
            if case .hue(let index) = voice.tint { return index }
            return nil
        }
        XCTAssertEqual(Set(hues).count, 5, "five named voices, five different hues: \(hues)")
        XCTAssertEqual(cast.tint(for: "me"), .you)
    }

    func testTwelveVoicesKeepYouAndTheTopFiveAndFoldTheRestByTalkShare() {
        var members = [Member(key: "me", isMe: true, name: nil, talkSeconds: 14)]
        let names: [String?] = [
            "Marta", "Diego", "Ilarion", "Nora", "Carla", "Elena", "Bruno", nil, "Pablo", nil, "Lucia"
        ]
        for (index, name) in names.enumerated() {
            members.append(Member(key: "s\(index)", name: name, talkSeconds: Double(30 - index * 2)))
        }

        let cast = VoiceCast(members: members, ordering: .talkShare)

        XCTAssertEqual(cast.voices.map(\.key), ["s0", "s1", "s2", "s3", "s4", "me"])
        XCTAssertEqual(cast.others.map(\.key), ["s5", "s6", "s7", "s8", "s9", "s10"])
        XCTAssertTrue(cast.others.allSatisfy { $0.tint == .grey })
        XCTAssertEqual(cast.tint(for: "s10"), .grey)
        XCTAssertEqual(cast.tint(for: "unknown"), .grey)
    }

    func testUnnamedVoicesStayGreyUntilNamed() {
        let unnamed = VoiceCast(
            members: [
                Member(key: "me", isMe: true, name: nil, talkSeconds: 5),
                Member(key: "s1", name: nil, talkSeconds: 9),
                Member(key: "s2", name: "  ", talkSeconds: 4)
            ],
            ordering: .talkShare)
        XCTAssertEqual(unnamed.voices.map(\.tint), [.grey, .you, .grey])

        let named = VoiceCast(
            members: [
                Member(key: "me", isMe: true, name: nil, talkSeconds: 5),
                Member(key: "s1", name: "Marta", talkSeconds: 9)
            ],
            ordering: .talkShare)
        XCTAssertEqual(named.tint(for: "s1"), .hue(VoiceHue.index(name: "Marta")))
    }

    func testClashingNamesTakeTheNextFreeHueInOrderOfAppearance() {
        XCTAssertEqual(
            VoiceHue.index(name: "Marta"),
            VoiceHue.index(name: "Nora"),
            "fixture: the two names share a stable hue")
        let cast = VoiceCast(
            members: [
                Member(key: "s1", name: "Marta", talkSeconds: 1),
                Member(key: "s2", name: "Nora", talkSeconds: 9)
            ],
            ordering: .talkShare)

        let marta = VoiceHue.index(name: "Marta")
        XCTAssertEqual(cast.tint(for: "s1"), .hue(marta), "the first to appear keeps the stable hue")
        XCTAssertEqual(cast.tint(for: "s2"), .hue((marta + 1) % VoiceHue.paletteSize))
    }

    func testLiveCastLeadsWithTheCurrentSpeakerThenMostRecent() {
        let cast = VoiceCast(
            members: [
                Member(key: "me", isMe: true, name: nil, talkSeconds: 20, lastHeard: 100),
                Member(key: "s1", name: "Marta", talkSeconds: 90, lastHeard: 60),
                Member(key: "s2", name: "Carla", talkSeconds: 5, lastHeard: 110),
                Member(key: "s3", name: nil, talkSeconds: 50, lastHeard: nil)
            ],
            ordering: .recency,
            current: "me")

        XCTAssertEqual(cast.voices.map(\.key), ["me", "s2", "s1", "s3"])
    }

    func testLiveRankingAndRelabelChurnNeverRecolourSomeoneOnScreen() {
        let names = ["Marta", "Nora", "Diego", "Carla", "Ilarion", "Bruno", "Elena"]
        func live(_ order: [String], relabel: [String: String] = [:], previous: VoiceCast?) -> VoiceCast {
            VoiceCast(
                members: names.enumerated().map { index, name in
                    Member(
                        key: relabel[name] ?? "S\(index + 1)", name: name, talkSeconds: 10,
                        lastHeard: Double(order.firstIndex(of: name).map { 100 - $0 } ?? 0))
                },
                ordering: .recency,
                previous: previous)
        }
        func hue(_ cast: VoiceCast, _ name: String) -> VoiceCast.Tint? {
            (cast.voices + cast.others).first { $0.name == name }?.tint
        }

        let first = live(["Marta", "Nora", "Diego", "Carla", "Ilarion"], previous: nil)
        let martaHue = hue(first, "Marta")
        let noraHue = hue(first, "Nora")
        XCTAssertEqual(hue(first, "Bruno"), .grey)

        // Bruno speaks, Ilarion drops out; Marta's live label changes from S1 to S9.
        let second = live(
            ["Bruno", "Marta", "Nora", "Diego", "Carla"], relabel: ["Marta": "S9"], previous: first)
        XCTAssertEqual(hue(second, "Marta"), martaHue)
        XCTAssertEqual(hue(second, "Nora"), noraHue)
        XCTAssertEqual(hue(second, "Ilarion"), .grey)
        XCTAssertEqual(hue(second, "Bruno"), hue(first, "Ilarion"), "Bruno takes the hue Ilarion freed")
        XCTAssertEqual(second.voices.first?.name, "Bruno")
    }

    func testMeetingCastFromSpeakersAndSegments() {
        let meeting = MeetingID()
        let me = Speaker(meetingID: meeting, label: "Me", isMe: true)
        let marta = Speaker(meetingID: meeting, label: "S1", displayName: "Marta")
        let silent = Speaker(meetingID: meeting, label: "S2")
        let segments = [
            segment(meeting, marta.id, 0, 6),
            segment(meeting, me.id, 6, 8),
            segment(meeting, nil, 8, 20),
            segment(meeting, me.id, 30, 30)
        ]

        let cast = VoiceCast(speakers: [me, marta, silent], segments: segments)

        XCTAssertEqual(cast.voices.map(\.key), [marta, me, silent].map { VoiceCast.key($0.id) })
        XCTAssertEqual(cast.voices.map(\.talkSeconds), [6, 2, 0])
        XCTAssertEqual(cast.tint(for: me), .you)
        XCTAssertEqual(cast.tint(for: silent), .grey)
    }

    func testMeetingCastGivesAClashToWhoeverWasHeardFirst() {
        let meeting = MeetingID()
        let nora = Speaker(meetingID: meeting, label: "S1", displayName: "Nora")
        let marta = Speaker(meetingID: meeting, label: "S2", displayName: "Marta")
        let cast = VoiceCast(
            speakers: [nora, marta],
            segments: [segment(meeting, nora.id, 10, 30), segment(meeting, marta.id, 0, 5)])

        let hue = VoiceHue.index(name: "Marta")
        XCTAssertEqual(cast.tint(for: marta), .hue(hue))
        XCTAssertEqual(cast.tint(for: nora), .hue((hue + 1) % VoiceHue.paletteSize))
    }

    func testLibraryStripCastAgreesWithTheMeetingOnAClash() {
        func voice(_ name: String?, isMe: Bool = false, talk: TimeInterval, heard: TimeInterval)
            -> MeetingVoiceColumns.Voice {
            MeetingVoiceColumns.Voice(
                speakerID: SpeakerID(), isMe: isMe, label: "S", displayName: name,
                talkSeconds: talk, firstHeard: heard)
        }
        let stored = MeetingVoiceColumns(duration: 30, columns: [0, 1, 2, VoiceColumns.silence], voices: [
            voice("Marta", talk: 3, heard: 0),
            voice(nil, isMe: true, talk: 2, heard: 4),
            voice("Nora", talk: 5, heard: 10)
        ])
        let strip = VoiceStripColumns(columns: stored)
        let hue = VoiceHue.index(name: "Marta")
        XCTAssertEqual(strip.cast.voices.map(\.name), ["Nora", "Marta", nil], "drawn by talk share")
        XCTAssertEqual(strip.tints, [.hue(hue), .you, .hue((hue + 1) % VoiceHue.paletteSize)])
        XCTAssertEqual(strip.columns, stored.columns)
    }

    private func segment(
        _ meeting: MeetingID, _ speaker: SpeakerID?, _ start: TimeInterval, _ end: TimeInterval
    ) -> TranscriptSegment {
        TranscriptSegment(
            meetingID: meeting, speakerID: speaker, channel: .system, text: "x",
            startTime: start, endTime: end, isFinal: true)
    }
}
