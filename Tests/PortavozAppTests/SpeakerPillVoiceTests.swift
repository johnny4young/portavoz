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
        let cast = [me, marta, unnamed]

        XCTAssertEqual(SpeakerPill.voice(for: me, in: cast, colorScheme: .light), .you)
        XCTAssertEqual(
            SpeakerPill.voice(for: marta, in: cast, colorScheme: .light),
            .named(VoicePalette.color(for: marta, in: cast, colorScheme: .light)))
        XCTAssertEqual(
            SpeakerPill.voice(for: unnamed, in: cast, colorScheme: .dark),
            .unnamed(VoicePalette.color(for: unnamed, in: cast, colorScheme: .dark)),
            "an unnamed voice keeps its cast-order hue on an open dot")
        XCTAssertEqual(
            SpeakerPill.voice(for: nil, in: cast, colorScheme: .light),
            .unnamed(VoicePalette.unnamed))
    }
}
