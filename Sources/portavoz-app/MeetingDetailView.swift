import AppKit
import AudioPlaybackKit
import DiarizationKit
import IntegrationsKit
import IntelligenceKit
import ModelStoreKit
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
    /// The live Companion's answer cards, persisted (D26) so the meeting can
    /// be reviewed afterward. Loaded lazily; empty hides the rail section.
    @State private var companionCards: [CompanionCard] = []
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
    /// Refine state lives in RefineService (keyed by meeting) so the work
    /// and its draft survive navigating away from this view.
    private var refinePhase: RefineService.Phase? { services.refines.phase(for: meetingID) }
    private var refining: String? {
        if case .running(let status) = refinePhase { return status } else { return nil }
    }
    private var refineError: String? {
        if case .failed(let message) = refinePhase { return message } else { return nil }
    }
    private var refineDraft: RefineDraft? {
        if case .draft(let draft) = refinePhase { return draft } else { return nil }
    }
    /// Applying a draft (and other row actions) stays view-local: it is a
    /// short DB write, not a long re-pass.
    @State private var applying: String?
    @State private var actionError: String?
    @State private var editingTitle = false
    @State private var newTitle = ""
    /// Typed-recipe suggestion (M13b): detected once per visit, offered as
    /// a chip — never applied on its own.
    @State private var suggestedRecipe: Recipe?
    @State private var detectedRecipeOnce = false
    /// Presents the "New structure…" sheet from the Structure menu.
    @State private var showingNewStructure = false
    /// Content-based title suggestion — same contract: chip, click, never solo.
    @State private var suggestedTitle: String?
    @State private var suggestedTitleOnce = false
    /// Which summary tab is showing (0 = overview · 1…N = `##` sections ·
    /// 1000 = action items).
    @State private var summaryTabSelection = 0
    /// Cross-meeting voice matches (D8/D21): computed once per visit when
    /// the gallery has voices and unnamed speakers exist — chips only.
    @State private var voiceSuggestions: [VoiceMatcher.Match] = []
    @State private var voiceMatchedOnce = false
    /// After the user confirms a name (rename or chip), offer — never do —
    /// remembering that speaker's voice for future meetings.
    @State private var rememberOffer: Speaker?
    @State private var rememberingVoice = false

    /// The post-meeting mirror (6a-2): opt-in, shown once right after a
    /// qualifying recording. `mirrorAverageShare` is the user's usual talk
    /// share across recent meetings, loaded lazily so the card can compare.
    @AppStorage("mirrorAfterMeeting") private var mirrorAfterMeeting = false
    @State private var mirrorAverageShare: Double?
    @State private var mirrorAverageLoadedFor: MeetingID?

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
            // No `.navigationTitle`: the meeting title already lives in the
            // header below, and showing it in the window bar too read as a
            // duplicate. The window bar keeps the app's own title.
            .navigationTitle("Portavoz")
            .sheet(isPresented: refineDraftBinding) { refineSheet }
            .sheet(isPresented: mirrorBinding(detail)) { mirrorSheet(detail) }
            .task(id: mirrorTaskID) { await loadMirrorAverageIfNeeded() }
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
            .sheet(isPresented: $editingTitle) {
                renameSheet(detail)
            }
            .sheet(isPresented: $showingNewStructure) {
                CustomStructureSheet(existing: nil) { recipe in
                    CustomRecipeStore.upsert(recipe)
                    regenerate(language: summary?.draft.language ?? "en", recipe: recipe)
                }
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
        // A fixed-height composition (NOT one big page scroll): header and
        // summary sit at the top, the transcript fills the middle and scrolls
        // in its own viewport, and the player is DOCKED at the bottom — so you
        // never scroll the page to reach the player, and reading the
        // transcript never moves it. The health + chapters rail sits alongside.
        VStack(alignment: .leading, spacing: 12) {
            header(detail)
            speakersRow(detail)
            refineStatus
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 10) {
                    summaryOrGenerate(detail)
                    transcriptHeader
                    transcriptArea(detail)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    playerDock
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                detailRail(detail)
            }
            .frame(maxHeight: .infinity)
        }
        .padding(16)
        .frame(maxWidth: 1060, maxHeight: .infinity, alignment: .topLeading)
    }

    private var transcriptHeader: some View {
        HStack {
            Text("Transcript").font(.headline)
            if player != nil {
                Spacer()
                Text("Click a line to jump there")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    /// The transcript body: a self-centering lyrics carousel when there's
    /// audio (sized to fill the space above the docked player), or a plain
    /// scrolling list otherwise.
    @ViewBuilder
    private func transcriptArea(_ detail: MeetingDetail) -> some View {
        if player != nil {
            GeometryReader { geometry in
                transcriptLines(detail, carouselHeight: max(180, geometry.size.height))
            }
        } else {
            ScrollView { transcriptLines(detail, carouselHeight: 440) }
        }
    }

    private func transcriptLines(_ detail: MeetingDetail, carouselHeight: CGFloat) -> some View {
        // Own View struct so only it re-renders as the playhead moves — the
        // header and summary above stay put.
        TranscriptSegmentsView(
            segments: detail.segments,
            speakers: detail.speakers,
            player: player,
            onSeek: { player?.seek(to: $0); player?.play() },
            onRenameTap: { speaker in
                renamingSpeaker = speaker
                newName = speaker.displayName ?? ""
            },
            carouselHeight: carouselHeight)
    }

    /// The audio player, docked at the bottom of the transcript column so it
    /// stays put while you read.
    @ViewBuilder
    private var playerDock: some View {
        if let player {
            Divider()
            MeetingPlayerBar(player: player, waveform: waveform)
            compressRow
        }
    }

    /// The right rail: meeting health + ✦ chapters — the at-a-glance column
    /// beside the transcript. Hidden entirely when it would be empty (no
    /// attributed speech and no chapters) so the page doesn't carry a void.
    @ViewBuilder
    private func detailRail(_ detail: MeetingDetail) -> some View {
        let hasChapters = !ChapterExtractor.chapters(from: detail.segments).isEmpty
        let hasHealth = detail.segments.contains { $0.speakerID != nil }
        if hasHealth || hasChapters || !companionCards.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                if hasHealth {
                    MeetingHealthView(speakers: detail.speakers, segments: detail.segments)
                }
                chaptersSection(detail)
                companionCardsSection
            }
            .frame(width: 260)
        }
    }

    @ViewBuilder
    private var refineStatus: some View {
        if let progress = refining ?? applying {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(progress).foregroundStyle(.secondary)
            }
        }
        if let message = refineError ?? actionError {
            Text(message).font(.caption).foregroundStyle(.red)
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
    /// The .portavoz interchange file (M15 L0): transcript + cast +
    /// latest summary + notes — and optionally the recording itself
    /// (compress first via "Compress audio (AAC)" for a mail-sized file).
    private func exportBundle(_ detail: MeetingDetail, includeAudio: Bool) async {
        let notes = (try? await services.store.contextItems(for: meetingID)) ?? []
        var audio: [MeetingBundle.AudioAttachment]?
        if includeAudio, let relative = detail.meeting.audioDirectory {
            let base = RecordingsLocation.shared.resolve(relative)
            let attachments = ["system", "microphone"].compactMap { name -> MeetingBundle.AudioAttachment? in
                guard let url = MeetingAudioLayout.channelFile(named: name, in: base),
                    let data = try? Data(contentsOf: url)
                else { return nil }
                return MeetingBundle.AudioAttachment(
                    name: name, fileExtension: url.pathExtension, data: data)
            }
            audio = attachments.isEmpty ? nil : attachments
        }
        let bundle = MeetingBundle(
            meeting: detail.meeting,
            speakers: detail.speakers,
            segments: detail.segments,
            summary: summary?.draft,
            contextItems: notes,
            audioFiles: audio)
        guard let data = try? bundle.encoded() else {
            gistError = L10n.text("Could not encode the meeting file.")
            return
        }
        exportType = .meetingBundle
        exportName = "\(detail.meeting.title).portavoz"
        exportDocument = ExportDocument(data: data)
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
    /// A compact rename sheet — opens pre-filled with the current title,
    /// selected, so you can type over it or edit. (Replaces the old `.alert`,
    /// whose text field went blank on the second open.)
    private func renameSheet(_ detail: MeetingDetail) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Rename meeting").font(.headline)
            AutoSelectTextField(text: $newTitle, onSubmit: { commitRename(detail) })
                .frame(width: 340, height: 22)
            HStack {
                Spacer()
                Button("Cancel") { editingTitle = false }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { commitRename(detail) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private func commitRename(_ detail: MeetingDetail) {
        let title = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        editingTitle = false
        guard !title.isEmpty else { return }
        var meeting = detail.meeting
        Task {
            meeting.title = title
            try? await services.store.save(meeting)
            await reload()
            services.libraryVersion += 1
        }
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
        Binding(
            get: { refineDraft != nil },
            set: { if !$0 { services.refines.clear(meetingID) } })
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
                        ChipLabel(kind: .ai, text: "“\(suggestion)”?")
                    }
                    .buttonStyle(.plain)
                    .help("Suggested title from the summary — one click renames, nothing changes on its own")
                }
                Spacer(minLength: 0)
            }
            actionRow(detail)
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

    /// The meeting's actions as a row of round buttons under the title
    /// (design system: refine · export · delete live with the meeting, not
    /// in the window toolbar). Export is tinted the accent; delete is
    /// destructive red.
    private func actionRow(_ detail: MeetingDetail) -> some View {
        HStack(spacing: 8) {
            refineMenu(detail)

            Menu {
                Button("Export Markdown…") { export(detail, as: .markdown) }
                Button("Export PDF…") { export(detail, as: .pdf) }
                Button("Export meeting file (.portavoz)…") {
                    Task { await exportBundle(detail, includeAudio: false) }
                }
                Button("Export meeting file with audio…") {
                    Task { await exportBundle(detail, includeAudio: true) }
                }
                Divider()
                Button("Publish as Gist…") { showGistConfirm = true }
            } label: {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 13))
                    .foregroundStyle(PVDesign.accent)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(PVDesign.accent.opacity(0.16)))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(L10n.text("Export or share this meeting"))

            roundButton(
                systemImage: "trash", tint: .red, role: .destructive,
                help: "Move this meeting to Recently deleted"
            ) {
                Task {
                    try? await services.store.delete(meetingID)
                    services.libraryVersion += 1
                    route = nil
                }
            }
        }
    }

    /// One circular icon action, matching the DS's under-title button row.
    @ViewBuilder
    private func roundButton(
        systemImage: String, tint: Color, role: ButtonRole? = nil,
        busy: Bool = false, disabled: Bool = false, help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(role: role, action: action) {
            Group {
                if busy {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: systemImage).font(.system(size: 13))
                }
            }
            .foregroundStyle(tint)
            .frame(width: 30, height: 30)
            .background(Circle().fill(.quaternary.opacity(0.5)))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(help)
    }

    /// The meeting's cast, with the M6 "1-tap speaker→name" flow: ✦
    /// proposes names the transcript proves; one click applies them.
    @ViewBuilder
    private func speakersRow(_ detail: MeetingDetail) -> some View {
        let unnamed = detail.speakers.filter { !$0.isMe && $0.displayName == nil }
        HStack(spacing: 8) {
            ForEach(detail.speakers) { speaker in
                SpeakerPill(speaker: speaker, cast: detail.speakers) { speaker in
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
                    .foregroundStyle(PVDesign.accent)
                }
            }
            ForEach(nameSuggestions, id: \.label) { suggestion in
                Button {
                    Task { await apply(suggestion, in: detail) }
                } label: {
                    ChipLabel(kind: .ai, text: "\(suggestion.label) → \(suggestion.name)?")
                }
                .buttonStyle(.plain)
                .help("Evidence: \(suggestion.evidence)")
            }
            // Cross-meeting voice matches: same chip contract, waveform icon
            // marks the evidence as "their voice", not the transcript.
            ForEach(voiceSuggestions, id: \.voiceLabel) { match in
                Button {
                    Task { await apply(match, in: detail) }
                } label: {
                    ChipLabel(kind: .voice, text: "\(match.voiceLabel) → \(match.name)?")
                }
                .buttonStyle(.plain)
                .help(L10n.format(
                    "Voice match: sounds like “%@” from your remembered voices.", match.name))
            }
            rememberOfferChip
        }
    }

    /// The explicit-consent gesture (D8): after the user names a speaker,
    /// offer to remember that voice — never remember it silently.
    @ViewBuilder
    private var rememberOfferChip: some View {
        if let offer = rememberOffer, let name = offer.displayName {
            if rememberingVoice {
                ProgressView().controlSize(.small)
            } else {
                HStack(spacing: 6) {
                    Label(
                        L10n.format("Remember %@’s voice?", name),
                        systemImage: "person.wave.2")
                    .font(.caption)
                    .foregroundStyle(PVDesign.chipOfferInk)
                    Button(L10n.text("Remember")) {
                        Task { await rememberVoice(of: offer) }
                    }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(PVDesign.accent)
                    Button {
                        rememberOffer = nil
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption2)
                            .foregroundStyle(PVDesign.chipOfferInk)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L10n.text("Dismiss voice offer"))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(PVDesign.chipOfferBg, in: Capsule())
                .help(L10n.text(
                    // One-line UI help text.
                    // swiftlint:disable:next line_length
                    "Stores only an encrypted numeric fingerprint of their voice on this Mac — never the audio, never synced — so future meetings can suggest their name. Removable in Settings."))
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
        offerToRemember(speaker)
    }

    // MARK: Cross-meeting voices (D8/D21)

    private func apply(_ match: VoiceMatcher.Match, in detail: MeetingDetail) async {
        guard var speaker = detail.speakers.first(where: { $0.label == match.voiceLabel }) else {
            return
        }
        speaker.displayName = match.name
        try? await services.store.save([speaker])
        voiceSuggestions.removeAll { $0.voiceLabel == match.voiceLabel }
        services.libraryVersion += 1
    }

    /// Offers the remember-this-voice chip after a name was confirmed by a
    /// user gesture. Skipped for "Me" (that's the enrollment in Settings)
    /// and for names already in the gallery (their voice is remembered).
    private func offerToRemember(_ speaker: Speaker) {
        guard !speaker.isMe, let name = speaker.displayName, !name.isEmpty else {
            rememberOffer = nil
            return
        }
        let remembered = (try? VoiceGallery().voices()) ?? []
        guard !remembered.contains(where: {
            $0.name.compare(name, options: .caseInsensitive) == .orderedSame
        }) else {
            rememberOffer = nil
            return
        }
        rememberOffer = speaker
    }

    private func rememberVoice(of speaker: Speaker) async {
        guard let detail, let name = speaker.displayName else { return }
        rememberingVoice = true
        defer {
            rememberingVoice = false
            rememberOffer = nil
        }
        let prints = await extractVoiceprints(detail, speakers: [speaker])
        guard let voiceprint = prints[speaker.label] else {
            gistError = L10n.text(
                "Not enough clear audio from that voice to remember it (about 5 seconds are needed).")
            return
        }
        do {
            try VoiceGallery().remember(
                RememberedVoice(name: name, embedding: voiceprint.embedding))
        } catch {
            gistError = L10n.format("Could not remember the voice: %@", error.localizedDescription)
        }
    }

    /// Voice-based name chips, computed once per visit: only when the user
    /// has remembered voices, unnamed speakers exist, and the meeting keeps
    /// its system audio. Uses a throwaway diarizer (~14 MB models; the
    /// heavy recording engines are NOT loaded for this).
    private func suggestFromVoicesIfUseful() async {
        guard !voiceMatchedOnce, let detail else { return }
        let unnamed = detail.speakers.filter { !$0.isMe && $0.displayName == nil }
        guard !unnamed.isEmpty else { return }
        guard let gallery = try? VoiceGallery().voices(), !gallery.isEmpty else { return }
        voiceMatchedOnce = true
        let prints = await extractVoiceprints(detail, speakers: unnamed)
        guard !prints.isEmpty else { return }
        voiceSuggestions = VoiceMatcher.matches(
            speakers: prints.map { ($0.key, $0.value.embedding) },
            gallery: gallery)
    }

    /// One embedding per requested speaker from their system-channel spans.
    /// Embeddings are transient: nothing is persisted here (persisting is
    /// the explicit "Remember" gesture only).
    private func extractVoiceprints(
        _ detail: MeetingDetail, speakers: [Speaker]
    ) async -> [String: Voiceprint] {
        guard let relative = detail.meeting.audioDirectory else { return [:] }
        let base = RecordingsLocation.shared.resolve(relative)
        guard let systemURL = MeetingAudioLayout.channelFile(named: "system", in: base) else {
            return [:]
        }
        var ranges: [String: [ClosedRange<TimeInterval>]] = [:]
        for speaker in speakers {
            let spans = detail.segments
                .filter {
                    $0.speakerID == speaker.id && $0.channel == .system
                        && $0.endTime > $0.startTime
                }
                .map { $0.startTime...$0.endTime }
            if !spans.isEmpty { ranges[speaker.label] = spans }
        }
        guard !ranges.isEmpty,
            let diarizer = try? await PyannoteDiarizer.loadRecommended(store: ModelStore())
        else { return [:] }
        return (try? await diarizer.extractVoiceprints(
            fromFile: systemURL, rangesBySpeaker: ranges)) ?? [:]
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
                thinSummaryChip(summary)
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
                            ForEach(CustomRecipeStore.all()) { recipe in
                                Button(recipe.displayName) {
                                    regenerate(language: summary.draft.language, recipe: recipe)
                                }
                            }
                            Divider()
                            Button("New structure…") { showingNewStructure = true }
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
            summaryTabs(summary)
            summaryTabContent(summary)
        }
        .padding(14)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }

    /// The tab strip (design system): Resumen · each `##` section (with its
    /// bullet count) · Pendientes (done/total). Parsed from the Markdown so
    /// it works in any language.
    @ViewBuilder
    private func summaryTabs(_ summary: (draft: SummaryDraft, version: Int)) -> some View {
        let parsed = SummarySections.parse(summary.draft.markdown)
        let done = summary.draft.actionItems.filter(\.isDone).count
        let total = summary.draft.actionItems.count
        HStack(spacing: 6) {
            summaryTab(L10n.text("Summary"), tag: 0)
            ForEach(Array(parsed.sections.enumerated()), id: \.offset) { index, section in
                summaryTab("\(section.heading) · \(section.bulletCount)", tag: index + 1)
            }
            if total > 0 {
                summaryTab(L10n.format("To-dos · %d/%d", done, total), tag: 1000)
            }
        }
    }

    private func summaryTab(_ label: String, tag: Int) -> some View {
        let on = summaryTabSelection == tag
        return Button {
            summaryTabSelection = tag
        } label: {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(on ? Color.white : .secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background {
                    if on {
                        Capsule().fill(PVDesign.accent)
                    } else {
                        Capsule().fill(.quaternary.opacity(0.6))
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(tag == 1000 ? "summary-tab-todos" : "summary-tab-\(tag)")
    }

    @ViewBuilder
    private func summaryTabContent(_ summary: (draft: SummaryDraft, version: Int)) -> some View {
        let parsed = SummarySections.parse(summary.draft.markdown)
        if summaryTabSelection == 1000 {
            ForEach(summary.draft.actionItems) { item in
                Toggle(isOn: actionBinding(item)) {
                    Text(item.text).strikethrough(item.isDone)
                }
                .toggleStyle(.checkbox)
            }
        } else if summaryTabSelection >= 1, summaryTabSelection - 1 < parsed.sections.count {
            MarkdownText(text: parsed.sections[summaryTabSelection - 1].body)
        } else {
            MarkdownText(text: parsed.intro.isEmpty ? summary.draft.markdown : parsed.intro)
        }
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
            recipe ?? summary.flatMap { CustomRecipeStore.byID($0.draft.recipeID) } ?? .general
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
    /// The refine control: a normal click re-transcribes auto-detecting the
    /// language (or honoring the Settings pin); the chevron offers a per-meeting
    /// language override, the fix for a meeting whose transcript came out in
    /// the wrong language on weak audio.
    private func refineMenu(_ detail: MeetingDetail) -> some View {
        let disabled = refining != nil || detail.meeting.audioDirectory == nil
        return Menu {
            Button("Re-transcribe in Spanish") { refine(detail, language: "es") }
            Button("Re-transcribe in English") { refine(detail, language: "en") }
        } label: {
            Group {
                if refining != nil {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "wand.and.stars").font(.system(size: 13))
                }
            }
            .foregroundStyle(.secondary)
            .frame(width: 30, height: 30)
            .background(Circle().fill(.quaternary.opacity(0.5)))
        } primaryAction: {
            refine(detail)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(disabled)
        .accessibilityIdentifier("detail-refine")
        .help(
            L10n.text(
                // swiftlint:disable:next line_length
                "Re-transcribe with Whisper (maximum quality) and present the result as a draft — nothing is applied without your confirmation. Use the menu to force a language."
            ))
    }

    private func refine(_ detail: MeetingDetail, language: String? = nil) {
        services.refines.start(
            meetingID: meetingID, detail: detail, services: services, language: language)
    }

    private func applyRefineDraft(_ draft: RefineDraft) {
        services.refines.clear(meetingID)
        applying = L10n.text("Applying the refined transcript…")
        Task {
            defer { applying = nil }
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
                actionError = L10n.format("Could not apply refine: %@", error.localizedDescription)
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
                Button("Discard", role: .cancel) { services.refines.clear(meetingID) }
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
            actionError = L10n.format("Could not rename: %@", error.localizedDescription)
            return
        }
        renamingSpeaker = nil
        await reload()
        services.libraryVersion += 1
        offerToRemember(renamed)
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

    // MARK: - Post-meeting mirror (6a-2)

    /// The meeting's duration, preferring wall-clock (start→end) and falling
    /// back to attributed speech when the meeting has no recorded end.
    private func mirrorDuration(_ detail: MeetingDetail, health: MeetingHealth) -> TimeInterval {
        if let ended = detail.meeting.endedAt {
            return ended.timeIntervalSince(detail.meeting.startedAt)
        }
        return health.totalSpeechSeconds
    }

    /// The user's own stat for this meeting, matched by the `isMe` speaker.
    private func mirrorMyStat(
        _ detail: MeetingDetail, health: MeetingHealth
    ) -> MeetingHealth.SpeakerStat? {
        guard let me = detail.speakers.first(where: \.isMe) else { return nil }
        return health.stats.first { $0.speakerID == me.id }
    }

    /// The mirror shows once, right after a qualifying recording, and only
    /// when the user opted in. Everything is local and gated on real signal.
    private func mirrorShouldShow(_ detail: MeetingDetail) -> Bool {
        guard mirrorAfterMeeting, services.justRecorded == meetingID else { return false }
        let health = MeetingHealth.compute(segments: detail.segments)
        guard mirrorMyStat(detail, health: health) != nil else { return false }
        return MirrorStats.qualifies(
            speakerCount: health.stats.count,
            seconds: mirrorDuration(detail, health: health))
    }

    private func mirrorBinding(_ detail: MeetingDetail) -> Binding<Bool> {
        Binding(
            get: { mirrorShouldShow(detail) },
            set: { if !$0 { services.justRecorded = nil } })
    }

    /// Recompute the comparison average whenever a fresh recording arrives.
    private var mirrorTaskID: MeetingID? { services.justRecorded }

    private func loadMirrorAverageIfNeeded() async {
        guard mirrorAfterMeeting, services.justRecorded == meetingID,
            mirrorAverageLoadedFor != meetingID
        else { return }
        mirrorAverageLoadedFor = meetingID
        mirrorAverageShare = await services.averageMyShare(excluding: meetingID)
    }

    @ViewBuilder
    private func mirrorSheet(_ detail: MeetingDetail) -> some View {
        let health = MeetingHealth.compute(segments: detail.segments)
        if let mine = mirrorMyStat(detail, health: health) {
            MirrorCard(
                myShare: mine.share,
                myQuestions: mine.questions,
                myInterruptions: mine.interruptionsMade,
                language: Locale.current.language.languageCode?.identifier ?? "en",
                averageShare: mirrorAverageShare,
                onSeeTrend: {
                    services.justRecorded = nil
                    route = .insights
                },
                onDismiss: { services.justRecorded = nil },
                onTurnOff: {
                    mirrorAfterMeeting = false
                    services.justRecorded = nil
                })
        }
    }

    private func reload() async {
        detail = try? await services.store.detail(meetingID)
        companionCards = (try? await services.store.companionCards(for: meetingID)) ?? []
        summary = try? await services.store.summary(meetingID)
        await loadPlayerIfNeeded()
        // A palette citation navigated here: jump to the cited moment.
        if let seek = services.pendingSeek {
            services.pendingSeek = nil
            player?.seek(to: seek)
        }
        await suggestRecipeIfUseful()
        await suggestTitleIfUseful()
        await suggestFromVoicesIfUseful()
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
                ChipLabel(
                    kind: .ai,
                    text: L10n.format("Summarize as %@?", suggested.displayName))
            }
            .buttonStyle(.plain)
            .help("This meeting looks like a \(suggested.displayName) — restructure the summary with one click. Nothing changes unless you accept.")
        }
    }

    /// "Summary looks thin" — a long meeting whose summary collapsed
    /// (field case: 56 min → 530 chars, 0 action items from the 3B). One
    /// click regenerates with the embedded engine, which handled the same
    /// meeting well. Deterministic gate; only offered when MLX is ready
    /// and was NOT the engine that produced this summary.
    @ViewBuilder
    private func thinSummaryChip(
        _ summary: (draft: SummaryDraft, version: Int)
    ) -> some View {
        if !regenerating,
            services.summaryEngine != .mlx,
            services.mlxDownloaded,
            let detail,
            let ended = detail.meeting.endedAt,
            ThinSummaryPolicy.isThin(
                summaryCharacters: summary.draft.markdown.count,
                actionItems: summary.draft.actionItems.count,
                meetingSeconds: ended.timeIntervalSince(detail.meeting.startedAt)) {
            Button {
                regenerate(language: summary.draft.language, engine: .mlx)
            } label: {
                Label("Summary looks thin — retry with Built-in?", systemImage: "sparkles")
            }
            .controlSize(.small)
            .help(
                // One-line UI help text.
                // swiftlint:disable:next line_length
                "This meeting is long but its summary came out very small. Regenerate with the embedded model — nothing changes unless you click.")
        }
    }

    /// "v3 · en" plus the structure when it is not the default one.
    private func summaryBadge(_ summary: (draft: SummaryDraft, version: Int)) -> String {
        var badge = "v\(summary.version) · \(summary.draft.language)"
        if summary.draft.recipeID != Recipe.general.id,
            let recipe = CustomRecipeStore.byID(summary.draft.recipeID) {
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
        // "Solo mi voz": skip everything that isn't the user's mic turns.
        if let player, let detail {
            let voiceRanges = detail.segments
                .filter { $0.channel == .microphone && $0.endTime > $0.startTime }
                .map { $0.startTime...$0.endTime }
            player.setNonVoiceRanges(
                PlaybackRanges.complement(of: voiceRanges, within: player.duration))
        }
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

    /// ✦ Chapters (design system): break points the app finds locally in
    /// the transcript — a long pause or a topic that has run long — each
    /// labeled with a real opening line and seeking the player on tap.
    /// Shown only when the meeting actually breaks into more than one.
    @ViewBuilder
    private func chaptersSection(_ detail: MeetingDetail) -> some View {
        let chapters = ChapterExtractor.chapters(from: detail.segments)
        if !chapters.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Label("Chapters", systemImage: "sparkles")
                    .font(.headline)
                    .foregroundStyle(PVDesign.accent)
                    .accessibilityIdentifier("detail-chapters")
                ForEach(chapters) { chapter in
                    Button {
                        player?.seek(to: chapter.startTime)
                        player?.play()
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(timestamp(chapter.startTime))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(PVDesign.accent)
                                .frame(width: 44, alignment: .leading)
                            Text(chapter.title)
                                .font(.callout)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(player == nil)
                    .padding(.vertical, 3)
                    .accessibilityIdentifier("chapter-\(Int(chapter.startTime))")
                    .help(player == nil
                        ? L10n.text("Chapters jump the player — this meeting has no audio.")
                        : L10n.text("Jump to this moment"))
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    /// The live Companion's answers, kept for review (D26): each card seeks
    /// the player to the moment the question was asked, and can be copied or
    /// removed. Hidden when the meeting had none.
    @ViewBuilder
    private var companionCardsSection: some View {
        if !companionCards.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Label("Companion", systemImage: "sparkles")
                    .font(.headline)
                    .foregroundStyle(PVDesign.accent)
                    .accessibilityIdentifier("detail-companion")
                ForEach(companionCards) { card in
                    companionCardRow(card)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private func companionCardRow(_ card: CompanionCard) -> some View {
        let tint: Color = card.directed ? .orange : PVDesign.accent
        return VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Button {
                    player?.seek(to: card.askedAt)
                    player?.play()
                } label: {
                    Text(timestamp(card.askedAt))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(tint)
                }
                .buttonStyle(.plain)
                .disabled(player == nil)
                Text(card.question)
                    .font(.callout.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !card.answer.isEmpty {
                Text(card.answer)
                    .font(.callout)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Text(companionCardTag(card))
                    .font(.caption2)
                    .foregroundStyle(card.directed ? tint : Color.secondary)
                Spacer()
                if !card.answer.isEmpty {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(card.answer, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.plain)
                    .controlSize(.small)
                    .help(L10n.text("Copy answer"))
                }
                Button {
                    Task { await removeCompanionCard(card.id) }
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .controlSize(.small)
                .accessibilityLabel(L10n.text("Remove card"))
                .help(L10n.text("Remove card"))
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8).strokeBorder(tint.opacity(0.25), lineWidth: 1)
        )
        .accessibilityIdentifier("companion-card-\(Int(card.askedAt))")
    }

    private func companionCardTag(_ card: CompanionCard) -> String {
        let base = card.kind == .context
            ? L10n.text("from this meeting")
            : L10n.format("knowledge · %@", card.source)
        if card.directed {
            return card.answer.isEmpty ? L10n.text("asked you") : "\(L10n.text("asked you")) · \(base)"
        }
        return base
    }

    private func removeCompanionCard(_ id: UUID) async {
        // Drop from the UI only after the tombstone lands — a failed delete
        // leaves the card in place instead of stranding a phantom removal.
        do {
            try await services.store.deleteCompanionCard(id)
            companionCards.removeAll { $0.id == id }
        } catch {
            actionError = L10n.text("Could not remove the card.")
        }
    }
}
