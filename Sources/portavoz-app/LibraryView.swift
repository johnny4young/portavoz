import AppKit
import IntegrationsKit
import PortavozCore
import StorageKit
import SwiftUI
import UniformTypeIdentifiers

/// Sidebar: record button, full-text search, and the meeting library.
struct LibraryView: View {
    @Environment(AppServices.self) private var services
    @Binding var route: Route?

    /// To-dos fold away when the user wants a lean sidebar; the choice
    /// survives relaunches.
    @AppStorage("todosSectionExpanded") private var todosExpanded = true
    @State private var meetings: [Meeting] = []
    @State private var query = ""
    @State private var hits: [SearchHit] = []
    /// Open action items across ALL meetings — the cross-meeting to-do list.
    @State private var openItems: [MeetingStore.OpenActionItem] = []
    /// Soft-deleted meetings for the "Recently deleted" section.
    @State private var trashed: [MeetingStore.DeletedMeeting] = []
    /// Prep agenda (M13b): the rest of today's meetings + tomorrow's,
    /// collapsible in the sidebar; clicking one builds its brief ON DEMAND
    /// (no FM spent up front). Loads only when calendar access was already
    /// granted — never prompts here. A 5-minute timer keeps it honest.
    @State private var upcomingToday: [UpcomingEvent] = []
    @State private var upcomingTomorrow: [UpcomingEvent] = []
    /// Shown once when calendar access was never asked: the agenda's own
    /// affordance to request it (fixes the discoverability gap — the brief
    /// itself never prompts).
    @State private var offerCalendar = false
    @State private var brief: MeetingBrief?
    @State private var briefLoading: UpcomingEvent?
    @State private var showBrief = false
    private let briefTimer = Timer.publish(every: 300, on: .main, in: .common).autoconnect()
    @State private var renamingMeeting: Meeting?
    @State private var newTitle = ""
    @State private var importStatus: String?
    @State private var importError: String?

    /// Audio the importer accepts (drag-drop or the Import button).
    private static let importTypes: [UTType] = [.audio, .mpeg4Audio, .wav, .mp3, .meetingBundle]

