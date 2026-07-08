import Foundation
import XCTest

@testable import AudioPlaybackKit

final class MeetingPlayerTests: XCTestCase {
    @MainActor
    func testMakeReturnsNilWhenNoChannelFileExists() async {
        let player = await MeetingPlayer.make(
            channelFiles: [URL(fileURLWithPath: "/nonexistent/system.caf")])
        XCTAssertNil(player, "a player over missing audio must not be built")
    }

    @MainActor
    func testMakeReturnsNilForEmptyList() async {
        let player = await MeetingPlayer.make(channelFiles: [])
        XCTAssertNil(player)
    }
}
