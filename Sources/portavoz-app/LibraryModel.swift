import Foundation
import IntegrationsKit
import Observation
import PortavozCore
import StorageKit

/// Narrow composition contract for the Library feature. The first Strangler
/// slice deliberately keeps the released Store queries and broad invalidation;
/// scoped GRDB observations replace this client in the following slice.
@MainActor
protocol LibraryModelClient: AnyObject {
    func loadLibraryMeetings() async throws -> [Meeting]
    func loadLibraryVoiceMixes(
        for meetingIDs: [MeetingID]
    ) async throws -> [MeetingID: [MeetingStore.VoiceMixSlice]]
    func loadLibraryOpenItems(limit: Int) async throws -> [MeetingStore.OpenActionItem]
    func loadLibraryTrash() async throws -> [MeetingStore.DeletedMeeting]
    func searchLibrary(_ query: String) async throws -> [SearchHit]

    func renameLibraryMeeting(_ meeting: Meeting) async throws
    func setLibraryActionItem(_ id: UUID, done: Bool) async throws
    func deleteLibraryMeeting(_ id: MeetingID) async throws
    func restoreLibraryMeeting(_ id: MeetingID) async throws
    func purgeLibraryMeeting(_ entry: MeetingStore.DeletedMeeting) async
    func importLibraryFile(
        _ url: URL,
        progress: @escaping @MainActor (String) -> Void
    ) async throws -> MeetingID

    func libraryAgenda() -> LibraryModel.Agenda?
    func requestLibraryCalendarAccess() async
    func buildLibraryBrief(for event: UpcomingEvent) async -> MeetingBrief?
}

/// Per-window presentation owner for the Library. Views render one value-state
/// snapshot and send enum actions; they never coordinate Store/use-case calls.
@MainActor
@Observable
final class LibraryModel {
    enum LoadPhase: Equatable {
        case idle
        case loading
        case loaded
        case empty
        case degraded(failures: Int)
        case failed
    }

    enum SearchPhase: Equatable {
        case idle
        case searching
        case loaded
        case empty
        case degraded
    }

    struct RenameState {
        let meeting: Meeting
        var title: String
    }

    struct Agenda {
        let offerCalendar: Bool
        let today: [UpcomingEvent]
        let tomorrow: [UpcomingEvent]
    }

    /// A value snapshot with a private model-owned write path. SwiftUI can
    /// observe and render it, but cannot mutate feature state directly.
    struct State {
        fileprivate(set) var loadPhase: LoadPhase = .idle
        fileprivate(set) var reloadVersion: Int?
        fileprivate(set) var meetings: [Meeting] = []
        fileprivate(set) var voiceMixes: [MeetingID: [MeetingStore.VoiceMixSlice]] = [:]
        fileprivate(set) var openItems: [MeetingStore.OpenActionItem] = []
        fileprivate(set) var trashed: [MeetingStore.DeletedMeeting] = []

        fileprivate(set) var query = ""
        fileprivate(set) var hits: [SearchHit] = []
        fileprivate(set) var searchPhase: SearchPhase = .idle

        fileprivate(set) var rename: RenameState?
        fileprivate(set) var importStatus: String?
        fileprivate(set) var importError: String?
        fileprivate(set) var lastActionError: String?

        fileprivate(set) var upcomingToday: [UpcomingEvent] = []
        fileprivate(set) var upcomingTomorrow: [UpcomingEvent] = []
        fileprivate(set) var offerCalendar = false
        fileprivate(set) var brief: MeetingBrief?
        fileprivate(set) var briefLoading: UpcomingEvent?
    }

    enum Action {
        case reload(version: Int)
        case queryChanged(String)
        case search
        case beginRename(Meeting)
        case renameTitleChanged(String)
        case cancelRename
        case confirmRename(Meeting, title: String)
        case setActionItem(UUID, done: Bool)
        case delete(MeetingID)
        case restore(MeetingID)
        case purge(MeetingStore.DeletedMeeting)
        case importFile(URL)
        case dismissImportError
        case refreshAgenda
        case requestCalendarAccess
        case openBrief(UpcomingEvent)
        case dismissBrief
    }

    enum Effect: Equatable {
        case openMeeting(MeetingID)
        case deletedMeeting(MeetingID)
    }

    private(set) var state = State()

    private let client: any LibraryModelClient
    private let searchDelay: Duration
    private var newestReloadVersion = Int.min

    init(
        client: any LibraryModelClient,
        searchDelay: Duration = .milliseconds(250)
    ) {
        self.client = client
        self.searchDelay = searchDelay
    }

    @discardableResult
    func send(_ action: Action) async -> Effect? {
        await handleLoadingAction(action)
        await handleMutationAction(action)
        await handleAgendaAction(action)
        return await handleNavigationAction(action)
    }
}

