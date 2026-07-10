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

// Large SwiftUI view (transcript + summary + action items). Helper types
// (MeetingPlayerBar, WaveformView, TranscriptSegmentsView, SpeakerPill,
// ExportDocument) live in their own files; this type body is split across
// `extension MeetingDetailView` blocks below. The file stays above the
// file_length threshold because splitting the rest would expose ~24 private
// `@State` properties to the whole module — an encapsulation cost not worth
// paying for line-count only.
// swiftlint:disable file_length

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
    /// Typed-recipe suggestion (M13b): detected once per visit, offered as
    /// a chip — never applied on its own.
    @State private var suggestedRecipe: Recipe?
    @State private var detectedRecipeOnce = false
    /// Content-based title suggestion — same contract: chip, click, never solo.
    @State private var suggestedTitle: String?
    @State private var suggestedTitleOnce = false

    /// A refine result awaiting the user's decision — never applied on its
    /// own. The transcript it would replace stays untouched until "Apply".
    struct RefineDraft {
        let language: String?
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

    /// The loaded detail: the scrolling content plus the toolbar, sheet, and
    /// the stack of exporter/confirmation/alert modifiers. The branchy pieces
    /// live in the extracted subviews and computed bindings below so this
    /// stays a flat composition.
    private func loaded(_ detail: MeetingDetail) -> some View {
        loadedBody(detail)
            .navigationTitle(detail.meeting.title)
            .sheet(isPresented: refineDraftBinding) { refineSheet }
            .toolbar {
                refineButton(detail)
                exportMenu(detail)
                deleteButton
            }
            .fileExporter(
                isPresented: exportBinding,
                document: exportDocument,
                contentType: exportType,
                defaultFilename: exportName
            ) { _ in
                exportDocument = nil
            }
            .confirmationDialog(
                "The full transcript will leave your Mac for GitHub as a SECRET (unlisted) gist.",
                isPresented: $showGistConfirm,
                titleVisibility: .visible
            ) {
                gistConfirmButtons(detail)
            }
            .alert("Gist published", isPresented: gistResultBinding) {
                gistPublishedButtons
            } message: {
                Text(gistResult?.absoluteString ?? "")
            }
            .alert("Summary", isPresented: summaryNoticeBinding) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(summaryNotice ?? "")
            }
            .alert("Couldn’t complete", isPresented: gistErrorBinding) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(gistError ?? "")
            }
            .alert("Rename meeting", isPresented: $editingTitle) {
                renameMeetingButtons(detail)
            }
            .alert("Rename speaker", isPresented: renameBinding) {
                renameSpeakerButtons
            } message: {
                Text("Current label: \(renamingSpeaker?.label ?? "")")
            }
    }
}

// MARK: - Loaded content (subviews & presentation bindings)

