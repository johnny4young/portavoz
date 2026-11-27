import ApplicationKit
import Foundation
import PortavozCore
import XCTest

@testable import portavoz_app

final class MeetingMarginAttributionTests: XCTestCase {
    private let me = OpenItemSource.Voice(speakerID: SpeakerID(), isMe: true, label: "Me", displayName: nil)
    private let marta = OpenItemSource.Voice(speakerID: SpeakerID(), isMe: false, label: "S1", displayName: "Marta")

    private func texts(saidBy: OpenItemSource.Voice?, owner: OpenItemSource.Voice?) -> [String] {
        MeetingMarginAttribution.clauses(
            OpenItemSource(saidBy: saidBy, time: 1, owner: owner, dueAt: nil)
        ).map(\.text)
    }

    func testOnePersonWhoSaidAndOwnsItReadsAsOneClause() {
        XCTAssertEqual(texts(saidBy: me, owner: me), [L10n.text("You said it and own it")])
        XCTAssertEqual(texts(saidBy: marta, owner: marta), [L10n.format("%@ said it and owns it", "Marta")])
    }

    func testSomeoneElseAskingNamesBothPeople() {
        XCTAssertEqual(texts(saidBy: marta, owner: me), [L10n.format("%@ asked", "Marta"), L10n.text("You own it")])
        XCTAssertEqual(texts(saidBy: me, owner: marta), [L10n.text("You asked"), L10n.format("%@ owns it", "Marta")])
    }

    func testAnUnknownSideIsLeftOut() {
        XCTAssertEqual(texts(saidBy: marta, owner: nil), [L10n.format("%@ said it", "Marta")])
        XCTAssertEqual(texts(saidBy: nil, owner: me), [L10n.text("You own it")])
        XCTAssertTrue(texts(saidBy: nil, owner: nil).isEmpty)
    }
}
