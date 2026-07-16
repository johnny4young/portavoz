import Foundation
import IntegrationsKit
import PortavozCore
import XCTest

@testable import StorageKit
@testable import portavoz_app

@MainActor
final class LibraryModelTests: XCTestCase {
    func testReloadPublishesOneCompleteSnapshotAtTheRequestedVersion() async {
        let fixture = LibraryModelFixture()
        let client = LibraryModelClientFake(fixture: fixture)
        client.agenda = fixture.agenda
        let model = LibraryModel(client: client, searchDelay: .zero)

        _ = await model.send(.reload(version: 7))

        XCTAssertEqual(model.state.loadPhase, .loaded)
        XCTAssertEqual(model.state.reloadVersion, 7)
        XCTAssertEqual(model.state.meetings.map(\.id), [fixture.meeting.id])
        XCTAssertEqual(model.state.voiceMixes[fixture.meeting.id], fixture.voiceMix)
        XCTAssertEqual(model.state.openItems.map(\.item.id), [fixture.actionItem.id])
        XCTAssertEqual(model.state.trashed.map(\.meeting.id), [fixture.deleted.meeting.id])
        XCTAssertEqual(model.state.upcomingToday, fixture.agenda.today)
        XCTAssertEqual(model.state.upcomingTomorrow, fixture.agenda.tomorrow)
        XCTAssertTrue(model.state.offerCalendar)
        XCTAssertEqual(
            client.calls,
            [.meetings, .voiceMixes([fixture.meeting.id]), .openItems(20), .trash, .agenda])
    }

    func testReloadDistinguishesEmptyDegradedAndFailedState() async {
        let fixture = LibraryModelFixture()

        let emptyClient = LibraryModelClientFake(fixture: fixture)
        emptyClient.meetings = []
        emptyClient.voiceMixes = [:]
        emptyClient.openItems = []
        emptyClient.trash = []
        let emptyModel = LibraryModel(client: emptyClient, searchDelay: .zero)
        _ = await emptyModel.send(.reload(version: 1))
        XCTAssertEqual(emptyModel.state.loadPhase, .empty)

        let degradedClient = LibraryModelClientFake(fixture: fixture)
        degradedClient.failures = [.voiceMixes]
        let degradedModel = LibraryModel(client: degradedClient, searchDelay: .zero)
        _ = await degradedModel.send(.reload(version: 2))
        XCTAssertEqual(degradedModel.state.loadPhase, .degraded(failures: 1))
        XCTAssertEqual(degradedModel.state.meetings.map(\.id), [fixture.meeting.id])
        XCTAssertTrue(degradedModel.state.voiceMixes.isEmpty)

        let failedClient = LibraryModelClientFake(fixture: fixture)
        failedClient.failures = [.meetings, .openItems, .trash]
        let failedModel = LibraryModel(client: failedClient, searchDelay: .zero)
        _ = await failedModel.send(.reload(version: 3))
        XCTAssertEqual(failedModel.state.loadPhase, .failed)
        XCTAssertTrue(failedModel.state.meetings.isEmpty)
        XCTAssertTrue(failedModel.state.openItems.isEmpty)
        XCTAssertTrue(failedModel.state.trashed.isEmpty)
    }

    func testOlderReloadCannotReplaceARequestedNewerVersion() async {
        let fixture = LibraryModelFixture()
        let client = LibraryModelClientFake(fixture: fixture)
        let model = LibraryModel(client: client, searchDelay: .zero)

        _ = await model.send(.reload(version: 9))
        client.meetings = []
        _ = await model.send(.reload(version: 8))

        XCTAssertEqual(model.state.reloadVersion, 9)
        XCTAssertEqual(model.state.meetings.map(\.id), [fixture.meeting.id])
        XCTAssertEqual(client.calls.filter { $0 == .meetings }.count, 1)
    }

    func testSearchTrimsInputAndOwnsLoadedEmptyAndDegradedState() async {
        let fixture = LibraryModelFixture()
        let client = LibraryModelClientFake(fixture: fixture)
        let model = LibraryModel(client: client, searchDelay: .zero)

        _ = await model.send(.queryChanged("  presupuesto  "))
        _ = await model.send(.search)
        XCTAssertEqual(client.queries, ["presupuesto"])
        XCTAssertEqual(model.state.hits.map(\.segmentID), [fixture.hit.segmentID])
        XCTAssertEqual(model.state.searchPhase, .loaded)

        client.hits = []
        _ = await model.send(.queryChanged("missing"))
        _ = await model.send(.search)
        XCTAssertEqual(model.state.searchPhase, .empty)

        client.failures = [.search]
        _ = await model.send(.queryChanged("broken"))
        _ = await model.send(.search)
        XCTAssertTrue(model.state.hits.isEmpty)
        XCTAssertEqual(model.state.searchPhase, .degraded)

        _ = await model.send(.queryChanged("   "))
        XCTAssertTrue(model.state.hits.isEmpty)
        XCTAssertEqual(model.state.searchPhase, .idle)
    }