extension MeetingDetailView {
    private func loadedBody(_ detail: MeetingDetail) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                header(detail)
                speakersRow(detail)
                refineStatus
                summaryOrGenerate(detail)
                MeetingHealthView(speakers: detail.speakers, segments: detail.segments)
                transcriptSection(detail)
            }
            .padding(16)
            .frame(maxWidth: 860, alignment: .leading)
        }
    }

    @ViewBuilder
    private var refineStatus: some View {
        if let refining {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(refining).foregroundStyle(.secondary)
            }
        }
        if let refineError {
            Text(refineError).font(.caption).foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private func summaryOrGenerate(_ detail: MeetingDetail) -> some View {
        if let summary {
            summarySection(summary)
        } else if regenerating {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Generating summary…").foregroundStyle(.secondary)
            }
        } else if !detail.segments.isEmpty {
            Button {
                regenerate(language: Locale.current.language.languageCode?.identifier ?? "en")
            } label: {
                Label("Generate summary", systemImage: "sparkles")
            }
        }
    }

    @ViewBuilder
    private func transcriptSection(_ detail: MeetingDetail) -> some View {
        HStack {
            Text("Transcript").font(.headline)
            if player != nil {
                Spacer()
                Text("Click a line to jump there")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        if let player {
            MeetingPlayerBar(player: player, waveform: waveform)
            compressRow
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

    @ViewBuilder
    private var compressRow: some View {
        if canCompressAudio || compressing || compressMessage != nil {
            HStack(spacing: 8) {
                Button(action: compressAudio) {
                    if compressing {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Compressing…")
                        }
                    } else {
                        Label("Compress audio (AAC)", systemImage: "arrow.down.circle")
                    }
                }
                .controlSize(.small)
                .disabled(!canCompressAudio)
                .help("Converts audio to AAC to save disk space, with no audible loss for speech")
                if let compressMessage {
                    Text(compressMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
    }

    @ViewBuilder
    private func refineButton(_ detail: MeetingDetail) -> some View {
        Button {
            refine(detail)
        } label: {
            if refining != nil {
                ProgressView().controlSize(.small)
            } else {
                Label("Refine", systemImage: "wand.and.stars")
            }
        }
        .disabled(refining != nil || detail.meeting.audioDirectory == nil)
        .help(
            // One-line UI help text.
            // swiftlint:disable:next line_length
            "Re-transcribe with Whisper (maximum quality) and present the result as a draft — nothing is applied without your confirmation"
        )
    }

    private func exportMenu(_ detail: MeetingDetail) -> some View {
        Menu {
            Button("Export Markdown…") { export(detail, as: .markdown) }
            Button("Export PDF…") { export(detail, as: .pdf) }
            Divider()
            Button("Publish as Gist…") { showGistConfirm = true }
        } label: {
            Label("Export", systemImage: "square.and.arrow.up")
        }
    }

    private var deleteButton: some View {
        Button(role: .destructive) {
            Task {
                try? await services.store.delete(meetingID)
                services.libraryVersion += 1
                route = nil
            }
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    @ViewBuilder
    private var refineSheet: some View {
        if let draft = refineDraft {
            refineReviewSheet(draft)
        }
    }

    @ViewBuilder
    private func gistConfirmButtons(_ detail: MeetingDetail) -> some View {
        Button("Publish secret gist") { Task { await publishGist(detail) } }
        Button("Cancel", role: .cancel) {}
    }

    @ViewBuilder
    private var gistPublishedButtons: some View {
        Button("Copy link") {
            if let url = gistResult {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.absoluteString, forType: .string)
            }
        }
        Button("Open") {
            if let url = gistResult { NSWorkspace.shared.open(url) }
        }
        Button("OK", role: .cancel) {}
    }

    @ViewBuilder
    private func renameMeetingButtons(_ detail: MeetingDetail) -> some View {
        TextField("Title", text: $newTitle)
        Button("Save") {
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
        Button("Cancel", role: .cancel) {}
    }

    @ViewBuilder
    private var renameSpeakerButtons: some View {
        TextField("Name", text: $newName)
        Button("Save") {
            // Capture NOW: dismissing the alert nils renamingSpeaker
            // before the task runs, which silently dropped the rename.
            if let speaker = renamingSpeaker {
                let name = newName
                Task { await rename(speaker, to: name) }
            }
        }
        Button("Cancel", role: .cancel) {}
    }

    private var refineDraftBinding: Binding<Bool> {
        Binding(get: { refineDraft != nil }, set: { if !$0 { refineDraft = nil } })
    }

    private var exportBinding: Binding<Bool> {
        Binding(get: { exportDocument != nil }, set: { if !$0 { exportDocument = nil } })
    }

    private var gistResultBinding: Binding<Bool> {
        Binding(get: { gistResult != nil }, set: { if !$0 { gistResult = nil } })
    }

    private var summaryNoticeBinding: Binding<Bool> {
        Binding(get: { summaryNotice != nil }, set: { if !$0 { summaryNotice = nil } })
    }

    private var gistErrorBinding: Binding<Bool> {
        Binding(get: { gistError != nil }, set: { if !$0 { gistError = nil } })
    }

    private var renameBinding: Binding<Bool> {
        Binding(
            get: { renamingSpeaker != nil },
            set: { if !$0 { renamingSpeaker = nil } }
        )
    }
}

// MARK: - Header, speakers & name suggestions

extension MeetingDetailView {
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
                .help("Rename the meeting")
                if let suggestion = suggestedTitle {
                    Button {
                        suggestedTitle = nil
                        Task {
                            var meeting = detail.meeting
                            meeting.title = suggestion
                            try? await services.store.save(meeting)
                            services.libraryVersion += 1
                        }
                    } label: {
                        Label("“\(suggestion)”?", systemImage: "sparkles")
                            .font(.caption)
                    }
                    .controlSize(.small)
                    .help("Suggested title from the summary — one click renames, nothing changes on its own")
                }
            }
            HStack(spacing: 12) {
                Text(detail.meeting.startedAt.formatted(date: .long, time: .shortened))
                if let ended = detail.meeting.endedAt {
                    let minutes = Int(ended.timeIntervalSince(detail.meeting.startedAt) / 60)
                    Text("\(minutes) min")
                }
                Text("\(detail.segments.count) segments")
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
                        Label("Suggest names", systemImage: "sparkles")
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
                    Text("\(suggestion.label) → \(suggestion.name)?")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.14), in: Capsule())
                }
                .buttonStyle(.plain)
                .help("Evidence: \(suggestion.evidence)")
            }
        }
    }

    private func suggestNames(_ detail: MeetingDetail) async {
        guard #available(macOS 26.0, *) else {
            gistError = L10n.text("Name suggestions require macOS 26.")
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
                gistError = L10n.text(
                    "The transcript does not prove any names — you can rename the pills manually.")
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
}

// MARK: - Summary, export & regenerate

extension MeetingDetailView {
    private func summarySection(_ summary: (draft: SummaryDraft, version: Int)) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Summary")
                    .font(.headline)
                Text(summaryBadge(summary))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                recipeSuggestionChip(summary)
                Menu {
                    Button("Copy as plain text") { copySummary(summary.draft, as: .plainText) }
                    Button("Copy as Markdown") { copySummary(summary.draft, as: .markdown) }
                    Button("Copy for Slack") { copySummary(summary.draft, as: .slack) }
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Copy the summary to the clipboard")
                if regenerating {
                    ProgressView().controlSize(.small)
                } else {
                    Menu {
                        Button("Regenerate in Spanish") { regenerate(language: "es") }
                        Button("Regenerate in English") { regenerate(language: "en") }
                        Menu("Structure") {
                            ForEach(Recipe.all) { recipe in
                                Button(recipe.displayName) {
                                    regenerate(language: summary.draft.language, recipe: recipe)
                                }
                            }
                        }
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
        case .ollama, .mlx:
            if services.appleSummaryAvailable {
                return (.appleOnDevice, "Regenerar con Apple (on-device)")
            }
            return nil
        }
    }

    private func regenerate(
        language: String,
        engine: AppServices.SummaryEngine? = nil,
        recipe: Recipe? = nil
    ) {
        guard let detail, !regenerating else { return }
        regenerating = true
        // No explicit recipe keeps whatever structure the summary already
        // has — regenerating in another language must not lose a Standup.
        let activeRecipe =
            recipe ?? summary.flatMap { Recipe.byID($0.draft.recipeID) } ?? .general
        Task {
            defer { regenerating = false }
            let notes = (try? await services.store.contextItems(for: meetingID)) ?? []
            let request = SummaryRequest(
                meetingID: meetingID,
                segments: detail.segments,
                speakers: detail.speakers,
                recipe: activeRecipe,
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
                    gistError = L10n.text("The local model could not generate the summary.")
                }
                return
            }

            guard #available(macOS 26.0, *) else {
                gistError = L10n.text("On-device summaries require macOS 26 (or choose Ollama in Settings).")
                return
            }
            if let reason = FoundationModelSummaryProvider.unavailabilityReason() {
                gistError = reason
                return
            }
            let provider = FoundationModelSummaryProvider()
            let fingerprint = SummaryFingerprint.compute(
                request: request, providerID: FoundationModelSummaryProvider.providerID)

            // D25 cache: same material + same stored language — with greedy
            // decoding the model would reproduce the same result.
            if let hit = try? await services.store.latestSummary(
                meetingID, fingerprint: fingerprint, language: language) {
                summaryNotice =
                    // One-line UI notice.
                    // swiftlint:disable:next line_length
                    L10n.format("Summary v%d already matches this material — there is nothing to regenerate. Change the transcript, notes, or vocabulary to produce a new one.", hit.version)
                return
            }
            // D25 pivot: same material in another language → translating that
            // snapshot costs a fraction of summarizing the transcript again.
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
}

// MARK: - Refine (D7 quality re-pass)

extension MeetingDetailView {
    /// The D7 quality re-pass, in-app: re-transcribes both channels with
    /// Whisper (with the user's vocabulary), re-diarizes (micro-cluster
    /// merge included), atomically replaces the cast, and regenerates the
    /// summary from the clean transcript.
    private func refine(_ detail: MeetingDetail) {
        guard refining == nil else { return }
        refining = L10n.text("Preparing…")
        refineError = nil
        Task {
            defer { refining = nil }
            do {
                guard let relative = detail.meeting.audioDirectory else {
                    refineError = L10n.text("This meeting does not keep its audio.")
                    return
                }
                let base = RecordingsLocation.shared.resolve(relative)
                let systemURL = MeetingAudioLayout.channelFile(named: "system", in: base)
                let microphoneURL = MeetingAudioLayout.channelFile(named: "microphone", in: base)
                guard systemURL != nil || microphoneURL != nil else {
                    refineError = L10n.text("Could not find the meeting audio.")
                    return
                }

                let whisper = try await services.loadWhisperIfNeeded { status in
                    refining = status
                }
                try await services.loadEnginesIfNeeded()

                let vocabulary = VocabularyPrompt.parse(
                    UserDefaults.standard.string(forKey: "customVocabulary") ?? "")
                let hints = refineTranscriptionHints(for: detail, vocabulary: vocabulary)

                var segments: [TranscriptSegment] = []
                if let systemURL {
                    refining = L10n.text("Re-transcribing participants (Whisper)…")
                    let result = try await whisper.transcribeFile(
                        at: systemURL, hints: hints, channel: .system)
                    segments.append(contentsOf: result.segments)
                }
                if let microphoneURL {
                    refining = L10n.text("Re-transcribing your channel (Whisper)…")
                    let result = try await whisper.transcribeFile(
                        at: microphoneURL, hints: hints, channel: .microphone)
                    segments.append(contentsOf: result.segments)
                }
                segments.sort { $0.startTime < $1.startTime }

                var turns: [SpeakerTurn] = []
                if let systemURL, let diarizer = services.diarizer {
                    refining = L10n.text("Identifying speakers…")
                    turns = (try? await diarizer.diarizeFile(at: systemURL)) ?? []
                }
                let attribution = SpeakerAttributor.attribute(
                    segments: segments, turns: turns, meetingID: meetingID)

                // Draft, never override: the user compares and decides.
                let oldSpeech = detail.segments.reduce(0) { $0 + ($1.endTime - $1.startTime) }
                refineDraft = RefineDraft(
                    language: hints.language,
                    speakers: attribution.speakers,
                    segments: attribution.segments,
                    oldSegmentCount: detail.segments.count,
                    oldSpeakerCount: detail.speakers.count,
                    oldSpeechSeconds: oldSpeech)
            } catch {
                refineError = L10n.format("Refine failed: %@", error.localizedDescription)
            }
        }
    }

    private func refineTranscriptionHints(
        for detail: MeetingDetail,
        vocabulary: [String]
    ) -> TranscriptionHints {
        let spokenLanguage = SpokenLanguageDetector.transcriptionLanguageHint(
            for: detail.meeting,
            segments: detail.segments)
        return TranscriptionHints(
            language: spokenLanguage,
            vocabulary: vocabulary,
            meetingID: meetingID)
    }

    private func applyRefineDraft(_ draft: RefineDraft) {
        refineDraft = nil
        refining = L10n.text("Applying the refined transcript…")
        Task {
            defer { refining = nil }
            do {
                if let language = draft.language, var meeting = detail?.meeting {
                    meeting.language = language
                    try await services.store.save(meeting)
                }
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
                refineError = L10n.format("Could not apply refine: %@", error.localizedDescription)
            }
        }
    }

    private func refineReviewSheet(_ draft: RefineDraft) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Review the refined transcript", systemImage: "wand.and.stars")
                .font(.title3.weight(.semibold))

            if draft.looksLossy {
                Label(
                    // One-line UI text.
                    // swiftlint:disable:next line_length
                    "The refine covers much less speech than the current transcript — it probably failed. Do not apply it.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .foregroundStyle(.red)
            }

            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 6) {
                GridRow {
                    Text("").font(.caption)
                    Text("Current").font(.caption.weight(.semibold))
                    Text("Refined").font(.caption.weight(.semibold))
                }
                GridRow {
                    Text("Segments").foregroundStyle(.secondary)
                    Text("\(draft.oldSegmentCount)")
                    Text("\(draft.segments.count)")
                }
                GridRow {
                    Text("Speakers").foregroundStyle(.secondary)
                    Text("\(draft.oldSpeakerCount)")
                    Text("\(draft.speakers.count)")
                }
                GridRow {
                    Text("Covered speech").foregroundStyle(.secondary)
                    Text(minutes(draft.oldSpeechSeconds))
                    Text(minutes(draft.newSpeechSeconds))
                }
            }

            Text("Sample").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
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
                Button("Discard", role: .cancel) { refineDraft = nil }
                Button("Apply") { applyRefineDraft(draft) }
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
}

// MARK: - Gist, rename, playback & lifecycle

extension MeetingDetailView {
    private func publishGist(_ detail: MeetingDetail) async {
        guard
            let token = try? SecretStore.get(service: SecretStore.gitHubTokenService),
            !token.isEmpty
        else {
            gistError = L10n.text("Configure your GitHub token in Settings (⌘,) first.")
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

    private func rename(_ speaker: Speaker, to name: String) async {
        var renamed = speaker
        renamed.displayName = name.isEmpty ? nil : name
        do {
            try await services.store.save([renamed])
        } catch {
            refineError = L10n.format("Could not rename: %@", error.localizedDescription)
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
        await suggestRecipeIfUseful()
        await suggestTitleIfUseful()
    }

    /// Content-based title chip: only while the title still looks like the
    /// template output (starts with a digit — "2026-07-09 09.33 Meeting");
    /// a title the user already wrote is never second-guessed.
    private func suggestTitleIfUseful() async {
        guard !suggestedTitleOnce,
            let detail, let summary,
            detail.meeting.title.first?.isNumber == true
        else { return }
        suggestedTitleOnce = true
        guard #available(macOS 26.0, *),
            FoundationModelSummaryProvider.unavailabilityReason() == nil
        else { return }
        suggestedTitle = await TitleSuggester.suggest(
            summaryMarkdown: summary.draft.markdown,
            currentTitle: detail.meeting.title)
    }

    /// "Summarize as Standup?" chip source (M13b): classify the meeting
    /// type once per visit, only while the summary still has the general
    /// structure, on the scheduler's background lane.
    private func suggestRecipeIfUseful() async {
        guard !detectedRecipeOnce,
            let detail, !detail.segments.isEmpty,
            let summary, summary.draft.recipeID == Recipe.general.id
        else { return }
        detectedRecipeOnce = true
        guard #available(macOS 26.0, *),
            FoundationModelSummaryProvider.unavailabilityReason() == nil
        else { return }
        suggestedRecipe = await MeetingTypeDetector.detect(
            segments: detail.segments, speakerCount: detail.speakers.count)
    }

    /// "Summarize as Standup?" — the typed-recipe suggestion (M13b). One
    /// click regenerates with that structure; dismissable by regenerating
    /// any other way. Never applied on its own.
    @ViewBuilder
    private func recipeSuggestionChip(
        _ summary: (draft: SummaryDraft, version: Int)
    ) -> some View {
        if let suggested = suggestedRecipe, !regenerating {
            Button {
                suggestedRecipe = nil
                regenerate(language: summary.draft.language, recipe: suggested)
            } label: {
                Label(
                    L10n.format("Summarize as %@?", suggested.displayName),
                    systemImage: "sparkles")
            }
            .controlSize(.small)
            .help("This meeting looks like a \(suggested.displayName) — restructure the summary with one click. Nothing changes unless you accept.")
        }
    }

    /// "v3 · en" plus the structure when it is not the default one.
    private func summaryBadge(_ summary: (draft: SummaryDraft, version: Int)) -> String {
        var badge = "v\(summary.version) · \(summary.draft.language)"
        if summary.draft.recipeID != Recipe.general.id,
            let recipe = Recipe.byID(summary.draft.recipeID) {
            badge += " · \(recipe.displayName)"
        }
        return badge
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
            let freed = ByteCountFormatter.string(fromByteCount: saved, countStyle: .file)
            compressMessage = L10n.format("Audio compressed — %@ freed.", freed)
        }
    }

    private func timestamp(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
