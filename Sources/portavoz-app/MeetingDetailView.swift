import AppKit
import AudioPlaybackKit
import DiarizationKit
import IntegrationsKit
import IntelligenceKit
import PortavozCore
import StorageKit
import SwiftUI
import TranscriptionKit
import UniformTypeIdentifiers

/// Transcript with editable speaker pills (the M3 leftover), the latest
/// summary snapshot, and its checkable action items.
struct MeetingDetailView: View {
    @Environment(AppServices.self) private var services
    let meetingID: MeetingID
    @Binding var route: Route?

    @State private var detail: MeetingDetail?
    @State private var summary: (draft: SummaryDraft, version: Int)?
    @State private var player: MeetingPlayer?
    @State private var waveform: [Waveform.Bucket] = []
    @State private var channelURLs: [URL] = []
    @State private var compressing = false
    @State private var compressMessage: String?
    @State private var renamingSpeaker: Speaker?
    @State private var newName = ""
    @State private var exportDocument: ExportDocument?
    @State private var exportType: UTType = .plainText
    @State private var exportName = "reunion"
    @State private var regenerating = false
    @State private var showGistConfirm = false
    @State private var gistResult: URL?
    @State private var gistError: String?
    @State private var summaryNotice: String?
    @State private var nameSuggestions: [NameSuggestion] = []
    @State private var suggestingNames = false
    @State private var refining: String?
    @State private var refineError: String?
    @State private var refineDraft: RefineDraft?
    @State private var editingTitle = false
    @State private var newTitle = ""

    /// A refine result awaiting the user's decision — never applied on its
    /// own. The transcript it would replace stays untouched until "Aplicar".
    struct RefineDraft {
        let speakers: [Speaker]
        let segments: [TranscriptSegment]
        let oldSegmentCount: Int
        let oldSpeakerCount: Int
        let oldSpeechSeconds: TimeInterval

        var newSpeechSeconds: TimeInterval {
            segments.reduce(0) { $0 + ($1.endTime - $1.startTime) }
        }
        /// A refined pass that covers well under the current transcript's
        /// speech almost certainly failed — surfaced as a loud warning.
        var looksLossy: Bool { newSpeechSeconds < oldSpeechSeconds * 0.5 }
    }

    var body: some View {
        Group {
            if let detail {
                loaded(detail)
            } else {
                ProgressView()
            }
        }
        .task(id: services.libraryVersion) { await reload() }
        .onDisappear { player?.invalidate() }
    }

    @ViewBuilder
    private func loaded(_ detail: MeetingDetail) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                header(detail)
                speakersRow(detail)

