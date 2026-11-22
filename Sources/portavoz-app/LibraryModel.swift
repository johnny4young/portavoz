import ApplicationKit
import Foundation
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
    func purgeLibraryMeeting(_ entry: LibraryTrashItem) async throws
    func enqueueLibraryAudio(_ urls: [URL]) async throws
    func importLibraryFile(
        _ url: URL,
        progress: @escaping @MainActor (String) -> Void
    ) async throws -> MeetingID

    func libraryAgenda() -> LibraryModel.Agenda?
    func requestLibraryCalendarAccess() async
    func buildLibraryBrief(for event: UpcomingEvent) async -> MeetingBrief?
    func libraryBriefLines(for event: UpcomingEvent) async throws -> MeetingBriefLines?
    func libraryTodayVoices(at now: Date, events: [UpcomingEvent]) async throws -> TodayVoices
    func libraryTodayWork(_ request: LoadTodayWork.Request) async throws -> TodayWork
    /// Skill offers waiting for review; zero when they cannot be read.
    func pendingLibraryAutomations() async -> Int
    /// Suggestions waiting in Radar's review queue; nil when they cannot be read.
    func librarySuggestionsToReview() async -> Int?
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

    /// What each person said last time, for one event occurrence.
    struct BriefPreview: Equatable {
        let occurrence: MeetingBriefLines.Occurrence
        /// nil when the event has no previous occurrence.
        let lines: MeetingBriefLines?

        /// False for both empty states the card words.
        var hasLines: Bool { lines?.people.isEmpty == false }

        func isFor(_ event: UpcomingEvent) -> Bool {
            occurrence == MeetingBriefLines.Occurrence(event: event)
        }
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
        fileprivate(set) var voiceStrips: [MeetingID: VoiceStripColumns] = [:]
        fileprivate(set) var voiceSources: [MeetingID: VoiceStripSource] = [:]
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
        fileprivate(set) var pendingAutomations = 0
        fileprivate(set) var briefPreview: BriefPreview?
        /// Who spoke today and the day axis; nil until the first read.
        fileprivate(set) var todayVoices: TodayVoices?
        /// Bumped when today's meetings, their finished strips or today's
        /// agenda change; a recording's live strip is left out, so captions
        /// never trigger a read.
        fileprivate(set) var todayVoicesRevision = 0
        /// Bumped when a meeting or an open to-do changes, not by transcript
        /// writes alone, so a live recording does not reload the brief per caption.
        fileprivate(set) var libraryRevision = 0
        /// Saved listening positions of the pick-up candidates; nil until read.
        fileprivate(set) var playbackPositions: [MeetingID: MeetingPlaybackPosition]?
        /// Who said each shown to-do, by item.
        fileprivate(set) var openItemSources: [UUID: OpenItemSource] = [:]
        /// Generated suggestions waiting in Radar's review queue.
        fileprivate(set) var suggestionsToReview = 0

        /// The open to-dos Today lists.
        var shownOpenItems: ArraySlice<LibraryOpenItem> { openItems.prefix(TodayPickUp.maximumOpenItems) }

        /// Pick up where you left off; rows carry no progress until positions load.
        var pickUpRows: [TodayPickUp.Row] {
            TodayPickUp.rows(meetings: meetings, positions: playbackPositions)
        }

        /// The first event of today, else the first of tomorrow.
        var heroEvent: (event: UpcomingEvent, isToday: Bool)? {
            if let first = upcomingToday.first { return (first, true) }
            return upcomingTomorrow.first.map { ($0, false) }
        }

        /// The brief of the hero's own occurrence, once it has loaded.
        var heroBriefPreview: BriefPreview? {
            guard let event = heroEvent?.event, let briefPreview, briefPreview.isFor(event) else { return nil }
            return briefPreview
        }

        /// One cast for all of Today: the day's voices, then the hero's
        /// invitees, the brief source, to-do sources and pick-up rows.
        func pageCast(pickUp: [TodayPickUp.Row]) -> TodayPageCast {
            let ids = [heroBriefPreview?.lines?.sourceMeetingID].compactMap(\.self)
                + shownOpenItems.map(\.meetingID)
                + pickUp.map(\.meeting.id)
            return TodayPageCast(
                day: todayVoices, hero: heroEvent?.event,
                meetings: ids.compactMap { id in voiceSources[id].map { (id, $0) } })
        }
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
        case importFiles([URL])
        case dismissImportError
        case dismissActionError
        case refreshAgenda
        case requestCalendarAccess
        case openBrief(UpcomingEvent)
        case dismissBrief
        case loadBriefPreview(UpcomingEvent)
        case loadTodayVoices
        case refreshAutomations
        case refreshSuggestions
        case loadTodayWork
    }

    enum Effect: Equatable {
        case openMeeting(MeetingID)
        case deletedMeeting(MeetingID)
        case showImportQueue
    }

    private(set) var state = State()

    private let client: any LibraryModelClient
    private let searchDelay: Duration
    private var observedSections: Set<LibrarySection> = []
    private var failedSections: Set<LibrarySection> = []
    private var inlineFailures: [LibrarySection: Int] = [:]
    private var briefPreviewRequest = 0
    private var todayVoicesRequest = 0
    private var todayWorkTask: Task<Void, Never>?
    private var suggestionsRequest = 0
    private var meetingSignatures: [MeetingSignature] = []
    private var openItemSignatures: [OpenItemSignature] = []
    private var todaySignature: TodaySignature?

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
            await recordAction { try await client.purgeLibraryMeeting(entry) }
        case .dismissActionError:
            state.lastActionError = nil
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
        case .loadBriefPreview(let event):
            await loadBriefPreview(event)
        case .loadTodayVoices:
            await loadTodayVoices()
        case .refreshAutomations:
            await refreshAutomations()
        case .refreshSuggestions:
            await refreshSuggestions()
        case .loadTodayWork:
            await loadTodayWork()
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
            return await importFiles([url])
        case .importFiles(let urls):
            return await importFiles(urls)
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
            state.voiceStrips = Dictionary(uniqueKeysWithValues: rows.map {
                ($0.meeting.id, $0.voiceStrip)
            })
            state.voiceSources = Dictionary(uniqueKeysWithValues: rows.compactMap { row in
                row.voiceSource.map { (row.meeting.id, $0) }
            })
            markObserved(.meetings, inlineFailureCount: failures)
            bumpRevision(meetings: rows.map { MeetingSignature($0.meeting) })
            refreshAgenda()
        case .openItems(let items):
            state.openItems = items
            markObserved(.openItems)
            bumpRevision(openItems: items.map { OpenItemSignature(id: $0.id, text: $0.item.text) })
        case .trash(let items):
            state.trashed = items
            markObserved(.trash)
        case .failed(let section):
            failedSections.insert(section)
            inlineFailures[section] = 0
        }
        refreshLoadPhase()
    }

    func bumpRevision(meetings: [MeetingSignature]? = nil, openItems: [OpenItemSignature]? = nil) {
        var changed = false
        if let meetings, meetings != meetingSignatures {
            meetingSignatures = meetings
            changed = true
        }
        if let openItems, openItems != openItemSignatures {
            openItemSignatures = openItems
            changed = true
        }
        if changed { state.libraryRevision &+= 1 }
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

    func importFiles(_ urls: [URL]) async -> Effect? {
        guard state.importStatus == nil, !urls.isEmpty else { return nil }
        state.importError = nil
        state.importStatus = L10n.text("Preparing…")
        defer { state.importStatus = nil }
        do {
            if urls.contains(where: { $0.pathExtension.lowercased() == "portavoz" }) {
                guard urls.count == 1, let url = urls.first else { throw AudioImportQueueError.mixedBundles }
                let id = try await client.importLibraryFile(url) { [weak self] status in
                    self?.state.importStatus = status
                }
                return .openMeeting(id)
            }
            try await client.enqueueLibraryAudio(urls)
            return .showImportQueue
        } catch {
            state.importError = error.localizedDescription
            return nil
        }
    }

    func refreshAgenda() {
        if let agenda = client.libraryAgenda() {
            state.offerCalendar = agenda.offerCalendar
            state.upcomingToday = agenda.today
            state.upcomingTomorrow = agenda.tomorrow
        }
        refreshTodaySignature()
    }

    func refreshTodaySignature() {
        let startOfDay = Calendar.current.startOfDay(for: Date())
        let today = state.meetings.filter { $0.startedAt >= startOfDay || $0.lifecycleState == .recording }
        let signature = TodaySignature(
            meetings: today.map(MeetingSignature.init),
            strips: today.filter { $0.lifecycleState != .recording }.map { state.voiceStrips[$0.id] ?? .empty },
            events: state.upcomingToday)
        guard signature != todaySignature else { return }
        todaySignature = signature
        state.todayVoicesRevision &+= 1
    }

    func refreshAutomations() async {
        let count = await client.pendingLibraryAutomations()
        guard !Task.isCancelled else { return }
        state.pendingAutomations = count
        await refreshSuggestions()
    }

    /// An unreadable count keeps the badge as it is; the newest request wins.
    func refreshSuggestions() async {
        suggestionsRequest &+= 1
        let request = suggestionsRequest
        let review = await client.librarySuggestionsToReview()
        guard !Task.isCancelled, request == suggestionsRequest, let review, review != state.suggestionsToReview
        else { return }
        state.suggestionsToReview = review
    }

    func openBrief(_ event: UpcomingEvent) async {
        guard state.briefLoading == nil else { return }
        state.briefLoading = event
        let brief = await client.buildLibraryBrief(for: event)
        guard state.briefLoading == event else { return }
        state.briefLoading = nil
        state.brief = brief
        // Preparing the brief can record the source Today's card reads.
        if state.heroEvent?.event == event { await loadBriefPreview(event) }
    }

    /// A failed load keeps what is shown; the newest request wins.
    func loadBriefPreview(_ event: UpcomingEvent) async {
        briefPreviewRequest &+= 1
        let request = briefPreviewRequest
        let lines: MeetingBriefLines?
        do {
            lines = try await client.libraryBriefLines(for: event)
        } catch {
            return
        }
        guard !Task.isCancelled, request == briefPreviewRequest else { return }
        let preview = BriefPreview(occurrence: MeetingBriefLines.Occurrence(event: event), lines: lines)
        // An unchanged write would still re-render everything reading the state.
        if state.briefPreview != preview { state.briefPreview = preview }
    }

    /// Same rules as the brief preview: a failed read keeps what is shown.
    func loadTodayVoices() async {
        todayVoicesRequest &+= 1
        let request = todayVoicesRequest
        let voices: TodayVoices
        do {
            voices = try await client.libraryTodayVoices(at: Date(), events: state.upcomingToday)
        } catch {
            return
        }
        guard !Task.isCancelled, request == todayVoicesRequest else { return }
        if state.todayVoices != voices { state.todayVoices = voices }
    }

    /// Waits for the meetings and open to-dos to arrive; a newer request
    /// cancels the older read, and a failed part keeps what is shown.
    func loadTodayWork() async {
        guard observedSections.union(failedSections).isSuperset(of: [.meetings, .openItems]) else { return }
        todayWorkTask?.cancel()
        let request = LoadTodayWork.Request(
            meetingIDs: TodayPickUp.candidates(state.meetings).map(\.id),
            itemIDs: state.shownOpenItems.map(\.id))
        let task = Task {
            guard let work = try? await client.libraryTodayWork(request), !Task.isCancelled else { return }
            if let positions = work.positions, positions != state.playbackPositions {
                state.playbackPositions = positions
            }
            if let sources = work.sources, sources != state.openItemSources { state.openItemSources = sources }
        }
        todayWorkTask = task
        await task.value
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

/// What a brief line can depend on in a meeting row.
private struct MeetingSignature: Equatable {
    let id: MeetingID
    let title: String
    let startedAt: Date
    let endedAt: Date?
    let transcriptRevision: Int

    init(_ meeting: Meeting) {
        id = meeting.id
        title = meeting.title
        startedAt = meeting.startedAt
        endedAt = meeting.endedAt
        transcriptRevision = meeting.transcriptRevision
    }
}

/// What today's talk totals and day axis can depend on.
private struct TodaySignature: Equatable {
    let meetings: [MeetingSignature]
    let strips: [VoiceStripColumns]
    let events: [UpcomingEvent]
}

private struct OpenItemSignature: Equatable {
    let id: UUID
    let text: String
}