    var body: some View {
        VStack(spacing: 0) {
            Button {
                route = .recording(nil)
            } label: {
                Label("New recording", systemImage: "record.circle")
                    .frame(maxWidth: .infinity)
            }
            .accessibilityIdentifier("library-new-recording-button")
            .controlSize(.large)
            .keyboardShortcut("n")
            .padding(.horizontal, 12)
            .padding(.top, 12)

            if let importStatus {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(importStatus).font(.caption).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
            } else {
                Button {
                    chooseAudioToImport()
                } label: {
                    Label("Import audio…", systemImage: "square.and.arrow.down")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.small)
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .help("Transcribe an audio file (.m4a, .wav, .mp3) as a new meeting")
                .accessibilityIdentifier("library-import-audio-button")
            }

            Button {
                route = .ask
            } label: {
                Label("Ask your meetings", systemImage: "bubble.left.and.text.bubble.right")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.small)
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .help("Natural-language questions over every meeting, answered on your Mac")
            .accessibilityIdentifier("library-ask-button")

            Button {
                route = .insights
            } label: {
                Label("Insights", systemImage: "chart.bar.xaxis")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.small)
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .help("Totals, cadence, people and commitments — computed on your Mac")
            .accessibilityIdentifier("library-insights-button")

            if offerCalendar {
                Button {
                    Task {
                        _ = await CalendarAttendeeSource.requestAccess()
                        await refreshBrief()
                    }
                } label: {
                    Label("Connect your calendar", systemImage: "calendar.badge.plus")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.small)
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .help("Shows today's and tomorrow's meetings here, with a prep brief for each. Read-only, on-device.")
            }

            TextField("Search all meetings…", text: $query)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 12)
                .task(id: query) { await search(query) }

            List(selection: $route) {
                if !query.isEmpty {
                    Section("Results") {
                        if hits.isEmpty {
                            Text("No matches").foregroundStyle(.secondary)
                        }
                        ForEach(hits, id: \.segmentID) { hit in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(hit.snippet).lineLimit(2)
                                Text("\(hit.meetingTitle) · \(timestamp(hit.startTime))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .tag(Route.meeting(hit.meetingID))
                        }
                    }
                } else {
                    if !upcomingToday.isEmpty {
                        Section("Today") {
                            ForEach(upcomingToday) { event in
                                upcomingRow(event)
                            }
                        }
                    }
                    if !upcomingTomorrow.isEmpty {
                        Section("Tomorrow") {
                            ForEach(upcomingTomorrow) { event in
                                upcomingRow(event)
                            }
                        }
                    }
                    if !openItems.isEmpty {
                        Section("To-dos", isExpanded: $todosExpanded) {
                            ForEach(openItems, id: \.item.id) { open in
                                todoRow(open)
                            }
                        }
                    }
                    Section("Meetings") {
                        if meetings.isEmpty {
                            Text("No meetings yet").foregroundStyle(.secondary)
                        }
                        ForEach(meetings) { meeting in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(meeting.title).lineLimit(1)
                                Text(meeting.startedAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .tag(Route.meeting(meeting.id))
                            .contextMenu {
                                Button("Rename…") {
                                    renamingMeeting = meeting
                                    newTitle = meeting.title
                                }
                                Button("Delete", role: .destructive) {
                                    Task {
                                        try? await services.store.delete(meeting.id)
                                        if route == .meeting(meeting.id) { route = nil }
                                        services.libraryVersion += 1
                                    }
                                }
                            }
                        }
                    }
                    TrashSection(items: trashed)
                }
            }
            .listStyle(.sidebar)
        }
        .navigationTitle("Portavoz")
        .alert(
            "Rename meeting",
            isPresented: Binding(
                get: { renamingMeeting != nil },
                set: { if !$0 { renamingMeeting = nil } }
            )
        ) {
            TextField("Title", text: $newTitle)
            Button("Save") {
                // Capture now — dismissing the alert nils renamingMeeting
                // before the task runs.
                if var meeting = renamingMeeting {
                    let title = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                    Task {
                        guard !title.isEmpty else { return }
                        meeting.title = title
                        try? await services.store.save(meeting)
                        services.libraryVersion += 1
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert(
            "Import failed",
            isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(importError ?? "")
        }
        .sheet(isPresented: $showBrief) {
            if let brief {
                MeetingBriefView(brief: brief, route: $route)
            }
        }
        // Drop an audio file anywhere on the sidebar to import it.
        .dropDestination(for: URL.self) { urls, _ in
            guard importStatus == nil, let url = urls.first(where: isAudio) else { return false }
            importAudio(from: url)
            return true
        }
        .task(id: services.libraryVersion) { await reload() }
        .onReceive(briefTimer) { _ in Task { await refreshBrief() } }
    }

    private func reload() async {
        meetings = (try? await services.store.meetings()) ?? []
        openItems = (try? await services.store.openActionItems(limit: 20)) ?? []
        trashed = (try? await services.store.deletedMeetings()) ?? []
        await refreshBrief()
    }

    /// EventKit is local and cheap: re-split the agenda into today/tomorrow.
    /// Briefs are built on click, so refreshing costs no model time.
    private func refreshBrief() async {
        guard !ProcessInfo.processInfo.arguments.contains("-use-temp-store") else { return }
        offerCalendar = CalendarAttendeeSource.accessUndetermined
        let events = CalendarAttendeeSource().upcomingEvents()
        let startOfTomorrow = Calendar.current.startOfDay(
            for: Date().addingTimeInterval(24 * 3600))
        upcomingToday = events.filter { $0.startDate < startOfTomorrow }
        upcomingTomorrow = events.filter { $0.startDate >= startOfTomorrow }
    }

    /// One agenda row: time + title; click builds that event's brief.
    private func upcomingRow(_ event: UpcomingEvent) -> some View {
        Button {
            openBrief(for: event)
        } label: {
            HStack(spacing: 6) {
                if briefLoading == event {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "calendar.badge.clock")
                        .foregroundStyle(.secondary)
                }
                Text(event.startDate.formatted(date: .omitted, time: .shortened))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text(event.title).lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .help("Brief for this meeting: who's coming, related meetings, open to-dos")
    }

    private func openBrief(for event: UpcomingEvent) {
        guard briefLoading == nil else { return }
        briefLoading = event
        Task {
            defer { briefLoading = nil }
            brief = await MeetingBrief.build(for: event, store: services.store)
            showBrief = brief != nil
        }
    }

    /// One open action item: check it off right here, or click through to
    /// its meeting. Checking bumps `libraryVersion`, which reloads the list
    /// (and the detail view, which shares the same items). NOT a selection
    /// row: several to-dos share one meeting, and tagging them with it made
    /// the List paint every sibling as selected at once (field bug, Jul 11)
    /// — so navigation is an explicit tap and selection stays disabled.
    private func todoRow(_ open: MeetingStore.OpenActionItem) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Toggle(isOn: todoBinding(open)) { EmptyView() }
                .toggleStyle(.checkbox)
                .labelsHidden()
            VStack(alignment: .leading, spacing: 2) {
                Text(open.item.text).lineLimit(2)
                Text(open.meetingTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
            .onTapGesture { route = .meeting(open.meetingID) }
        }
        .selectionDisabled()
    }

    private func todoBinding(_ open: MeetingStore.OpenActionItem) -> Binding<Bool> {
        Binding(
            get: { open.item.isDone },
            set: { done in
                Task {
                    try? await services.store.setActionItem(open.item.id, done: done)
                    services.libraryVersion += 1
                }
            }
        )
    }

    private func isAudio(_ url: URL) -> Bool {
        ["m4a", "wav", "mp3", "aac", "aiff", "aif", "caf", "m4b"]
            .contains(url.pathExtension.lowercased())
    }

    private func chooseAudioToImport() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = Self.importTypes
        panel.prompt = L10n.text("Import")
        panel.message = L10n.text("Choose an audio file to transcribe, or a .portavoz meeting file")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importAudio(from: url)
    }

    private func importAudio(from url: URL) {
        guard importStatus == nil else { return }
        importStatus = L10n.text("Preparing…")
        Task {
            do {
                let id: MeetingID
                if url.pathExtension.lowercased() == MeetingBundle.fileExtension {
                    id = try await services.importBundle(from: url)
                } else {
                    id = try await services.importMeeting(from: url) { status in
                        importStatus = status
                    }
                }
                importStatus = nil
                route = .meeting(id)
            } catch {
                importStatus = nil
                importError = error.localizedDescription
            }
        }
    }

    private func search(_ text: String) async {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            hits = []
            return
        }
        do {
            try await Task.sleep(for: .milliseconds(250))
            try Task.checkCancellation()
            let results = try await services.store.search(text)
            try Task.checkCancellation()
            hits = results
        } catch is CancellationError {
            // `.task(id:)` cancels stale searches as the user keeps typing.
        } catch {
            hits = []
        }
    }

    private func timestamp(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
