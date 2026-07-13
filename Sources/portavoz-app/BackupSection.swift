import AppKit
import IntegrationsKit
import PortavozCore
import SwiftUI

/// Settings section: export the WHOLE library as Markdown — one readable
/// file per meeting (summary, action items, transcript), no Portavoz
/// needed to read them ever again. The living proof of "your history is
/// never hostage".
struct BackupSection: View {
    @Environment(AppServices.self) private var services
    @State private var status: String?
    @State private var running = false

    var body: some View {
        Section("Your data") {
            Button {
                chooseFolderAndExport()
            } label: {
                Label("Export all meetings (Markdown)…", systemImage: "externaldrive")
            }
            .disabled(running)
            .accessibilityIdentifier("settings-export-all-button")
            if let status {
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
            Text(
                // One-line UI help text.
                // swiftlint:disable:next line_length
                "Writes one Markdown file per meeting — summary, action items and full transcript — into a folder you choose. Plain files you can read, grep and back up without Portavoz."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func chooseFolderAndExport() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = L10n.text("Export here")
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        running = true
        status = L10n.text("Exporting…")
        Task {
            let count = await exportAll(to: folder)
            running = false
            status = L10n.format("%d meetings exported.", count)
        }
    }

    /// One `.md` per meeting; duplicate titles get " 2", " 3"… suffixes so
    /// nothing is ever overwritten.
    private func exportAll(to folder: URL) async -> Int {
        let meetings = (try? await services.store.meetings()) ?? []
        var used: Set<String> = []
        var exported = 0
        for meeting in meetings {
            guard let detail = try? await services.store.detail(meeting.id) else { continue }
            let summary = try? await services.store.summary(meeting.id)
            let markdown = MeetingExporter.markdown(
                meeting: detail.meeting,
                speakers: detail.speakers,
                segments: detail.segments,
                summary: summary?.draft,
                summaryVersion: summary?.version)
            var name = sanitized(meeting.title)
            var attempt = 2
            while used.contains(name.lowercased()) {
                name = "\(sanitized(meeting.title)) \(attempt)"
                attempt += 1
            }
            used.insert(name.lowercased())
            let url = folder.appendingPathComponent("\(name).md")
            if (try? Data(markdown.utf8).write(to: url)) != nil {
                exported += 1
                status = L10n.format("Exporting… %d", exported)
            }
        }
        return exported
    }

    private func sanitized(_ title: String) -> String {
        let bad = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let cleaned = title.components(separatedBy: bad).joined(separator: "-")
            .trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? "meeting" : String(cleaned.prefix(120))
    }
}
