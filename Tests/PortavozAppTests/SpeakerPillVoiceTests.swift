import ApplicationKit
import PortavozCore
import SwiftUI
import XCTest

@testable import portavoz_app

final class SpeakerPillVoiceTests: XCTestCase {
    @MainActor
    func testYouNamedAndUnnamedVoicesMapToTheirChipStyles() async {
        let me = Speaker(meetingID: MeetingID(), label: "Me", isMe: true)
        let marta = Speaker(meetingID: me.meetingID, label: "S1", displayName: "Marta")
        let unnamed = Speaker(meetingID: me.meetingID, label: "S2")
        let cast = VoiceCast(speakers: [me, marta, unnamed], segments: [])

        XCTAssertEqual(SpeakerPill.voice(for: me, in: cast, colorScheme: .light), .you)
        XCTAssertEqual(
            SpeakerPill.voice(for: marta, in: cast, colorScheme: .light),
            .named(VoicePalette.color(.hue(VoiceHue.index(name: "Marta")), colorScheme: .light)))
        XCTAssertEqual(
            SpeakerPill.voice(for: unnamed, in: cast, colorScheme: .dark),
            .unnamed(VoicePalette.unnamed),
            "an unnamed voice stays grey on an open dot until named")
        XCTAssertEqual(
            SpeakerPill.voice(for: nil, in: cast, colorScheme: .light),
            .unnamed(VoicePalette.unnamed))
    }

    @MainActor
    func testABlankNameStillReadsAsUnnamed() async {
        let blank = Speaker(meetingID: MeetingID(), label: "S1", displayName: "  ")
        let cast = VoiceCast(speakers: [blank], segments: [])
        XCTAssertEqual(SpeakerPill.voice(for: blank, in: cast, colorScheme: .light), .unnamed(VoicePalette.unnamed))
    }

    @MainActor
    func testVoicesPastTheCastAreGreyEvenWhenNamed() async {
        let meeting = MeetingID()
        let people = ["Marta", "Bruno", "Carla", "Ilarion", "Lucia", "Elena"].enumerated().map {
            Speaker(meetingID: meeting, label: "S\($0 + 1)", displayName: $1)
        }
        let segments = people.enumerated().map { index, speaker in
            TranscriptSegment(
                meetingID: meeting, speakerID: speaker.id, channel: .system, text: "x",
                startTime: Double(index * 10), endTime: Double(index * 10 + 9 - index), isFinal: true)
        }
        let cast = VoiceCast(speakers: people, segments: segments)

        XCTAssertEqual(
            SpeakerPill.voice(for: people[5], in: cast, colorScheme: .light),
            .named(VoicePalette.unnamed))
        XCTAssertEqual(cast.others.map(\.name), ["Elena"])
    }
}
