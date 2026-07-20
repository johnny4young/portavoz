import AppKit
import ApplicationKit
import PortavozCore
import SwiftUI
import UniformTypeIdentifiers

/// Sidebar: record button, full-text search, and the meeting library.
struct LibraryView: View {
    let model: LibraryModel
    @Binding var route: Route?

    /// To-dos fold away when the user wants a lean sidebar; the choice
    /// survives relaunches.
    @AppStorage("todosSectionExpanded") private var todosExpanded = true
    @Environment(\.colorScheme) private var colorScheme
    private let briefTimer = Timer.publish(every: 300, on: .main, in: .common).autoconnect()

    /// Audio the importer accepts (drag-drop or the Import button).
    private static let importTypes: [UTType] = [.audio, .mpeg4Audio, .wav, .mp3, .meetingBundle]

    private var state: LibraryModel.State { model.state }

    /// The sidebar List owns meeting selection only. `route` also represents
    /// Ask, Insights, and Recording; binding the List directly to that broader
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

            if let importStatus = state.importStatus {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(importStatus).font(.caption).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
            } else {
                HStack(spacing: 6) {
                    actionChip(
                        "Import", systemImage: "square.and.arrow.down",
                        id: "library-import-audio-button",
                        help: "Transcribe an audio file (.m4a, .wav, .mp3) as a new meeting"
                    ) { chooseAudioToImport() }
                    actionChip(
                        "Ask", systemImage: "bubble.left.and.text.bubble.right",
                        id: "library-ask-button", active: route == .ask,
                        help: "Natural-language questions over every meeting, answered on your Mac"
                    ) { route = .ask }
                    actionChip(
                        "Insights", systemImage: "chart.bar.xaxis",
                        id: "library-insights-button", active: route == .insights,
                        help: "Totals, cadence, people and commitments — computed on your Mac"
                    ) { route = .insights }
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
            }

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
                .help("Shows today's and tomorrow's meetings here, with a prep brief for each. Read-only, on-device.")
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
        // Drop an audio file anywhere on the sidebar to import it.
        .dropDestination(for: URL.self) { urls, _ in
            guard state.importStatus == nil,
                let url = urls.first(where: isAudio)
            else { return false }
            importAudio(from: url)
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
        .help("Brief for this meeting: who's coming, related meetings, open to-dos")
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
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = Self.importTypes
        panel.prompt = L10n.text("Import")
        panel.message = L10n.text("Choose an audio file to transcribe, or a .portavoz meeting file")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importAudio(from: url)
    }

    private func importAudio(from url: URL) {
        guard state.importStatus == nil else { return }
        perform(.importFile(url))
    }

    private func timestamp(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%02d:%02d", total / 60, total % 60)
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

    /// The selected meeting's row fill: the DS aurora gradient. Unselected
    /// rows stay clear so the sidebar material shows through.
    @ViewBuilder
    private func meetingRowBackground(_ selected: Bool) -> some View {
        if selected {
            RoundedRectangle(cornerRadius: 6)
                .fill(LinearGradient(
                    colors: [PVDesign.accent, PVDesign.brandViolet],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
                .padding(.horizontal, 6)
        } else {
            Color.clear
        }
    }

    /// One meeting row: title, date, and its voice-mix bar. The selected
    /// row wears the DS's indigo→violet gradient (not the user's system
    /// accent — the DS's stance on the accent debt), painted as the row
    /// background so it wins over the native sidebar highlight.
    private func meetingRow(_ meeting: Meeting) -> some View {
        let selected = route == .meeting(meeting.id)
        return VStack(alignment: .leading, spacing: 3) {
            Text(meeting.title).lineLimit(1)
                .foregroundStyle(selected ? Color.white : .primary)
            Text(meeting.startedAt.formatted(date: .abbreviated, time: .shortened))
                .font(.caption)
                .foregroundStyle(selected ? Color.white.opacity(0.75) : .secondary)
            if let mix = state.voiceMixes[meeting.id] {
                VoiceMixBar(slices: mix, colorScheme: colorScheme)
            }
        }
        .listRowBackground(meetingRowBackground(selected))
        .tag(Route.meeting(meeting.id))
        .accessibilityIdentifier("library-meeting-\(meeting.id.rawValue.uuidString)")
        .contextMenu {
            Button("Rename…") {
                perform(.beginRename(meeting))
            }
            Button("Delete", role: .destructive) {
                perform(.delete(meeting.id))
            }
        }
    }

    /// The primary action, styled to the design system: an indigo→violet
    /// gradient pill whose leading glyph is a mini-waveform with your amber
    /// peak — the brand mark on the button you press most.
    private var recordButton: some View {
        Button {
            route = .recording(nil)
        } label: {
            HStack(spacing: 8) {
                HStack(alignment: .bottom, spacing: 2) {
                    Capsule().fill(.white.opacity(0.75)).frame(width: 2.5, height: 6)
                    Capsule().fill(VoicePalette.me).frame(width: 2.5, height: 13)
                    Capsule().fill(.white.opacity(0.75)).frame(width: 2.5, height: 8)
                }
                .frame(height: 13)
                Text("New recording").fontWeight(.medium)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(
                LinearGradient(
                    colors: [PVDesign.accent, PVDesign.brandViolet],
                    startPoint: .topLeading, endPoint: .bottomTrailing),
                in: RoundedRectangle(cornerRadius: 10))
            .shadow(color: PVDesign.brandViolet.opacity(0.4), radius: 8, y: 3)
        }
        .buttonStyle(.plain)
        .keyboardShortcut("n")
        .accessibilityIdentifier("library-new-recording-button")
    }

    /// One of the vertical action chips (Import / Ask / Insights): a stacked
    /// icon + label that lights up when its route is active.
    private func actionChip(
        _ title: LocalizedStringKey, systemImage: String, id: String,
        active: Bool = false, help: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: systemImage).font(.system(size: 14))
                Text(title).font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(active ? PVDesign.accent : .secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(
                (active ? PVDesign.accent.opacity(0.16) : Color.secondary.opacity(0.10)),
                in: RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityIdentifier(id)
    }

    /// Search field with a ⌘K keycap — the palette is one shortcut away.
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
            Text(verbatim: "⌘K")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 5)
                .padding(.vertical, 3)
                .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 4))
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    /// The standing privacy line, pinned under the library — the product's
    /// core claim, always in view.
    private var localFooter: some View {
        HStack(spacing: 7) {
            Circle().fill(.green).frame(width: 7, height: 7)
            Text("Local-first · transfers require opt-in")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }
}
