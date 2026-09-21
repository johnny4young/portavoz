import AppKit
import ApplicationKit
import Combine
import PortavozCore
import SwiftUI
import UniformTypeIdentifiers

/// Sidebar: record button, full-text search, and the meeting library.
struct LibraryView: View {
    let model: LibraryModel
    let imports: AudioImportQueueModel
    @State private var showsImportQueue = false
    @Binding var route: Route?
    let recordingActive: Bool
    let onReturnToRecording: () -> Void
    let onOpenSearchHit: (LibrarySearchHit) -> Void
    /// Opens Settings on Your data, where the activity log lives.
    let onOpenActivity: () -> Void

    /// To-dos fold away when the user wants a lean sidebar; the choice
    /// survives relaunches.
    @AppStorage("todosSectionExpanded") private var todosExpanded = true
    @State private var showsPrivacyNote = false
    @Environment(\.colorScheme) private var colorScheme
    private let briefTimer = Timer.publish(every: 300, on: .main, in: .common).autoconnect()

    /// Audio the importer accepts (drag-drop or the Import button).
    private static let importTypes: [UTType] = [.audio, .mpeg4Audio, .wav, .mp3, .meetingBundle]

    private var state: LibraryModel.State { model.state }

    /// The sidebar List owns meeting selection only. `route` also represents
    /// Ask, Insights, Radar, and Recording; binding the List directly to that broader
    /// state lets a transient list refresh write `nil` and dismiss those
    /// destinations. Ignore those native deselection writes while explicit
    /// navigation and deletion continue to own the full route.
    private var meetingSelection: Binding<Route?> {
        Binding(
            get: {
                guard let route, case .meeting = route else { return nil }
                return route
            },
            set: { selection in
                guard let selection, case .meeting = selection else { return }
                route = selection
            })
    }

