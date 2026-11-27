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
    @State private var isChoosingAudio = false
    @Binding var route: Route?
    @Binding var searchFocusRequested: Bool
    /// When the recording in progress started; nil when none is live.
    let recordingStartedAt: Date?
    let onReturnToRecording: () -> Void
    let onOpenSearchHit: (LibrarySearchHit) -> Void
    /// Opens Settings on Data & privacy, where the activity log lives.
    let onOpenActivity: () -> Void

    @State private var showsPrivacyNote = false
    @FocusState private var searchFocused: Bool
    private let briefTimer = Timer.publish(every: 300, on: .main, in: .common).autoconnect()

    /// Audio the importer accepts (drag-drop or the Import button).
    private static let importTypes: [UTType] =
        AudioImportFormats.fileExtensions.compactMap { UTType(filenameExtension: $0) } + [.meetingBundle]

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
        let groups = meetingGroups
        VStack(spacing: 0) {
            recordButton
                .padding(.horizontal, 12)
                .padding(.top, 12)

            LibraryNavigationControls(
                route: route,
                suggestionsToReview: state.suggestionsToReview,
                onNavigate: { route = $0 })
                .padding(.horizontal, 12)
                .padding(.top, 12)

            if let importStatus = state.importStatus {
                Text(importStatus)
                    .font(.caption)
                    .foregroundStyle(.ink3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.top, 6)
                    .accessibilityIdentifier("library-import-status")
            }

            LibraryImportStatusView(
                imports: imports, actionError: state.lastActionError,
                onOpen: { showsImportQueue = true },
                onDismissError: { perform(.dismissActionError) })

            searchField
                .padding(.horizontal, 12)
                .padding(.top, 8)

            List(selection: meetingSelection) {
                if !state.query.isEmpty {
                    Section {
                        if state.hits.isEmpty {
                            Text("No matches").foregroundStyle(.ink3)
                        }
                        ForEach(state.hits, id: \.segmentID) { hit in
                            Button {
                                onOpenSearchHit(hit)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(hit.snippet).lineLimit(2)
                                    Text(PVFont.timeCoded(hit.meetingTitle, at: ClockFormat.mmss(hit.startTime)))
                                        .font(.caption)
                                        .foregroundStyle(.ink3)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                            .selectionDisabled()
                            .accessibilityIdentifier(
                                "library-search-hit-\(hit.segmentID.uuidString)")
                        }
                    } header: {
                        LibrarySectionHeader("Results", id: "results")
                    }
                } else {
                    // Past meetings only: the agenda and open to-dos live on Today.
                    if state.showsNoMeetings {
                        Section {
                            Text("No meetings yet").foregroundStyle(.ink3)
                        } header: {
                            LibrarySectionHeader("Meetings", id: "meetings")
                        }
                    }
                    ForEach(groups, id: \.key) { group in
                        Section {
                            ForEach(group.meetings) { meeting in
                                meetingRow(meeting)
                            }
                        } header: {
                            LibrarySectionHeader(group.title, id: group.key)
                        }
                    }
                    TrashSection(
                        items: state.trashed,
                        onRestore: { perform(.restore($0.meeting.id)) },
                        onPurge: { perform(.purge($0)) })
                }
            }
            .listStyle(.sidebar)
            .contentMargins(.top, 16, for: .scrollContent)
            // AppKit keeps the scroll offset when a section lands above drawn
            // rows, which hid the first header; a new section set starts at the top.
            .id(sectionKeys(groups))
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
        // New summaries and to-dos change what Radar has to review.
        .onChange(of: state.libraryRevision) { perform(.refreshSuggestions) }
        // Reviewing in Radar changes the queue without touching the library.
        .onChange(of: route?.isCommitmentRadar == true) { perform(.refreshSuggestions) }
        .onReceive(briefTimer) { _ in
            perform(.refreshAgenda)
            perform(.refreshAutomations)
        }
    }

    private func isAudio(_ url: URL) -> Bool {
        AudioImportFormats.admits(url.pathExtension)
    }

    private func chooseAudioToImport() {
        guard !isChoosingAudio, state.importStatus == nil else { return }
        isChoosingAudio = true
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = Self.importTypes
        panel.prompt = L10n.text("Import")
        panel.message = L10n.text("Choose audio files to transcribe, or one .portavoz meeting file")
        AudioImportUITestFixture.configurePicker(panel)
        // Return from native menu tracking before entering the same app-modal
        // chooser. A nested modal loop inside the menu action delays its AX
        // acknowledgement; deferral keeps selection and cancellation unchanged.
        DispatchQueue.main.async {
            defer { isChoosingAudio = false }
            guard panel.runModal() == .OK else { return }
            importAudio(from: panel.urls)
        }
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
    /// This week (today included) and Earlier, newest first; empty groups drop.
    typealias MeetingGroup = (key: String, title: LocalizedStringKey, meetings: [Meeting])

    private var meetingGroups: [MeetingGroup] {
        let now = Date()
        let startOfWeek = Calendar.current.dateInterval(of: .weekOfYear, for: now)?.start
            ?? Calendar.current.startOfDay(for: now)
        let thisWeek = state.meetings.filter { $0.startedAt >= startOfWeek }
        let earlier = state.meetings.filter { $0.startedAt < startOfWeek }
        return [
            (key: "thisweek", title: LocalizedStringKey("This week"), meetings: thisWeek),
            (key: "earlier", title: LocalizedStringKey("Earlier"), meetings: earlier)
        ].filter { !$0.meetings.isEmpty }
    }

    private func sectionKeys(_ groups: [MeetingGroup]) -> [String] {
        guard state.query.isEmpty else { return ["results"] }
        return (state.showsNoMeetings ? ["meetings"] : []) + groups.map(\.key)
    }

    /// The selected meeting is a raised card over the native highlight; explicit
    /// ink keeps the text from inverting the way it does on an accent fill.
    private func meetingRow(_ meeting: Meeting) -> some View {
        let isSelected = route == .meeting(meeting.id)
        return VStack(alignment: .leading, spacing: 2) {
            Text(MeetingRowTitle.display(meeting.title))
                .fontWeight(.semibold)
                .foregroundStyle(PVDesign.ink)
                .lineLimit(1)
            Text(meeting.dayAndLength)
                .font(.caption.monospacedDigit())
                .foregroundStyle(PVDesign.ink3)
            VoiceStrip(state.voiceStrips[meeting.id] ?? .empty)
                .padding(.top, 6)
        }
        .padding(.vertical, 5)
        .listRowBackground(
            isSelected ? PVRaisedSurface(cornerRadius: PVDesign.radiusSmall).padding(.horizontal, 7) : nil)
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

    /// The primary action, an ink pill led by the Portavoz mark, plus a ▾ menu
    /// for the rare ones (Import), so the navigation list stays destinations only.
    /// While a recording is live the red return button takes the whole row;
    /// audio can still be dropped on the window to import it.
    private var recordButton: some View {
        HStack(spacing: 4) {
            recordAction
            if !recordingActive { importMenu }
        }
    }

    private var importMenu: some View {
        Menu {
            Button {
                chooseAudioToImport()
            } label: {
                Label("Import audio…", systemImage: "square.and.arrow.down")
            }
            .disabled(state.importStatus != nil || isChoosingAudio)
            .accessibilityIdentifier("library-import-audio-button")
        } label: {
            Image(systemName: "chevron.down")
                .font(.caption.weight(.semibold))
                .foregroundStyle(PVDesign.onInk)
                .frame(width: 24, height: 34)
                .background(PVDesign.ink, in: RoundedRectangle(cornerRadius: 10))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(L10n.text("More recording options"))
        .help(L10n.text("Transcribe an audio file (.m4a, .wav, .mp3) as a new meeting"))
        .accessibilityIdentifier("library-record-menu")
    }

    private var recordAction: some View {
        Button {
            if recordingActive {
                onReturnToRecording()
            } else {
                route = .recording(nil)
            }
        } label: {
            HStack(spacing: 6) {
                if let recordingStartedAt {
                    Circle().fill(PVDesign.onNow).frame(width: 6, height: 6)
                    Text("Return to recording")
                        .minimumScaleFactor(0.8)
                    Spacer(minLength: 0)
                    LibraryRecordingElapsed(startedAt: recordingStartedAt)
                } else {
                    PortavozMarkGlyph(color: PVDesign.onInk)
                    Text("New recording")
                }
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(recordingActive ? .pvStop : .pvPrimary)
        .controlSize(.large)
        .keyboardShortcut("n")
        .accessibilityIdentifier(
            recordingActive
                ? "library-return-to-recording"
                : "library-new-recording-button")
        .help(recordingActive
            ? L10n.text("Return to the recording in progress")
            : L10n.text("Start a new recording"))
    }

    private var recordingActive: Bool { recordingStartedAt != nil }

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
                .foregroundStyle(.ink3)
                .accessibilityHidden(true)
            TextField("Search all meetings…", text: Binding(
                get: { state.query },
                set: { perform(.queryChanged($0)) }))
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .accessibilityIdentifier("library-search-field")
                .task(id: state.query) { _ = await model.send(.observeSearch) }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        .task(id: searchFocusRequested) {
            guard searchFocusRequested else { return }
            // A sidebar being revealed can take focus only once it is on screen.
            for _ in 0..<10 where !searchFocused {
                searchFocused = true
                try? await Task.sleep(for: .milliseconds(100))
            }
            searchFocusRequested = false
        }
    }

    /// The product's one privacy promise, pinned under the library (D536).
    /// Every other surface trusts this chip instead of repeating the claim;
    /// the detail lives one click away, in Settings ▸ Data & privacy.
    private var localFooter: some View {
        HStack {
            Button {
                showsPrivacyNote.toggle()
            } label: {
                Label("On your Mac", systemImage: PVSymbol.privacy)
                    .font(.caption2.weight(.semibold))
            }
            .buttonStyle(.pvOfferChip)
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

/// A native sidebar section header in ink 3 semibold: the system header
/// grey reads near 2:1 on paper.
struct LibrarySectionHeader: View {
    let title: LocalizedStringKey
    let id: String

    init(_ title: LocalizedStringKey, id: String) {
        self.title = title
        self.id = id
    }

    var body: some View {
        Text(title)
            .fontWeight(.semibold)
            .foregroundStyle(.ink3)
            .accessibilityIdentifier("library-section-\(id)")
    }
}

/// The live recording's elapsed time beside "Return to recording"; only this
/// text ticks, once a second.
private struct LibraryRecordingElapsed: View {
    let startedAt: Date

    var body: some View {
        TimelineView(.periodic(from: startedAt, by: 1)) { context in
            Text(verbatim: ClockFormat.mmss(context.date.timeIntervalSince(startedAt), truncating: true))
                .font(.caption.weight(.semibold).monospacedDigit())
                .opacity(0.85)
                .accessibilityIdentifier("library-recording-elapsed")
        }
    }
}