    func testMutationsFlowThroughActionsAndReturnNavigationEffects() async {
        let fixture = LibraryModelFixture()
        let client = LibraryModelClientFake(fixture: fixture)
        let model = LibraryModel(client: client, searchDelay: .zero)

        _ = await model.send(.beginRename(fixture.meeting))
        _ = await model.send(.renameTitleChanged("  Weekly sync  "))
        let rename = try? XCTUnwrap(model.state.rename)
        if let rename {
            _ = await model.send(.confirmRename(rename.meeting, title: rename.title))
        }
        _ = await model.send(.setActionItem(fixture.actionItem.id, done: true))
        let deleteEffect = await model.send(.delete(fixture.meeting.id))
        _ = await model.send(.restore(fixture.deleted.meeting.id))
        _ = await model.send(.purge(fixture.deleted))

        XCTAssertNil(model.state.rename)
        XCTAssertEqual(deleteEffect, .deletedMeeting(fixture.meeting.id))
        XCTAssertTrue(client.calls.contains(.rename("Weekly sync")))
        XCTAssertTrue(client.calls.contains(.setActionItem(fixture.actionItem.id, true)))
        XCTAssertTrue(client.calls.contains(.delete(fixture.meeting.id)))
        XCTAssertTrue(client.calls.contains(.restore(fixture.deleted.meeting.id)))
        XCTAssertTrue(client.calls.contains(.purge(fixture.deleted.meeting.id)))
    }

    func testDegradableMutationFailureIsRecordedWithoutChangingItsEffect() async {
        let fixture = LibraryModelFixture()
        let client = LibraryModelClientFake(fixture: fixture)
        client.failures = [.delete]
        let model = LibraryModel(client: client, searchDelay: .zero)

        let effect = await model.send(.delete(fixture.meeting.id))

        XCTAssertEqual(effect, .deletedMeeting(fixture.meeting.id))
        XCTAssertEqual(model.state.lastActionError, LibraryModelFailure.delete.localizedDescription)
    }

    func testImportOwnsProgressSuccessAndVisibleFailureState() async {
        let fixture = LibraryModelFixture()
        let client = LibraryModelClientFake(fixture: fixture)
        let model = LibraryModel(client: client, searchDelay: .zero)
        let url = URL(fileURLWithPath: "/tmp/meeting.m4a")

        let effect = await model.send(.importFile(url))

        XCTAssertEqual(effect, .openMeeting(fixture.importedID))
        XCTAssertNil(model.state.importStatus)
        XCTAssertNil(model.state.importError)
        XCTAssertTrue(client.calls.contains(.importFile(url)))

        client.failures = [.importFile]
        let failedEffect = await model.send(.importFile(url))
        XCTAssertNil(failedEffect)
        XCTAssertNil(model.state.importStatus)
        XCTAssertEqual(
            model.state.importError,
            LibraryModelFailure.importFile.localizedDescription)
        _ = await model.send(.dismissImportError)
        XCTAssertNil(model.state.importError)
    }

    func testCalendarAndBriefActionsStayInsideTheFeatureModel() async {
        let fixture = LibraryModelFixture()
        let client = LibraryModelClientFake(fixture: fixture)
        client.agenda = fixture.agenda
        client.brief = fixture.brief
        let model = LibraryModel(client: client, searchDelay: .zero)

        _ = await model.send(.refreshAgenda)
        _ = await model.send(.requestCalendarAccess)
        _ = await model.send(.openBrief(fixture.eventToday))

        XCTAssertTrue(client.calls.contains(.requestCalendarAccess))
        XCTAssertTrue(client.calls.contains(.brief(fixture.eventToday.id)))
        XCTAssertNil(model.state.briefLoading)
        XCTAssertEqual(model.state.brief?.event, fixture.eventToday)
        _ = await model.send(.dismissBrief)
        XCTAssertNil(model.state.brief)
    }
}

private struct LibraryModelFixture {
    let meeting: Meeting
    let actionItem: ActionItem
    let importedID: MeetingID
    let eventToday: UpcomingEvent
    let eventTomorrow: UpcomingEvent
    let deleted: MeetingStore.DeletedMeeting
    let hit: SearchHit

    init() {
        let meeting = Meeting(
            title: "Reunión",
            startedAt: Date(timeIntervalSince1970: 1_789_000_000))
        self.meeting = meeting
        actionItem = ActionItem(text: "Enviar presupuesto")
        importedID = MeetingID()
        eventToday = UpcomingEvent(
            title: "Planning",
            startDate: Date(timeIntervalSince1970: 1_789_010_000),
            attendees: ["Ana"])
        eventTomorrow = UpcomingEvent(
            title: "Review",
            startDate: Date(timeIntervalSince1970: 1_789_100_000),
            attendees: ["Luis"])
        deleted = MeetingStore.DeletedMeeting(
            meeting: Meeting(
                title: "Deleted",
                startedAt: Date(timeIntervalSince1970: 1_788_000_000)),
            deletedAt: Date(timeIntervalSince1970: 1_789_200_000))
        hit = SearchHit(
            meetingID: meeting.id,
            meetingTitle: meeting.title,
            segmentID: UUID(),
            snippet: "presupuesto",
            startTime: 12)
    }

