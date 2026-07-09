import AppKit
import PortavozCore
import StorageKit
import SwiftUI
import UniformTypeIdentifiers

/// Sidebar: record button, full-text search, and the meeting library.
struct LibraryView: View {
    @Environment(AppServices.self) private var services
    @Binding var route: Route?

    @State private var meetings: [Meeting] = []
    @State private var query = ""
    @State private var hits: [SearchHit] = []
    /// Open action items across ALL meetings — the cross-meeting to-do list.
    @State private var openItems: [MeetingStore.OpenActionItem] = []
    @State private var renamingMeeting: Meeting?
    @State private var newTitle = ""
    @State private var importStatus: String?
    @State private var importError: String?

    /// Audio the importer accepts (drag-drop or the Import button).
    private static let importTypes: [UTType] = [.audio, .mpeg4Audio, .wav, .mp3]

    var body: some View {
        VStack(spacing: 0) {
            Button {
                route = .recording
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
                    if !openItems.isEmpty {
                        Section("To-dos") {
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
        // Drop an audio file anywhere on the sidebar to import it.
        .dropDestination(for: URL.self) { urls, _ in
            guard importStatus == nil, let url = urls.first(where: isAudio) else { return false }
            importAudio(from: url)
            return true
        }
        .task(id: services.libraryVersion) { await reload() }
    }

    private func reload() async {
        meetings = (try? await services.store.meetings()) ?? []
        openItems = (try? await services.store.openActionItems(limit: 20)) ?? []
    }

    /// One open action item: check it off right here, or click through to
    /// its meeting. Checking bumps `libraryVersion`, which reloads the list
    /// (and the detail view, which shares the same items).
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
        }
        .tag(Route.meeting(open.meetingID))
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
        panel.message = L10n.text("Choose an audio file to transcribe as a meeting")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importAudio(from: url)
    }

    private func importAudio(from url: URL) {
        guard importStatus == nil else { return }
        importStatus = L10n.text("Preparing…")
        Task {
            do {
                let id = try await services.importMeeting(from: url) { status in
                    importStatus = status
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