    var body: some View {
        VStack(spacing: 0) {
            recordButton
                .padding(.horizontal, 12)
                .padding(.top, 12)

            LibraryNavigationControls(
                route: route,
                onNavigate: { route = $0 })
                .padding(.horizontal, 12)
                .padding(.top, 12)

            if let importStatus = state.importStatus {
                Text(importStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.top, 6)
                    .accessibilityIdentifier("library-import-status")
            }

            LibraryImportStatusView(
                imports: imports, actionError: state.lastActionError,
                onOpen: { showsImportQueue = true },
                onDismissError: { perform(.dismissActionError) })

            if state.offerCalendar {
                Button {
                    perform(.requestCalendarAccess)
                } label: {
                    Label("Connect your calendar", systemImage: "calendar.badge.plus")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.small)
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .help("Shows today's and tomorrow's meetings with a brief for each.")
            }

            searchField
                .padding(.horizontal, 12)
                .padding(.top, 8)

            List(selection: meetingSelection) {
                if !state.query.isEmpty {
                    Section("Results") {
                        if state.hits.isEmpty {
                            Text("No matches").foregroundStyle(.secondary)
                        }
                        ForEach(state.hits, id: \.segmentID) { hit in
                            Button {
                                onOpenSearchHit(hit)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(hit.snippet).lineLimit(2)
                                    Text("\(hit.meetingTitle) · \(ClockFormat.mmss(hit.startTime))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                            .selectionDisabled()
                            .accessibilityIdentifier(
                                "library-search-hit-\(hit.segmentID.uuidString)")
                        }
                    }
                } else {
                    if !state.upcomingToday.isEmpty {
                        Section("Today") {
                            ForEach(state.upcomingToday) { event in
                                upcomingRow(event)
                            }
                        }
                    }
                    if !state.upcomingTomorrow.isEmpty {
                        Section("Tomorrow") {
                            ForEach(state.upcomingTomorrow) { event in
                                upcomingRow(event)
                            }
                        }
                    }
                    if !state.openItems.isEmpty {
                        Section("To-dos", isExpanded: $todosExpanded) {
                            ForEach(state.openItems, id: \.item.id) { open in
                                todoRow(open)
                            }
                        }
                    }
                    if state.meetings.isEmpty {
                        Section("Meetings") {
                            Text("No meetings yet").foregroundStyle(.secondary)
                        }
                    }
                    // Grouped by recency (design system: HOY · ESTA SEMANA ·
                    // SEMANA PASADA · antes) so the library reads like a
                    // timeline, not one long undated pile.
                    ForEach(meetingGroups, id: \.key) { group in
                        Section(group.title) {
                            ForEach(group.meetings) { meeting in
                                meetingRow(meeting)
                            }
                        }
                    }
                    TrashSection(
                        items: state.trashed,
                        onRestore: { perform(.restore($0.meeting.id)) },
                        onPurge: { perform(.purge($0)) })
                }
            }
            .listStyle(.sidebar)
            .tint(PVDesign.accent)
            localFooter
        }
        .navigationTitle("Portavoz")
        .alert(
            "Rename meeting",
            isPresented: Binding(
                get: { state.rename != nil },
                set: { if !$0 { perform(.cancelRename) } }
            )
        ) {
            TextField("Title", text: Binding(
                get: { state.rename?.title ?? "" },
                set: { perform(.renameTitleChanged($0)) }))
            Button("Save") {
                // Capture before alert dismissal sends cancel.
                if let rename = state.rename {
                    perform(.confirmRename(rename.meeting, title: rename.title))
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert(
            "Import failed",
            isPresented: Binding(
                get: { state.importError != nil },
                set: { if !$0 { perform(.dismissImportError) } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(state.importError ?? "")
        }
        .sheet(isPresented: Binding(
            get: { state.brief != nil },
            set: { if !$0 { perform(.dismissBrief) } }
        )) {
            if let brief = state.brief {
                MeetingBriefView(brief: brief, route: $route)
            }
        }
        .sheet(isPresented: $showsImportQueue) {
            AudioImportQueueView(model: imports) { id in
                route = .meeting(id)
                showsImportQueue = false
            }
        }
        // Each accepted audio URL is admitted; never silently keep only the first.
        .dropDestination(for: URL.self) { urls, _ in
            let audio = urls.filter(isAudio)
            guard state.importStatus == nil, !audio.isEmpty else { return false }
            importAudio(from: audio)
            return true
        }
        .task {
            _ = await model.send(.observeLibrary)
        }
        .onReceive(briefTimer) { _ in perform(.refreshAgenda) }
    }

    /// One agenda row: time + title; click builds that event's brief.
    private func upcomingRow(_ event: UpcomingEvent) -> some View {
        Button {
            openBrief(for: event)
        } label: {
            HStack(spacing: 6) {
                if state.briefLoading == event {
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
        // Agenda actions live inside the selectable meeting List but are not
        // meeting routes. Prevent AppKit's row-selection gesture from racing
        // the async brief action and opening the adjacent meeting instead.
        .selectionDisabled()
        .help("See who's coming, related meetings and open to-dos")
        .accessibilityIdentifier("library-upcoming-\(event.id)")
    }

    private func openBrief(for event: UpcomingEvent) {
        perform(.openBrief(event))
    }

    /// One open action item: check it off right here, or click through to
    /// its meeting. Checking refreshes this model through the open-item
    /// observation and retains broad invalidation only for the detail view.
    /// NOT a selection
    /// row: several to-dos share one meeting, and tagging them with it made
    /// the List paint every sibling as selected at once (field bug, Jul 11)
    /// — so navigation is an explicit tap and selection stays disabled.
    private func todoRow(_ open: LibraryOpenItem) -> some View {
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

    private func todoBinding(_ open: LibraryOpenItem) -> Binding<Bool> {
        Binding(
            get: { open.item.isDone },
            set: { done in
                perform(.setActionItem(open.item.id, done: done))
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
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = Self.importTypes
        panel.prompt = L10n.text("Import")
        panel.message = L10n.text("Choose audio files to transcribe, or one .portavoz meeting file")
        AudioImportUITestFixture.configurePicker(panel)
        guard panel.runModal() == .OK else { return }
        importAudio(from: panel.urls)
    }

    private func importAudio(from urls: [URL]) {
        guard state.importStatus == nil else { return }
        perform(.importFiles(urls))
    }

    private func perform(_ action: LibraryModel.Action) {
        Task {
            let effect = await model.send(action)
            handle(effect)
        }
    }

    private func handle(_ effect: LibraryModel.Effect?) {
        switch effect {
        case .openMeeting(let id):
            route = .meeting(id)
        case .showImportQueue:
            showsImportQueue = true
        case .deletedMeeting(let id):
            if route == .meeting(id) { route = nil }
        case nil:
            break
        }
    }
}

extension LibraryView {
    /// Meetings bucketed by recency, newest bucket first, empty buckets
    /// dropped — the sidebar's timeline (design system: HOY · ESTA SEMANA ·
    /// SEMANA PASADA · antes).
    private var meetingGroups: [(key: String, title: LocalizedStringKey, meetings: [Meeting])] {
        let calendar = Calendar.current
        let now = Date()
        let startOfToday = calendar.startOfDay(for: now)
        let startOfWeek = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? startOfToday
        let startOfLastWeek =
            calendar.date(byAdding: .weekOfYear, value: -1, to: startOfWeek) ?? startOfWeek

        var today: [Meeting] = [], thisWeek: [Meeting] = []
        var lastWeek: [Meeting] = [], earlier: [Meeting] = []
        for meeting in state.meetings {
            if meeting.startedAt >= startOfToday {
                today.append(meeting)
            } else if meeting.startedAt >= startOfWeek {
                thisWeek.append(meeting)
            } else if meeting.startedAt >= startOfLastWeek {
                lastWeek.append(meeting)
            } else {
                earlier.append(meeting)
            }
        }
        return [
            ("today", LocalizedStringKey("Today"), today),
            ("thisweek", LocalizedStringKey("This week"), thisWeek),
            ("lastweek", LocalizedStringKey("Last week"), lastWeek),
            ("earlier", LocalizedStringKey("Earlier"), earlier)
        ].filter { !$0.2.isEmpty }
            .map { (key: $0.0, title: $0.1, meetings: $0.2) }
    }

    /// Native sidebar selection owns contrast, focus and inactive-window styling.
    /// The voice mix remains a separate, meaningful recording cue.
    private func meetingRow(_ meeting: Meeting) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(MeetingRowTitle.display(meeting.title)).lineLimit(1)
            Text(meeting.startedAt.formatted(date: .abbreviated, time: .shortened))
                .font(.caption)
                .foregroundStyle(.secondary)
            if let mix = state.voiceMixes[meeting.id] {
                VoiceMixBar(slices: mix, colorScheme: colorScheme)
            }
        }
        .tag(Route.meeting(meeting.id))
        .accessibilityIdentifier("library-meeting-\(meeting.id.rawValue.uuidString)")
        .contextMenu {
            Button("Rename…") {
                perform(.beginRename(meeting))
            }
            Button("Delete", role: .destructive) {
                perform(.delete(meeting.id))
            }
            .accessibilityIdentifier("library-meeting-delete-\(meeting.id.rawValue.uuidString)")
        }
    }

    /// The primary action, styled to the design system: an indigo→violet
    /// gradient pill whose leading glyph is a mini-waveform with your amber
    /// peak — the brand mark on the button you press most.
    /// The primary action plus a ▾ menu for the rare ones (Import), so the
    /// navigation list stays destinations only.
    private var recordButton: some View {
        HStack(spacing: 4) {
            recordAction
            Menu {
                Button {
                    chooseAudioToImport()
                } label: {
                    Label("Import audio…", systemImage: "square.and.arrow.down")
                }
                .disabled(state.importStatus != nil)
                .accessibilityIdentifier("library-import-audio-button")
            } label: {
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 24, height: 34)
                    .background(
                        PVDesign.brandViolet.opacity(0.9),
                        in: RoundedRectangle(cornerRadius: 10))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel(L10n.text("More recording options"))
            .help(L10n.text("Transcribe an audio file (.m4a, .wav, .mp3) as a new meeting"))
            .accessibilityIdentifier("library-record-menu")
        }
    }

    private var recordAction: some View {
        Button {
            if recordingActive {
                onReturnToRecording()
            } else {
                route = .recording(nil)
            }
        } label: {
            HStack(spacing: 8) {
                if recordingActive {
                    Circle()
                        .fill(.red)
                        .frame(width: 9, height: 9)
                    Text("Return to recording").fontWeight(.medium)
                } else {
                    HStack(alignment: .bottom, spacing: 2) {
                        Capsule().fill(.white.opacity(0.75)).frame(width: 2.5, height: 6)
                        Capsule().fill(VoicePalette.me).frame(width: 2.5, height: 13)
                        Capsule().fill(.white.opacity(0.75)).frame(width: 2.5, height: 8)
                    }
                    .frame(height: 13)
                    Text("New recording").fontWeight(.medium)
                }
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(
                LinearGradient(
                    colors: [PVDesign.accent, PVDesign.brandViolet],
                    startPoint: .topLeading, endPoint: .bottomTrailing),
                in: RoundedRectangle(cornerRadius: 10))
            .shadow(color: PVDesign.brandViolet.opacity(0.18), radius: 3, y: 1)
        }
        .buttonStyle(.plain)
        .keyboardShortcut("n")
        .accessibilityIdentifier(
            recordingActive
                ? "library-return-to-recording"
                : "library-new-recording-button")
        .help(recordingActive
            ? L10n.text("Return to the recording in progress")
            : L10n.text("Start a new recording"))
    }

    /// The short privacy note behind the sidebar chip.
    private var privacyNote: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Nothing is sent unless you ask for it. Every transfer is logged here.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Button("See activity") {
                showsPrivacyNote = false
                onOpenActivity()
            }
            .accessibilityIdentifier("library-privacy-activity")
        }
        .padding(14)
        .frame(width: 280)
        // A container, so the note's identifier does not stamp the
        // See activity button and hide its own.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("library-privacy-note")
    }

    /// Library filtering stays distinct from the global Command-K palette.
    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Search all meetings…", text: Binding(
                get: { state.query },
                set: { perform(.queryChanged($0)) }))
                .textFieldStyle(.plain)
                .accessibilityIdentifier("library-search-field")
                .task(id: state.query) { _ = await model.send(.observeSearch) }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    /// The product's one privacy promise, pinned under the library (D536).
    /// Every other surface trusts this chip instead of repeating the claim;
    /// the detail lives one click away, in Settings ▸ Your data.
    private var localFooter: some View {
        HStack {
            // Bordered, not plain: the hosted runner's hit test maps a
            // bordered button reliably in every locale.
            Button {
                showsPrivacyNote.toggle()
            } label: {
                Label("On your Mac", systemImage: PVSymbol.privacy)
                    .font(.caption2)
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
            .tint(.secondary)
            .fixedSize()
            .accessibilityIdentifier("library-privacy-chip")
            // A one-point sibling anchors the note: anything attached to the
            // chip's own bounds is an unmappable element under hit tests on
            // the hosted runner.
            Color.clear
                .frame(width: 1, height: 1)
                .accessibilityHidden(true)
                .popover(isPresented: $showsPrivacyNote, arrowEdge: .top) {
                    privacyNote
                }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }
}
