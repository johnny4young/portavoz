import ApplicationKit
import Foundation
import IntegrationsKit
import Observation
import PortavozCore

/// Narrow composition contract for the Library feature. Persistence-specific
/// projections and observation mechanics stay behind the app adapter.
@MainActor
protocol LibraryModelClient: AnyObject {
    func observeLibrary() -> AsyncStream<LibraryUpdate>
    func observeLibrarySearch(
        _ query: String
    ) -> AsyncThrowingStream<[LibrarySearchHit], Error>

    func renameLibraryMeeting(_ meeting: Meeting) async throws
    func setLibraryActionItem(_ id: UUID, done: Bool) async throws
    func deleteLibraryMeeting(_ id: MeetingID) async throws
    func restoreLibraryMeeting(_ id: MeetingID) async throws
    func purgeLibraryMeeting(_ entry: LibraryTrashItem) async
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
        fileprivate(set) var meetings: [Meeting] = []
        fileprivate(set) var voiceMixes: [MeetingID: [LibraryVoiceMixSlice]] = [:]
        fileprivate(set) var openItems: [LibraryOpenItem] = []
        fileprivate(set) var trashed: [LibraryTrashItem] = []

        fileprivate(set) var query = ""
        fileprivate(set) var hits: [LibrarySearchHit] = []
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
        case observeLibrary
        case queryChanged(String)
        case observeSearch
        case beginRename(Meeting)
        case renameTitleChanged(String)
        case cancelRename
        case confirmRename(Meeting, title: String)
        case setActionItem(UUID, done: Bool)
        case delete(MeetingID)
        case restore(MeetingID)
        case purge(LibraryTrashItem)
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
    private var observedSections: Set<LibrarySection> = []
    private var failedSections: Set<LibrarySection> = []
    private var inlineFailures: [LibrarySection: Int] = [:]

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
        case .observeLibrary:
            await observeLibrary()
        case .queryChanged(let query):
            state.query = query
            if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                state.hits = []
                state.searchPhase = .idle
            }
        case .observeSearch:
            await observeSearch()
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
    func observeLibrary() async {
        state.loadPhase = .loading
        observedSections = []
        failedSections = []
        inlineFailures = [:]
        for await update in client.observeLibrary() {
            guard !Task.isCancelled else { return }
            publish(update)
        }
    }

    func publish(_ update: LibraryUpdate) {
        switch update {
        case .meetings(let rows, let failures):
            state.meetings = rows.map(\.meeting)
            state.voiceMixes = Dictionary(uniqueKeysWithValues: rows.map {
                ($0.meeting.id, $0.voiceMix)
            })
            markObserved(.meetings, inlineFailureCount: failures)
            refreshAgenda()
        case .openItems(let items):
            state.openItems = items
            markObserved(.openItems)
        case .trash(let items):
            state.trashed = items
            markObserved(.trash)
        case .failed(let section):
            failedSections.insert(section)
            inlineFailures[section] = 0
        }
        refreshLoadPhase()
    }

    func markObserved(
        _ section: LibrarySection,
        inlineFailureCount: Int = 0
    ) {
        observedSections.insert(section)
        failedSections.remove(section)
        inlineFailures[section] = inlineFailureCount
    }

    func refreshLoadPhase() {
        let accountedSections = observedSections.union(failedSections)
        guard accountedSections.count == LibrarySection.allCases.count else {
            state.loadPhase = .loading
            return
        }
        guard failedSections.count < LibrarySection.allCases.count else {
            state.loadPhase = .failed
            return
        }
        let failures = failedSections.count + inlineFailures.values.reduce(0, +)
        if failures > 0 {
            state.loadPhase = .degraded(failures: failures)
            return
        }
        let hasContent = !state.meetings.isEmpty
            || !state.openItems.isEmpty
            || !state.trashed.isEmpty
        state.loadPhase = hasContent ? .loaded : .empty
    }

    func observeSearch() async {
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
            for try await hits in client.observeLibrarySearch(query) {
                try Task.checkCancellation()
                guard state.query == sourceQuery else { return }
                state.hits = hits
                state.searchPhase = hits.isEmpty ? .empty : .loaded
            }
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
