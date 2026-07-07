import AppKit
import IntegrationsKit
import IntelligenceKit
import PortavozCore
import StorageKit
import SwiftUI
import UniformTypeIdentifiers

/// Transcript with editable speaker pills (the M3 leftover), the latest
/// summary snapshot, and its checkable action items.
struct MeetingDetailView: View {
    @Environment(AppServices.self) private var services
    let meetingID: MeetingID
    @Binding var route: Route?

    @State private var detail: MeetingDetail?
    @State private var summary: (draft: SummaryDraft, version: Int)?
    @State private var renamingSpeaker: Speaker?
    @State private var newName = ""
    @State private var exportDocument: ExportDocument?
    @State private var exportType: UTType = .plainText
    @State private var exportName = "reunion"
    @State private var regenerating = false
    @State private var showGistConfirm = false
    @State private var gistResult: URL?
    @State private var gistError: String?

    var body: some View {
        Group {
            if let detail {
                loaded(detail)
            } else {
                ProgressView()
            }
        }
        .task(id: services.libraryVersion) { await reload() }
    }

    @ViewBuilder
    private func loaded(_ detail: MeetingDetail) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header(detail)

                if let summary {
                    summarySection(summary)
                } else if regenerating {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Generando resumen…").foregroundStyle(.secondary)
                    }
                } else if !detail.segments.isEmpty {
                    Button {
                        regenerate(language: Locale.current.language.languageCode?.identifier ?? "en")
                    } label: {
                        Label("Generar resumen", systemImage: "sparkles")
                    }
                }

                Text("Transcript")
                    .font(.headline)
                ForEach(detail.segments) { segment in
                    segmentRow(segment, speakers: detail.speakers)
                }
            }
            .padding(20)
            .frame(maxWidth: 760, alignment: .leading)
        }
        .navigationTitle(detail.meeting.title)
        .toolbar {
            Menu {
                Button("Exportar Markdown…") { export(detail, as: .markdown) }
                Button("Exportar PDF…") { export(detail, as: .pdf) }
                Divider()
                Button("Publicar como Gist…") { showGistConfirm = true }
            } label: {
                Label("Exportar", systemImage: "square.and.arrow.up")
            }
            Button(role: .destructive) {
                Task {
                    try? await services.store.delete(meetingID)
                    services.libraryVersion += 1
                    route = nil
                }
            } label: {
                Label("Eliminar", systemImage: "trash")
            }
        }
        .fileExporter(
            isPresented: Binding(
                get: { exportDocument != nil },
                set: { if !$0 { exportDocument = nil } }
            ),
            document: exportDocument,
            contentType: exportType,
            defaultFilename: exportName
        ) { _ in
            exportDocument = nil
        }
        .confirmationDialog(
            "El transcript completo saldrá de tu Mac hacia GitHub como gist SECRETO (no listado).",
            isPresented: $showGistConfirm,
            titleVisibility: .visible
        ) {
            Button("Publicar gist secreto") { Task { await publishGist(detail) } }
            Button("Cancelar", role: .cancel) {}
        }
        .alert(
            "Gist publicado",
            isPresented: Binding(get: { gistResult != nil }, set: { if !$0 { gistResult = nil } })
        ) {
            Button("Copiar enlace") {
                if let url = gistResult {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url.absoluteString, forType: .string)
                }
            }
            Button("Abrir") {
                if let url = gistResult { NSWorkspace.shared.open(url) }
            }
            Button("OK", role: .cancel) {}
        } message: {
            Text(gistResult?.absoluteString ?? "")
        }
        .alert(
            "No se pudo publicar",
            isPresented: Binding(get: { gistError != nil }, set: { if !$0 { gistError = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(gistError ?? "")
        }
        .alert("Renombrar hablante", isPresented: renameBinding) {
            TextField("Nombre", text: $newName)
            Button("Guardar") { Task { await rename() } }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("Etiqueta actual: \(renamingSpeaker?.label ?? "")")
        }
    }

    private func header(_ detail: MeetingDetail) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(detail.meeting.title).font(.title2.bold())
            HStack(spacing: 12) {
                Text(detail.meeting.startedAt.formatted(date: .long, time: .shortened))
                if let ended = detail.meeting.endedAt {
                    let minutes = Int(ended.timeIntervalSince(detail.meeting.startedAt) / 60)
                    Text("\(minutes) min")
                }
                Text("\(detail.segments.count) segmentos")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
    }

    private func summarySection(_ summary: (draft: SummaryDraft, version: Int)) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Resumen")
                    .font(.headline)
                Text("v\(summary.version) · \(summary.draft.language)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if regenerating {
                    ProgressView().controlSize(.small)
                } else {
                    Menu {
                        Button("Regenerar en español") { regenerate(language: "es") }
                        Button("Regenerate in English") { regenerate(language: "en") }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            }
            MarkdownText(text: summary.draft.markdown)
            ForEach(summary.draft.actionItems) { item in
                Toggle(isOn: actionBinding(item)) {
                    Text(item.text)
                        .strikethrough(item.isDone)
                }
                .toggleStyle(.checkbox)
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }

    private func segmentRow(_ segment: TranscriptSegment, speakers: [Speaker]) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(timestamp(segment.startTime))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 44, alignment: .trailing)
            SpeakerPill(
                speaker: speakers.first { $0.id == segment.speakerID }
            ) { speaker in
                renamingSpeaker = speaker
                newName = speaker.displayName ?? ""
            }
            Text(segment.text)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }

    // MARK: - Actions

    private enum ExportFormat { case markdown, pdf }

    private func export(_ detail: MeetingDetail, as format: ExportFormat) {
        let markdown = MeetingExporter.markdown(
            meeting: detail.meeting,
            speakers: detail.speakers,
            segments: detail.segments,
            summary: summary?.draft,
            summaryVersion: summary?.version
        )
        switch format {
        case .markdown:
            exportType = .plainText
            exportName = "\(detail.meeting.title).md"
            exportDocument = ExportDocument(data: Data(markdown.utf8))
        case .pdf:
            guard let data = try? MeetingExporter.pdf(fromMarkdown: markdown) else { return }
            exportType = .pdf
            exportName = "\(detail.meeting.title).pdf"
            exportDocument = ExportDocument(data: data)
        }
    }

    private func regenerate(language: String) {
        guard let detail, !regenerating else { return }
        regenerating = true
        Task {
            defer { regenerating = false }
            guard #available(macOS 26.0, *) else {
                gistError = "Los resúmenes on-device necesitan macOS 26."
                return
            }
            if let reason = FoundationModelSummaryProvider.unavailabilityReason() {
                gistError = reason
                return
            }
            let request = SummaryRequest(
                meetingID: meetingID,
                segments: detail.segments,
                speakers: detail.speakers,
                recipe: .general,
                targetLanguage: language
            )
            if let draft = try? await FoundationModelSummaryProvider().summarize(request) {
                try? await services.store.saveSummary(draft)
                services.libraryVersion += 1
            }
        }
    }

    private func publishGist(_ detail: MeetingDetail) async {
        guard
            let token = try? SecretStore.get(service: SecretStore.gitHubTokenService),
            !token.isEmpty
        else {
            gistError = "Configura tu token de GitHub en Ajustes (⌘,) primero."
            return
        }
        let markdown = MeetingExporter.markdown(
            meeting: detail.meeting,
            speakers: detail.speakers,
            segments: detail.segments,
            summary: summary?.draft,
            summaryVersion: summary?.version
        )
        do {
            gistResult = try await GistPublisher(token: token).publish(
                markdown: markdown,
                filename: "\(detail.meeting.title).md",
                description: detail.meeting.title,
                isPublic: false
            )
        } catch {
            gistError = error.localizedDescription
        }
    }

    private var renameBinding: Binding<Bool> {
        Binding(
            get: { renamingSpeaker != nil },
            set: { if !$0 { renamingSpeaker = nil } }
        )
    }

    private func rename() async {
        guard var speaker = renamingSpeaker else { return }
        speaker.displayName = newName.isEmpty ? nil : newName
        try? await services.store.save([speaker])
        renamingSpeaker = nil
        services.libraryVersion += 1
    }

    private func actionBinding(_ item: ActionItem) -> Binding<Bool> {
        Binding(
            get: { item.isDone },
            set: { done in
                Task {
                    try? await services.store.setActionItem(item.id, done: done)
                    services.libraryVersion += 1
                }
            }
        )
    }

    private func reload() async {
        detail = try? await services.store.detail(meetingID)
        summary = try? await services.store.summary(meetingID)
    }

    private func timestamp(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

/// Write-only wrapper so `fileExporter` can save bytes we already built.
struct ExportDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.plainText, .pdf]
    let data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

/// One speaker chip; "Me" gets the accent color. Click to rename — the
/// M3 "editable speaker pills" acceptance piece.
struct SpeakerPill: View {
    let speaker: Speaker?
    let onRename: (Speaker) -> Void

    var body: some View {
        Button {
            if let speaker { onRename(speaker) }
        } label: {
            Text(speaker.map { $0.displayName ?? $0.label } ?? "?")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(
                    (speaker?.isMe == true ? Color.accentColor : Color.secondary).opacity(0.18),
                    in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(speaker == nil)
    }
}