private extension LibraryModel {
    func handleLoadingAction(_ action: Action) async {
        switch action {
        case .reload(let version):
            await reload(version: version)
        case .queryChanged(let query):
            state.query = query
            if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                state.hits = []
                state.searchPhase = .idle
            }
        case .search:
            await search()
        default:
            break
        }
    }

    func handleMutationAction(_ action: Action) async {
        switch action {
        case .beginRename(let meeting):
            state.rename = RenameState(meeting: meeting, title: meeting.title)
        case .renameTitleChanged(let title):
            state.rename?.title = title
        case .cancelRename:
            state.rename = nil
        case .confirmRename(let meeting, let title):
            await confirmRename(meeting, title: title)
        case .setActionItem(let id, let done):
            await setActionItem(id, done: done)
        case .restore(let id):
            await restore(id)
        case .purge(let entry):
            state.lastActionError = nil
            await client.purgeLibraryMeeting(entry)
        case .dismissImportError:
            state.importError = nil
        default:
            break
        }
    }

    func handleAgendaAction(_ action: Action) async {
        switch action {
        case .refreshAgenda:
            refreshAgenda()
        case .requestCalendarAccess:
            await client.requestLibraryCalendarAccess()
            refreshAgenda()
        case .openBrief(let event):
            await openBrief(event)
        case .dismissBrief:
            state.brief = nil
        default:
            break
        }
    }

    func handleNavigationAction(_ action: Action) async -> Effect? {
        switch action {
        case .delete(let id):
            await delete(id)
            return .deletedMeeting(id)
        case .importFile(let url):
            return await importFile(url)
        default:
            return nil
        }
    }
}

private extension LibraryModel {
    func reload(version: Int) async {
        guard version >= newestReloadVersion else { return }
        newestReloadVersion = version
        state.loadPhase = .loading

        var meetings: [Meeting] = []
        var voiceMixes: [MeetingID: [MeetingStore.VoiceMixSlice]] = [:]
        var openItems: [MeetingStore.OpenActionItem] = []
        var trashed: [MeetingStore.DeletedMeeting] = []
        var failures = 0
        var successfulPrimaryReads = 0

        do {
            meetings = try await client.loadLibraryMeetings()
            successfulPrimaryReads += 1
            voiceMixes = try await client.loadLibraryVoiceMixes(
                for: meetings.map(\.id))
        } catch {
            guard !isCancellation(error) else { return }
            failures += 1
        }
        do {
            openItems = try await client.loadLibraryOpenItems(limit: 20)
            successfulPrimaryReads += 1
        } catch {
            guard !isCancellation(error) else { return }
            failures += 1
        }
        do {
            trashed = try await client.loadLibraryTrash()
            successfulPrimaryReads += 1
        } catch {
            guard !isCancellation(error) else { return }
            failures += 1
        }

        guard !Task.isCancelled, version == newestReloadVersion else { return }
        state.meetings = meetings
        state.voiceMixes = voiceMixes
        state.openItems = openItems
        state.trashed = trashed
        state.reloadVersion = version
        state.loadPhase = loadPhase(
            failures: failures,
            successfulPrimaryReads: successfulPrimaryReads,
            hasContent: !meetings.isEmpty || !openItems.isEmpty || !trashed.isEmpty)
        refreshAgenda()
    }

    func loadPhase(
        failures: Int,
        successfulPrimaryReads: Int,
        hasContent: Bool
    ) -> LoadPhase {
        if successfulPrimaryReads == 0 { return .failed }
        if failures > 0 { return .degraded(failures: failures) }
        return hasContent ? .loaded : .empty
    }

    func search() async {
        let sourceQuery = state.query
        let query = sourceQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            state.hits = []
            state.searchPhase = .idle
            return
        }

        do {
            try await Task.sleep(for: searchDelay)
            try Task.checkCancellation()
            guard state.query == sourceQuery else { return }
            state.searchPhase = .searching
            let hits = try await client.searchLibrary(query)
            try Task.checkCancellation()
            guard state.query == sourceQuery else { return }
            state.hits = hits
            state.searchPhase = hits.isEmpty ? .empty : .loaded
        } catch {
            guard !isCancellation(error), state.query == sourceQuery else { return }
            state.hits = []
            state.searchPhase = .degraded
        }
    }

    func confirmRename(_ original: Meeting, title: String) async {
        state.rename = nil
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        var meeting = original
        meeting.title = title
        await recordAction { try await client.renameLibraryMeeting(meeting) }
    }

    func setActionItem(_ id: UUID, done: Bool) async {
        await recordAction { try await client.setLibraryActionItem(id, done: done) }
    }

    func delete(_ id: MeetingID) async {
        await recordAction { try await client.deleteLibraryMeeting(id) }
    }

    func restore(_ id: MeetingID) async {
        await recordAction { try await client.restoreLibraryMeeting(id) }
    }

    func importFile(_ url: URL) async -> Effect? {
        guard state.importStatus == nil else { return nil }
        state.importError = nil
        state.importStatus = L10n.text("Preparing…")
        do {
            let id = try await client.importLibraryFile(url) { [weak self] status in
                self?.state.importStatus = status
            }
            state.importStatus = nil
            return .openMeeting(id)
        } catch {
            state.importStatus = nil
            state.importError = error.localizedDescription
            return nil
        }
    }

    func refreshAgenda() {
        guard let agenda = client.libraryAgenda() else { return }
        state.offerCalendar = agenda.offerCalendar
        state.upcomingToday = agenda.today
        state.upcomingTomorrow = agenda.tomorrow
    }

    func openBrief(_ event: UpcomingEvent) async {
        guard state.briefLoading == nil else { return }
        state.briefLoading = event
        let brief = await client.buildLibraryBrief(for: event)
        guard state.briefLoading == event else { return }
        state.briefLoading = nil
        state.brief = brief
    }

    func recordAction(_ operation: () async throws -> Void) async {
        state.lastActionError = nil
        do {
            try await operation()
        } catch {
            state.lastActionError = error.localizedDescription
        }
    }

    func isCancellation(_ error: Error) -> Bool {
        Task.isCancelled || error is CancellationError
    }
}
