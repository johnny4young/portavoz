import Foundation
import PortavozCore
import XCTest

@testable import portavoz_app

/// The live Apuntador list rendered every card at full height, newest first,
/// none dropped. A real 18-minute meeting produced 23 cards — nine dismissed by
/// hand during the call — and only two were addressed to the user (D504).
final class CompanionCardWindowTests: XCTestCase {
    func testOnlyTheNewestFewStayOpen() {
        let cards = (0..<8).map { card(at: Double($0), directed: false) }

        let rows = CompanionCardWindow.rows(
            cards: cards, focused: nil, overrides: [:])

        XCTAssertEqual(rows.count, 8, "nothing is dropped, only folded")
        XCTAssertEqual(
            rows.map(\.presentation),
            Array(repeating: .clamped, count: CompanionCardWindow.expandedLimit)
                + Array(repeating: .collapsed, count: 8 - CompanionCardWindow.expandedLimit))
        XCTAssertEqual(
            rows.map(\.card.askedAt), [7, 6, 5, 4, 3, 2, 1, 0],
            "newest first")
    }

    func testTheFocusedCardIsNotRepeatedInTheList() {
        let directed = card(at: 5, directed: true)
        let cards = [card(at: 1, directed: false), directed, card(at: 9, directed: false)]

        let rows = CompanionCardWindow.rows(
            cards: cards, focused: directed.id, overrides: [:])

        XCTAssertEqual(rows.count, 2)
        XCTAssertFalse(rows.contains { $0.id == directed.id })
    }

    func testOpeningAnOldCardClosesTheOldestStillOpenOne() {
        let cards = (0..<6).map { card(at: Double($0), directed: false) }
        let oldest = cards[0]

        let rows = CompanionCardWindow.rows(
            cards: cards, focused: nil, overrides: [oldest.id: .clamped])

        XCTAssertEqual(
            rows.filter { $0.presentation != .collapsed }.count,
            CompanionCardWindow.expandedLimit,
            "the recency window counts what the user opened, so the panel keeps its size")
        XCTAssertEqual(rows.last?.presentation, .clamped)
        XCTAssertEqual(rows.last?.id, oldest.id)
    }

    func testAnExplicitCollapseWinsOverRecency() {
        let cards = (0..<3).map { card(at: Double($0), directed: false) }

        let rows = CompanionCardWindow.rows(
            cards: cards, focused: nil, overrides: [cards[2].id: .collapsed])

        XCTAssertEqual(rows.first?.presentation, .collapsed)
    }

    func testOnlyADirectedCardEarnsTheFocusSlot() {
        let older = card(at: 1, directed: true)
        let newer = card(at: 8, directed: true)
        let context = card(at: 9, directed: false)

        XCTAssertEqual(
            CompanionCardWindow.focusCard([older, newer, context])?.id, newer.id,
            "the newest question addressed to the user wins")
        XCTAssertNil(CompanionCardWindow.focusCard([context]))
        XCTAssertNil(CompanionCardWindow.focusCard([]))
    }

    func testOnlyAnAnswerTooLongToClampOffersToOpenFully() {
        let short = CompanionCardWindow.Row(
            card: card(at: 1, directed: false, answer: "Short."),
            presentation: .clamped)
        let long = CompanionCardWindow.Row(
            card: card(
                at: 2,
                directed: false,
                answer: String(
                    repeating: "x",
                    count: CompanionCardWindow.openFullyAboveCharacters + 1)),
            presentation: .clamped)
        let opened = CompanionCardWindow.Row(card: long.card, presentation: .full)

        XCTAssertFalse(short.canOpenFully)
        XCTAssertTrue(long.canOpenFully)
        XCTAssertFalse(opened.canOpenFully, "an open card offers to close, not to open")
    }

    func testTheTabBadgeNeverGoesNegativeWhenCardsAreDismissed() {
        XCTAssertEqual(CompanionCardWindow.unseen(liveCount: 7, seenCount: 4), 3)
        XCTAssertEqual(CompanionCardWindow.unseen(liveCount: 2, seenCount: 6), 0)
    }

    private func card(
        at askedAt: TimeInterval,
        directed: Bool,
        answer: String = "An answer."
    ) -> CompanionCard {
        CompanionCard(
            question: "Question at \(askedAt)?",
            answer: answer,
            kind: .context,
            source: "on-device",
            directed: directed,
            askedAt: askedAt)
    }
}