                if let refining {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(refining).foregroundStyle(.secondary)
                    }
                }
                if let refineError {
                    Text(refineError).font(.caption).foregroundStyle(.red)
                }

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

                HStack {
                    Text("Transcript").font(.headline)
                    if player != nil {
                        Spacer()
                        Text("Toca una línea para saltar ahí")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                if let player {
                    MeetingPlayerBar(player: player, waveform: waveform)
                    if canCompressAudio || compressing || compressMessage != nil {
                        HStack(spacing: 8) {
                            Button(action: compressAudio) {
                                if compressing {
                                    HStack(spacing: 6) {
                                        ProgressView().controlSize(.small)
                                        Text("Comprimiendo…")
                                    }
                                } else {
                                    Label("Comprimir audio (AAC)", systemImage: "arrow.down.circle")
                                }
                            }
                            .controlSize(.small)
                            .disabled(!canCompressAudio)
                            .help("Convierte el audio a AAC para ahorrar disco, sin pérdida audible para voz")
                            if let compressMessage {
                                Text(compressMessage)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                    }
                }
                // Own View structs so only they re-render as the playhead
                // moves — the header and summary above stay put.
                TranscriptSegmentsView(
                    segments: detail.segments,
                    speakers: detail.speakers,
                    player: player,
                    onSeek: { player?.seek(to: $0); player?.play() },
                    onRenameTap: { speaker in
                        renamingSpeaker = speaker
                        newName = speaker.displayName ?? ""
                    })
            }
            .padding(16)
            .frame(maxWidth: 860, alignment: .leading)
        }
        .navigationTitle(detail.meeting.title)
        .sheet(
            isPresented: Binding(
                get: { refineDraft != nil },
                set: { if !$0 { refineDraft = nil } }
            )
        ) {
            if let draft = refineDraft {
                refineReviewSheet(draft)
            }
        }
        .toolbar {
            Button {
                refine(detail)
            } label: {
                if refining != nil {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Refinar", systemImage: "wand.and.stars")
                }
            }
            .disabled(refining != nil || detail.meeting.audioDirectory == nil)
            .help(
                "Re-transcribe con Whisper (máxima calidad) y propone el resultado como borrador — nada se aplica sin tu confirmación"
            )
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
            "Resumen",
            isPresented: Binding(
                get: { summaryNotice != nil }, set: { if !$0 { summaryNotice = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(summaryNotice ?? "")
        }
        .alert(
            "No se pudo completar",
            isPresented: Binding(get: { gistError != nil }, set: { if !$0 { gistError = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(gistError ?? "")
        }
        .alert("Renombrar reunión", isPresented: $editingTitle) {
            TextField("Título", text: $newTitle)
            Button("Guardar") {
                let title = newTitle
                var meeting = detail.meeting
                Task {
                    meeting.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !meeting.title.isEmpty else { return }
                    try? await services.store.save(meeting)
                    await reload()
                    services.libraryVersion += 1
                }
            }
            Button("Cancelar", role: .cancel) {}
        }
        .alert("Renombrar hablante", isPresented: renameBinding) {
            TextField("Nombre", text: $newName)
            Button("Guardar") {
                // Capture NOW: dismissing the alert nils renamingSpeaker
                // before the task runs, which silently dropped the rename.
                if let speaker = renamingSpeaker {
                    let name = newName
                    Task { await rename(speaker, to: name) }
                }
            }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("Etiqueta actual: \(renamingSpeaker?.label ?? "")")
        }
    }

    private func header(_ detail: MeetingDetail) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(detail.meeting.title).font(.title2.bold())
                Button {
                    newTitle = detail.meeting.title
                    editingTitle = true
                } label: {
                    Image(systemName: "pencil").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Renombrar la reunión")
            }
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

    /// The meeting's cast, with the M6 "1-tap speaker→name" flow: ✦
    /// proposes names the transcript proves; one click applies them.
    @ViewBuilder
    private func speakersRow(_ detail: MeetingDetail) -> some View {
        let unnamed = detail.speakers.filter { !$0.isMe && $0.displayName == nil }
        HStack(spacing: 8) {
            ForEach(detail.speakers) { speaker in
                SpeakerPill(speaker: speaker) { speaker in
                    renamingSpeaker = speaker
                    newName = speaker.displayName ?? ""
                }
            }
            if !unnamed.isEmpty {
                if suggestingNames {
                    ProgressView().controlSize(.small)
                } else if nameSuggestions.isEmpty {
                    Button {
                        Task { await suggestNames(detail) }
                    } label: {
                        Label("Sugerir nombres", systemImage: "sparkles")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                }
            }
            ForEach(nameSuggestions, id: \.label) { suggestion in
                Button {
                    Task { await apply(suggestion, in: detail) }
                } label: {
                    Text("\(suggestion.label) → ¿\(suggestion.name)?")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.14), in: Capsule())
                }
                .buttonStyle(.plain)
                .help("Evidencia: \(suggestion.evidence)")
            }
        }
    }

    private func suggestNames(_ detail: MeetingDetail) async {
        guard #available(macOS 26.0, *) else {
            gistError = "Las sugerencias de nombres necesitan macOS 26."
            return
        }
        suggestingNames = true
        defer { suggestingNames = false }
        do {
            // Calendar attendees around the meeting widen the candidate
            // pool (TCC prompt on first use; denial = empty list).
            let attendees = await CalendarAttendeeSource()
                .attendees(around: detail.meeting.startedAt)
            nameSuggestions = try await SpeakerNamer().suggestNames(
                segments: detail.segments, speakers: detail.speakers,
                attendeeCandidates: attendees)
            if nameSuggestions.isEmpty {
                gistError = "El transcript no prueba ningún nombre — puedes renombrar los pills a mano."
            }
        } catch {
            gistError = error.localizedDescription
        }
    }

    private func apply(_ suggestion: NameSuggestion, in detail: MeetingDetail) async {
        guard var speaker = detail.speakers.first(where: { $0.label == suggestion.label }) else {
            return
        }
        speaker.displayName = suggestion.name
        try? await services.store.save([speaker])
        nameSuggestions.removeAll { $0.label == suggestion.label }
        services.libraryVersion += 1
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
                Menu {
                    Button("Copiar como texto") { copySummary(summary.draft, as: .plainText) }
                    Button("Copiar como Markdown") { copySummary(summary.draft, as: .markdown) }
                    Button("Copiar para Slack") { copySummary(summary.draft, as: .slack) }
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Copia el resumen al portapapeles")
                if regenerating {
                    ProgressView().controlSize(.small)
                } else {
                    Menu {
                        Button("Regenerar en español") { regenerate(language: "es") }
                        Button("Regenerate in English") { regenerate(language: "en") }
                        if let alt = alternateEngine {
                            Divider()
                            Menu(alt.label) {
                                Button("Español") { regenerate(language: "es", engine: alt.engine) }
                                Button("English") { regenerate(language: "en", engine: alt.engine) }
                            }
                        }
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

    /// The D7 quality re-pass, in-app: re-transcribes both channels with
    /// Whisper (with the user's vocabulary), re-diarizes (micro-cluster
    /// merge included), atomically replaces the cast, and regenerates the
    /// summary from the clean transcript.
    private func refine(_ detail: MeetingDetail) {
        guard refining == nil else { return }
        refining = "Preparando…"
        refineError = nil
        Task {
            defer { refining = nil }
            do {
                guard let relative = detail.meeting.audioDirectory else {
                    refineError = "Esta reunión no conserva su audio."
                    return
                }
                let base = RecordingsLocation.shared.resolve(relative)
                let systemURL = MeetingAudioLayout.channelFile(named: "system", in: base)
                let microphoneURL = MeetingAudioLayout.channelFile(named: "microphone", in: base)
                guard systemURL != nil || microphoneURL != nil else {
                    refineError = "No se encontró el audio de la reunión."
                    return
                }

                let whisper = try await services.loadWhisperIfNeeded { status in
                    refining = status
                }
                try await services.loadEnginesIfNeeded()

                let vocabulary = VocabularyPrompt.parse(
                    UserDefaults.standard.string(forKey: "customVocabulary") ?? "")
                let hints = TranscriptionHints(vocabulary: vocabulary, meetingID: meetingID)

                var segments: [TranscriptSegment] = []
                if let systemURL {
                    refining = "Re-transcribiendo a los participantes (Whisper)…"
                    let result = try await whisper.transcribeFile(
                        at: systemURL, hints: hints, channel: .system)
                    segments.append(contentsOf: result.segments)
                }
                if let microphoneURL {
                    refining = "Re-transcribiendo tu canal (Whisper)…"
                    let result = try await whisper.transcribeFile(
                        at: microphoneURL, hints: hints, channel: .microphone)
                    segments.append(contentsOf: result.segments)
                }
                segments.sort { $0.startTime < $1.startTime }

                var turns: [SpeakerTurn] = []
                if let systemURL, let diarizer = services.diarizer {
                    refining = "Identificando hablantes…"
                    turns = (try? await diarizer.diarizeFile(at: systemURL)) ?? []
                }
                let attribution = SpeakerAttributor.attribute(
                    segments: segments, turns: turns, meetingID: meetingID)

                // Draft, never override: the user compares and decides.
                let oldSpeech = detail.segments.reduce(0) { $0 + ($1.endTime - $1.startTime) }
                refineDraft = RefineDraft(
                    speakers: attribution.speakers,
                    segments: attribution.segments,
                    oldSegmentCount: detail.segments.count,
                    oldSpeakerCount: detail.speakers.count,
                    oldSpeechSeconds: oldSpeech)
            } catch {
                refineError = "El refinado falló: \(error.localizedDescription)"
            }
        }
    }

    private func applyRefineDraft(_ draft: RefineDraft) {
        refineDraft = nil
        refining = "Aplicando el transcript refinado…"
        Task {
            defer { refining = nil }
            do {
                try await services.store.replaceCast(
                    for: meetingID,
                    speakers: draft.speakers,
                    segments: draft.segments)
                await reload()
                services.libraryVersion += 1
                regenerate(
                    language: summary?.draft.language
                        ?? Locale.current.language.languageCode?.identifier ?? "en")
            } catch {
                refineError = "No se pudo aplicar el refinado: \(error.localizedDescription)"
            }
        }
    }

    private func refineReviewSheet(_ draft: RefineDraft) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Revisar el transcript refinado", systemImage: "wand.and.stars")
                .font(.title3.weight(.semibold))

            if draft.looksLossy {
                Label(
                    "El refinado cubre mucho menos habla que el transcript actual — probablemente falló. No lo apliques.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .foregroundStyle(.red)
            }

            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 6) {
                GridRow {
                    Text("").font(.caption)
                    Text("Actual").font(.caption.weight(.semibold))
                    Text("Refinado").font(.caption.weight(.semibold))
                }
                GridRow {
                    Text("Segmentos").foregroundStyle(.secondary)
                    Text("\(draft.oldSegmentCount)")
                    Text("\(draft.segments.count)")
                }
                GridRow {
                    Text("Hablantes").foregroundStyle(.secondary)
                    Text("\(draft.oldSpeakerCount)")
                    Text("\(draft.speakers.count)")
                }
                GridRow {
                    Text("Habla cubierta").foregroundStyle(.secondary)
                    Text(minutes(draft.oldSpeechSeconds))
                    Text(minutes(draft.newSpeechSeconds))
                }
            }

            Text("Muestra").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(draft.segments.prefix(8)) { segment in
                        Text(segment.text)
                            .font(.callout)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(maxHeight: 180)
            .padding(8)
            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))

            HStack {
                Spacer()
                Button("Descartar", role: .cancel) { refineDraft = nil }
                Button("Aplicar") { applyRefineDraft(draft) }
                    .buttonStyle(.borderedProminent)
                    .disabled(draft.segments.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private func minutes(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d min", total / 60, total % 60)
    }

    private func copySummary(_ draft: SummaryDraft, as format: MeetingExporter.SummaryFormat) {
        let text = MeetingExporter.summary(
            draft, speakers: detail?.speakers ?? [], format: format)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// The engine that is NOT the global default, offered as a per-meeting
    /// override in the regenerate menu — only when it can actually run here (M12).
    private var alternateEngine: (engine: AppServices.SummaryEngine, label: String)? {
        switch services.summaryEngine {
        case .appleOnDevice:
            if let model = services.ollamaModel {
                return (.ollama, "Regenerar con Ollama · \(model)")
            }
            return nil
        case .ollama:
            if services.appleSummaryAvailable {
                return (.appleOnDevice, "Regenerar con Apple (on-device)")
            }
            return nil
        }
    }

    private func regenerate(language: String, engine: AppServices.SummaryEngine? = nil) {
        guard let detail, !regenerating else { return }
        regenerating = true
        Task {
            defer { regenerating = false }
            let notes = (try? await services.store.contextItems(for: meetingID)) ?? []
            let request = SummaryRequest(
                meetingID: meetingID,
                segments: detail.segments,
                speakers: detail.speakers,
                recipe: .general,
                targetLanguage: language,
                glossary: VocabularyPrompt.parse(
                    UserDefaults.standard.string(forKey: "customVocabulary") ?? ""),
                contextItems: notes
            )

            // A configured non-Apple engine (Ollama) summarizes directly —
            // the fingerprint cache + translation pivot are FM-only. `engine`
            // overrides the global default for this one meeting (M12).
            if let provider = services.configuredSummaryProvider(override: engine) {
                if let draft = try? await provider.summarize(request) {
                    _ = try? await services.store.saveSummary(draft)
                    services.libraryVersion += 1
                } else {
                    gistError = "El modelo local no pudo generar el resumen."
                }
                return
            }

            guard #available(macOS 26.0, *) else {
                gistError = "Los resúmenes on-device necesitan macOS 26 (o elige Ollama en Ajustes)."
                return
            }
            if let reason = FoundationModelSummaryProvider.unavailabilityReason() {
                gistError = reason
                return
            }
            let provider = FoundationModelSummaryProvider()
            let fingerprint = SummaryFingerprint.compute(
                request: request, providerID: FoundationModelSummaryProvider.providerID)

            // Caché D25: mismo material + mismo idioma ya guardado — con
            // decodificación greedy el modelo reproduciría lo mismo.
            if let hit = try? await services.store.latestSummary(
                meetingID, fingerprint: fingerprint, language: language) {
                summaryNotice =
                    "El resumen v\(hit.version) ya corresponde a este material — no hay nada que regenerar. Cambia el transcript, las notas o el vocabulario para producir uno nuevo."
                return
            }
            // Pivote D25: mismo material en otro idioma → traducir ese
            // snapshot cuesta una fracción de re-resumir el transcript.
            if let pivot = try? await services.store.latestSummary(
                meetingID, fingerprint: fingerprint),
                let translated = try? await provider.translate(
                    pivot.draft, to: language, glossary: request.glossary) {
                _ = try? await services.store.saveSummary(translated)
                services.libraryVersion += 1
                return
            }
            if let draft = try? await provider.summarize(request) {
                _ = try? await services.store.saveSummary(draft)
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

    private func rename(_ speaker: Speaker, to name: String) async {
        var renamed = speaker
        renamed.displayName = name.isEmpty ? nil : name
        do {
            try await services.store.save([renamed])
        } catch {
            refineError = "No se pudo renombrar: \(error.localizedDescription)"
            return
        }
        renamingSpeaker = nil
        await reload()
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
        await loadPlayerIfNeeded()
    }

    /// Builds the synchronized player + waveform once (M11). Audio survives
    /// refine, so there's no reason to rebuild when the library version bumps.
    private func loadPlayerIfNeeded() async {
        guard player == nil, let relative = detail?.meeting.audioDirectory else { return }
        let base = RecordingsLocation.shared.resolve(relative)
        let system = MeetingAudioLayout.channelFile(named: "system", in: base)
        let mic = MeetingAudioLayout.channelFile(named: "microphone", in: base)
        let files = [system, mic].compactMap { $0 }
        guard !files.isEmpty else { return }
        channelURLs = files
        player = await MeetingPlayer.make(channelFiles: files)
        // Off the main actor: a long meeting reads a lot of frames.
        waveform = await Task.detached {
            Waveform.generate(micFile: mic, systemFile: system, buckets: 600)
        }.value
        player?.setSilentRanges(
            Waveform.silentRanges(waveform, duration: player?.duration ?? 0))
    }

    /// True when there's lossless audio (CAF/WAV) still worth compressing.
    private var canCompressAudio: Bool {
        !compressing && channelURLs.contains { $0.pathExtension.lowercased() != "m4a" }
    }

    /// Transcodes the channels to AAC and rebuilds the player from them.
    /// Originals are removed only after a verified write (M11/D27, T6).
    private func compressAudio() {
        let originals = channelURLs.filter { $0.pathExtension.lowercased() != "m4a" }
        guard !originals.isEmpty else { return }
        compressing = true
        compressMessage = nil
        Task {
            defer { compressing = false }
            let before = AudioTranscoder.totalBytes(of: channelURLs)
            do {
                for url in originals {
                    _ = try await AudioTranscoder.toAAC(source: url, deleteSource: true)
                }
            } catch {
                compressMessage = error.localizedDescription
                return
            }
            player?.invalidate()
            player = nil
            waveform = []
            channelURLs = []
            await loadPlayerIfNeeded()
            let saved = max(0, before - AudioTranscoder.totalBytes(of: channelURLs))
            compressMessage =
                "Audio comprimido — \(ByteCountFormatter.string(fromByteCount: saved, countStyle: .file)) liberados."
        }
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

/// The transport bar (M11): play/pause + a waveform scrubber over the mixed
/// timeline. Its own View so the scrubber's 5 fps updates don't re-render
/// the whole detail. Falls back to a plain slider until the waveform is
/// generated (or if the audio was unreadable).
struct MeetingPlayerBar: View {
    let player: MeetingPlayer
    let waveform: [Waveform.Bucket]

    @State private var exporting = false
    @State private var exportError: String?

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Button {
                    player.togglePlayPause()
                } label: {
                    Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.title)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
                .help(player.isPlaying ? "Pausar" : "Reproducir")
                .accessibilityIdentifier("player-play-pause")

                Text(clock(player.currentTime))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Toggle(isOn: Binding(get: { player.skipSilence }, set: { player.skipSilence = $0 })) {
                    Label("Saltar silencios", systemImage: "forward.fill")
                }
                .toggleStyle(.button)
                .controlSize(.small)
                .help("Salta automáticamente los silencios al reproducir")
                Text(clock(player.duration))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if waveform.isEmpty {
                Slider(
                    value: Binding(get: { player.currentTime }, set: { player.seek(to: $0) }),
                    in: 0...max(player.duration, 0.1))
            } else {
                WaveformView(
                    buckets: waveform,
                    progress: player.duration > 0 ? player.currentTime / player.duration : 0,
                    clipRange: clipFractions,
                    onSeek: { player.seek(to: $0 * player.duration) })
            }
            clipRow
        }
        .padding(10)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
        .alert(
            "No se pudo exportar",
            isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(exportError ?? "")
        }
    }

    /// Mark in/out at the playhead and export the range to an m4a clip.
    private var clipRow: some View {
        HStack(spacing: 8) {
            Button {
                player.markClipStart()
            } label: {
                Label("Inicio", systemImage: "arrow.down.right.and.arrow.up.left")
            }
            .controlSize(.small)
            .help("Marcar el inicio del clip en el punto actual")
            .accessibilityIdentifier("clip-mark-start")

            Button {
                player.markClipEnd()
            } label: {
                Label("Fin", systemImage: "arrow.up.left.and.arrow.down.right")
            }
            .controlSize(.small)
            .help("Marcar el fin del clip en el punto actual")
            .accessibilityIdentifier("clip-mark-end")

            if let range = player.clipRange {
                Text("Clip \(clock(range.upperBound - range.lowerBound))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Button {
                    exportClip(range)
                } label: {
                    if exporting {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Exportar", systemImage: "square.and.arrow.up")
                    }
                }
                .controlSize(.small)
                .disabled(exporting)
                .accessibilityIdentifier("clip-export")
                Button {
                    player.clearClip()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .controlSize(.small)
                .help("Descartar el clip")
            }
            Spacer()
        }
        .font(.caption)
    }

    /// The clip marks as 0…1 fractions for the waveform overlay.
    private var clipFractions: ClosedRange<Double>? {
        guard let range = player.clipRange, player.duration > 0 else { return nil }
        return (range.lowerBound / player.duration)...(range.upperBound / player.duration)
    }

    private func exportClip(_ range: ClosedRange<TimeInterval>) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "clip.m4a"
        panel.allowedContentTypes = [.mpeg4Audio]
        panel.prompt = "Exportar"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        exporting = true
        Task {
            defer { exporting = false }
            do {
                try await AudioClipExporter.export(
                    channelFiles: player.channelFiles, range: range, to: url)
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                exportError = error.localizedDescription
            }
        }
    }

    private func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// The scrubber waveform (M11): peak-amplitude columns tinted by who was
/// talking (accent = you, gray = them) and dimmed past the playhead. Click
/// or drag anywhere to seek.
struct WaveformView: View {
    let buckets: [Waveform.Bucket]
    /// Playback position as a 0…1 fraction of the duration.
    let progress: Double
    /// The selected clip as 0…1 fractions, shaded on the waveform.
    let clipRange: ClosedRange<Double>?
    /// Called with the seeked fraction (0…1) on click/drag.
    let onSeek: (Double) -> Void

    var body: some View {
        GeometryReader { geo in
            Canvas { context, size in
                guard !buckets.isEmpty else { return }
                // Shade the selected clip range behind the bars.
                if let clipRange {
                    let rect = CGRect(
                        x: clipRange.lowerBound * size.width, y: 0,
                        width: (clipRange.upperBound - clipRange.lowerBound) * size.width,
                        height: size.height)
                    context.fill(
                        Path(roundedRect: rect, cornerRadius: 3),
                        with: .color(.accentColor.opacity(0.15)))
                }
                let barWidth = size.width / CGFloat(buckets.count)
                let mid = size.height / 2
                for (index, bucket) in buckets.enumerated() {
                    let height = max(2, CGFloat(bucket.amplitude) * (size.height - 2))
                    let rect = CGRect(
                        x: CGFloat(index) * barWidth + barWidth * 0.2,
                        y: mid - height / 2,
                        width: max(1, barWidth * 0.6),
                        height: height)
                    let played = (Double(index) + 0.5) / Double(buckets.count) <= progress
                    let base: Color = bucket.micDominant ? .accentColor : .gray
                    context.fill(
                        Path(roundedRect: rect, cornerRadius: 1),
                        with: .color(base.opacity(played ? 0.9 : 0.3)))
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { value in
                    onSeek(min(1, max(0, value.location.x / max(1, geo.size.width))))
                })
        }
        .frame(height: 44)
    }
}

/// The transcript with a synchronized highlight (M11). Its own View so the
/// playhead moving only re-renders here, not the summary/header above. The
/// timestamp doubles as a "jump here" button, leaving the text selectable.
struct TranscriptSegmentsView: View {
    let segments: [TranscriptSegment]
    let speakers: [Speaker]
    let player: MeetingPlayer?
    let onSeek: (TimeInterval) -> Void
    let onRenameTap: (Speaker) -> Void

    /// The segment under the playhead: the one whose range contains the
    /// current time, or the last one that already started (so a gap between
    /// segments keeps the previous line lit).
    private var activeSegmentID: TranscriptSegment.ID? {
        guard let player else { return nil }
        let now = player.currentTime
        return segments.last(where: { $0.startTime <= now && now < $0.endTime })?.id
            ?? segments.last(where: { $0.startTime <= now })?.id
    }

    var body: some View {
        if player != nil {
            // With audio, the transcript is a Spotify-lyrics carousel: the
            // spoken line stays centered inside its own viewport, so seeking
            // moves the transcript, never the whole page.
            FocusedTranscriptView(segments: segments, activeID: activeSegmentID) {
                segment, isActive in
                row(segment, isActive: isActive)
            }
        } else {
            // No audio to follow — a plain readable list scrolling with the
            // page. Lazy: a long meeting has thousands of rows.
            LazyVStack(alignment: .leading, spacing: 3) {
                ForEach(segments) { segment in
                    row(segment, isActive: false)
                }
            }
        }
    }

    private func row(_ segment: TranscriptSegment, isActive: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Button {
                onSeek(segment.startTime)
            } label: {
                Text(clock(segment.startTime))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(isActive ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                    .frame(width: 44, alignment: .trailing)
            }
            .buttonStyle(.plain)
            .disabled(player == nil)
            .help("Saltar a este momento")
            SpeakerPill(speaker: speakers.first { $0.id == segment.speakerID }, onRename: onRenameTap)
            Text(segment.text)
                .font(.callout)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 8)
        .background(
            isActive ? Color.accentColor.opacity(0.12) : Color.clear,
            in: RoundedRectangle(cornerRadius: 6))
    }

    private func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
