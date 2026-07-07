import PortavozCore
import StorageKit
import SwiftUI

/// Sidebar: record button, full-text search, and the meeting library.
struct LibraryView: View {
    @Environment(AppServices.self) private var services
    @Binding var route: Route?

    @State private var meetings: [Meeting] = []
    @State private var query = ""
    @State private var hits: [SearchHit] = []

    var body: some View {
        VStack(spacing: 0) {
            Button {
                route = .recording
            } label: {
                Label("Nueva grabación", systemImage: "record.circle")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .keyboardShortcut("n")
            .padding(12)

            TextField("Buscar en todas las reuniones…", text: $query)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 12)
                .onChange(of: query) { _, newValue in
                    Task { await search(newValue) }
                }

            List(selection: $route) {
                if !query.isEmpty {
                    Section("Resultados") {
                        if hits.isEmpty {
                            Text("Sin coincidencias").foregroundStyle(.secondary)
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
                    Section("Reuniones") {
                        if meetings.isEmpty {
                            Text("Todavía no hay reuniones").foregroundStyle(.secondary)
                        }
                        ForEach(meetings) { meeting in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(meeting.title).lineLimit(1)
                                Text(meeting.startedAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .tag(Route.meeting(meeting.id))
                        }
                    }
                }
            }
            .listStyle(.sidebar)
        }
        .navigationTitle("Portavoz")
        .task(id: services.libraryVersion) { await reload() }
    }

    private func reload() async {
        meetings = (try? await services.store.meetings()) ?? []
    }

    private func search(_ text: String) async {
        guard !text.isEmpty else {
            hits = []
            return
        }
        hits = (try? await services.store.search(text)) ?? []
    }

    private func timestamp(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