    var voiceMix: [MeetingStore.VoiceMixSlice] {
        [MeetingStore.VoiceMixSlice(
            isMe: true,
            displayName: "Me",
            fraction: 1,
            order: 0)]
    }

    var openItem: MeetingStore.OpenActionItem {
        MeetingStore.OpenActionItem(
            meetingID: meeting.id,
            meetingTitle: meeting.title,
            item: actionItem)
    }

    var agenda: LibraryModel.Agenda {
        LibraryModel.Agenda(
            offerCalendar: true,
            today: [eventToday],
            tomorrow: [eventTomorrow])
    }

    var brief: MeetingBrief {
        MeetingBrief(
            event: eventToday,
            related: [],
            openItems: [openItem],
            whatToKnow: [])
    }
}

private enum LibraryModelFailure: String, Error, Hashable, LocalizedError {
    case meetings
    case voiceMixes
    case openItems
    case trash
    case search
    case rename
    case setActionItem
    case delete
    case restore
    case importFile

    var errorDescription: String? { "library-model-\(rawValue)" }
}

private enum LibraryModelCall: Equatable {
    case meetings
    case voiceMixes([MeetingID])
    case openItems(Int)
    case trash
    case agenda
    case search(String)
    case rename(String)
    case setActionItem(UUID, Bool)
    case delete(MeetingID)
    case restore(MeetingID)
    case purge(MeetingID)
    case importFile(URL)
    case requestCalendarAccess
    case brief(String)
}

@MainActor
private final class LibraryModelClientFake: LibraryModelClient {
    var meetings: [Meeting]
    var voiceMixes: [MeetingID: [MeetingStore.VoiceMixSlice]]
    var openItems: [MeetingStore.OpenActionItem]
    var trash: [MeetingStore.DeletedMeeting]
    var hits: [SearchHit]
    var agenda: LibraryModel.Agenda?
    var brief: MeetingBrief?
    var failures: Set<LibraryModelFailure> = []
    var calls: [LibraryModelCall] = []
    var queries: [String] = []
    let importedID: MeetingID

    init(fixture: LibraryModelFixture) {
        meetings = [fixture.meeting]
        voiceMixes = [fixture.meeting.id: fixture.voiceMix]
        openItems = [fixture.openItem]
        trash = [fixture.deleted]
        hits = [fixture.hit]
        importedID = fixture.importedID
    }

    func loadLibraryMeetings() throws -> [Meeting] {
        calls.append(.meetings)
        try fail(.meetings)
        return meetings
    }

    func loadLibraryVoiceMixes(
        for meetingIDs: [MeetingID]
    ) throws -> [MeetingID: [MeetingStore.VoiceMixSlice]] {
        calls.append(.voiceMixes(meetingIDs))
        try fail(.voiceMixes)
        return voiceMixes
    }

    func loadLibraryOpenItems(limit: Int) throws -> [MeetingStore.OpenActionItem] {
        calls.append(.openItems(limit))
        try fail(.openItems)
        return openItems
    }

    func loadLibraryTrash() throws -> [MeetingStore.DeletedMeeting] {
        calls.append(.trash)
        try fail(.trash)
        return trash
    }

    func searchLibrary(_ query: String) throws -> [SearchHit] {
        calls.append(.search(query))
        queries.append(query)
        try fail(.search)
        return hits
    }

    func renameLibraryMeeting(_ meeting: Meeting) throws {
        calls.append(.rename(meeting.title))
        try fail(.rename)
    }

    func setLibraryActionItem(_ id: UUID, done: Bool) throws {
        calls.append(.setActionItem(id, done))
        try fail(.setActionItem)
    }

    func deleteLibraryMeeting(_ id: MeetingID) throws {
        calls.append(.delete(id))
        try fail(.delete)
    }

    func restoreLibraryMeeting(_ id: MeetingID) throws {
        calls.append(.restore(id))
        try fail(.restore)
    }

    func purgeLibraryMeeting(_ entry: MeetingStore.DeletedMeeting) {
        calls.append(.purge(entry.meeting.id))
    }

    func importLibraryFile(
        _ url: URL,
        progress: @escaping @MainActor (String) -> Void
    ) throws -> MeetingID {
        calls.append(.importFile(url))
        progress("Transcribing…")
        try fail(.importFile)
        return importedID
    }

    func libraryAgenda() -> LibraryModel.Agenda? {
        calls.append(.agenda)
        return agenda
    }

    func requestLibraryCalendarAccess() {
        calls.append(.requestCalendarAccess)
    }

    func buildLibraryBrief(for event: UpcomingEvent) -> MeetingBrief? {
        calls.append(.brief(event.id))
        return brief
    }

    private func fail(_ failure: LibraryModelFailure) throws {
        if failures.contains(failure) { throw failure }
    }
}
