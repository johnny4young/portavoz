import ApplicationKit
import Foundation
import PortavozCore
import XCTest

@testable import StorageKit
@testable import portavoz_app

final class AutomationEntityCatalogTests: XCTestCase {
    func testLookupRejectsUnboundedOrOversizedInputs() {
        XCTAssertThrowsError(try AutomationEntityLookup<MeetingID>(limit: 0)) {
            XCTAssertEqual($0 as? AutomationEntityLookupError, .invalidLimit)
        }
        XCTAssertThrowsError(try AutomationEntityLookup<MeetingID>(
            identifiers: (0...50).map { _ in MeetingID() })) {
            XCTAssertEqual(
                $0 as? AutomationEntityLookupError,
                .tooManyIdentifiers)
        }
        XCTAssertThrowsError(try AutomationEntityLookup<MeetingID>(
            matching: String(repeating: "a", count: 121))) {
            XCTAssertEqual($0 as? AutomationEntityLookupError, .queryTooLong)
        }
        XCTAssertThrowsError(try AutomationEntityLookup<MeetingID>(
            identifiers: [MeetingID()],
            matching: "ambiguous")) {
            XCTAssertEqual(
                $0 as? AutomationEntityLookupError,
                .conflictingSelectors)
        }
    }

    func testCatalogIsBoundedLiteralAndPreservesExactIdentifierOrder() async throws {
        let store = try MeetingStore.inMemory()
        let older = Meeting(
            title: "Budget 100%_review",
            startedAt: Date(timeIntervalSince1970: 100))
        let newer = Meeting(
            title: "Other meeting",
            startedAt: Date(timeIntervalSince1970: 200))
        let deleted = Meeting(
            title: "Budget 100%_deleted",
            startedAt: Date(timeIntervalSince1970: 300))
        try await store.save(older)
        try await store.save(newer)
        try await store.save(deleted)
        try await store.delete(deleted.id)

        let loader = LoadAutomationEntities(catalog: store)
        let literal = try await loader.meetings(AutomationEntityLookup(
            matching: "100%_",
            limit: 20))
        XCTAssertEqual(literal.map(\.id), [older.id])

        let exact = try await loader.meetings(AutomationEntityLookup(
            identifiers: [older.id, newer.id, older.id, deleted.id],
            limit: 4))
        XCTAssertEqual(exact.map(\.id), [older.id, newer.id])

        let suggested = try await loader.meetings(AutomationEntityLookup(limit: 1))
        XCTAssertEqual(suggested.map(\.id), [newer.id])
    }

    func testCatalogExposesOnlyCanonicalPeopleAndConfirmedCommitments() async throws {
        let store = try MeetingStore.inMemory()
        let meeting = Meeting(title: "Entity source", startedAt: Date())
        let first = Speaker(meetingID: meeting.id, label: "S1")
        let second = Speaker(meetingID: meeting.id, label: "S2")
        try await store.save(meeting)
        try await store.save([first, second])
        let ana = try await store.createPersonAndLink(
            speakerID: first.id,
            preferredName: "Ana 100%_QA",
            source: .manualName).person
        _ = try await store.createPersonAndLink(
            speakerID: second.id,
            preferredName: "Bea",
            source: .manualName)

        let visible = try await confirm(
            title: "Send 100%_brief",
            meetingID: meeting.id,
            store: store)
        let dismissed = try await confirm(
            title: "Send 100%_discarded",
            meetingID: meeting.id,
            store: store)
        _ = try await store.applyCommitmentTransition(
            .dismiss,
            to: dismissed.id,
            at: Date().addingTimeInterval(1))

        let loader = LoadAutomationEntities(catalog: store)
        let people = try await loader.people(AutomationEntityLookup(
            matching: "100%_",
            limit: 20))
        XCTAssertEqual(people.map(\.id), [ana.id])

        let commitments = try await loader.commitments(AutomationEntityLookup(
            matching: "100%_",
            limit: 20))
        XCTAssertEqual(commitments.map(\.id), [visible.id])
        XCTAssertFalse(commitments.contains { $0.id == dismissed.id })
    }

    @MainActor
    func testAppAdapterDropsForgedIdentifiersAndMapsStableEntityValues() async throws {
        let store = try MeetingStore.inMemory()
        let meeting = Meeting(
            title: "Launch review",
            startedAt: Date(timeIntervalSince1970: 1_800_000_000))
        try await store.save(meeting)
        let catalog = AppAutomationEntityCatalog(store: store)

        let entities = try await catalog.meetings(
            identifiers: ["not-a-uuid", meeting.id.rawValue.uuidString],
            matching: nil,
            limit: 2)

        XCTAssertEqual(entities.map(\.id), [meeting.id.rawValue.uuidString])
        XCTAssertEqual(entities.map(\.title), [meeting.title])
        XCTAssertFalse(entities[0].dateDescription.isEmpty)
    }

    private func confirm(
        title: String,
        meetingID: MeetingID,
        store: MeetingStore
    ) async throws -> Commitment {
        try await store.confirmCommitment(
            CommitmentConfirmation(
                title: title,
                origin: .manual(meetingID: meetingID)),
            at: Date()).commitment
    }
}
