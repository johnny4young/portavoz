import AppKit
import ApplicationKit
import IntegrationsKit
import IntelligenceKit
import PortavozCore
import SwiftUI
import TranscriptionKit
import UniformTypeIdentifiers

// Meeting Detail composition and the remaining secondary flows. Focused
// header, trust, generated-document, transcript, and player types live in
// their own files; this type body is split across
// `extension MeetingDetailView` blocks below. The file stays above the
// file_length threshold because splitting the rest would expose ~24 private
// `@State` properties to the whole module — an encapsulation cost not worth
// paying for line-count only.
// swiftlint:disable file_length

private struct PersonRememberOffer {
    let speaker: Speaker
    let source: PersonAliasSource
}

/// Transcript with editable speaker pills (the M3 leftover), the latest
/// summary snapshot, and its checkable action items.
struct MeetingDetailView: View {
    let meetingID: MeetingID
    @Binding var route: Route?
    let model: MeetingDetailModel
    let presentation: MeetingDetailPresentation
    let sceneValues: MeetingDetailSceneValues
    let sceneActions: MeetingDetailSceneActions

    private var detail: MeetingReviewReadModel? { model.state.readModel }
    /// The live Companion's answer cards, persisted (D26) so the meeting can
    /// be reviewed afterward. Empty hides the rail section.
    private var companionCards: [CompanionCard] { detail?.companionCards ?? [] }
    private var summary: MeetingReviewSummary? { detail?.summary }
    private var player: MeetingPlaybackSession? { model.state.playback?.session }
    private var waveform: [MeetingWaveformBucket] {
        model.state.playback?.waveform ?? []
    }
    private var playbackTaskID: String? { detail?.meeting.audioDirectory }
    @State private var renamingSpeaker: Speaker?
    @State private var newName = ""
    @State private var exportDocument: ExportDocument?
    @State private var exportType: UTType = .plainText
    @State private var exportName = "reunion"
    @State private var regenerating = false
    @State private var showGistConfirm = false
    @State private var showingRecap = false
    @State private var gistResult: URL?
    @State private var gistError: String?
    @State private var summaryNotice: String?
    @State private var summarySetupIssue: SummarySetupIssue?
    @State private var enhancingNotes = false
    @State private var notesNotice: String?
    /// Refine state lives in RefineService (keyed by meeting) so the work
    /// and its draft survive navigating away from this view.
    private var refinePhase: RefineService.Phase? { sceneValues.refinePhase }
    private var refining: String? {
        if case .running(let status) = refinePhase { return status } else { return nil }
    }
    private var refineError: String? {
        if case .failed(let message) = refinePhase { return message } else { return nil }
    }
    private var refineDraft: RefineDraft? {
        if case .draft(let draft) = refinePhase { return draft } else { return nil }
    }
    /// Applying a draft stays view-local as presentation state while the
    /// atomic mutation and optional Companion refresh cross ApplicationKit.
    @State private var applying: String?
    @State private var actionError: String?
    @State private var editingTitle = false
    @State private var newTitle = ""
    /// Presents the "New structure…" sheet from the Structure menu.
    @State private var showingNewStructure = false
    /// After the user confirms a name (rename or chip), offer — never do —
    /// remembering that speaker's voice for future meetings.
    @State private var rememberOffer: Speaker?
    @State private var rememberingVoice = false
    /// Canonical people are a separate explicit-consent path from encrypted
    /// voice memory. Alias matches only open a chooser; they never auto-link.
    @State private var personOffer: PersonRememberOffer?
    @State private var personCandidates: [Person] = []
    @State private var choosingPerson: PersonRememberOffer?
    @State private var findingPerson = false
    /// Cross-section evidence and external-seek navigation stays a small value.
    /// It can map accepted evidence into a future correction-composed row and
    /// retains a seek while a long waveform is still preparing.
    @State private var transcriptNavigation = MeetingTranscriptNavigationState()
    /// Disposable Instruments automation runs once per detail instance. It is
    /// inert unless both the temp-store and performance-profile flags exist.
    @State private var didRunPerformanceSeek = false

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
        .task { await model.observe() }
        .task(id: playbackTaskID) { await refreshPlayback() }
        .task(id: model.state.revision) { await refreshPresentation() }
        .onChange(of: sceneValues.pendingSeek) { _, _ in
            consumePendingMeetingSeekIfMatching()
        }
        .onDisappear { model.invalidatePlayback() }
    }

    /// The loaded detail: the scrolling content plus the toolbar, sheet, and
    /// the stack of exporter/confirmation/alert modifiers. The branchy pieces
    /// live in the extracted subviews and computed bindings below so this
    /// stays a flat composition.
    private func loaded(_ detail: MeetingReviewReadModel) -> some View {
        loadedAlertsAndEditors(detail)
    }

    private func loadedSheetsAndDialogs(_ detail: MeetingReviewReadModel) -> some View {
        loadedBody(detail).onAppear { model.firstContentDidAppear() }
            // No `.navigationTitle`: the meeting title already lives in the
            // header below, and showing it in the window bar too read as a
            // duplicate. The window bar keeps the app's own title.
            .navigationTitle("Portavoz")
            .sheet(isPresented: refineDraftBinding) { refineSheet }
            .sheet(isPresented: mirrorBinding(detail)) { mirrorSheet(detail) }
            .sheet(isPresented: $showingRecap) { recapSheet(detail) }
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
            .confirmationDialog(
                Text(L10n.format(
                    "Who is %@?",
                    choosingPerson?.speaker.displayName ?? "")),
                isPresented: personChoiceBinding,
                titleVisibility: .visible
            ) {
                personChoiceButtons
            } message: {
                Text(L10n.text(
                    // One-line UI explanation.
                    // swiftlint:disable:next line_length
                    "Choose an existing person or keep this as a separate person. Portavoz never merges people automatically."))
            }
    }

    private func loadedAlertsAndEditors(_ detail: MeetingReviewReadModel) -> some View {
        loadedSheetsAndDialogs(detail)
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
            .alert("Summary needs setup", isPresented: summarySetupBinding) {
                Button("Open Intelligence Settings") {
                    sceneActions.openSettings(.intelligence)
                }
                .accessibilityIdentifier("detail-summary-open-settings")
                Button("Not now", role: .cancel) {}
                    .accessibilityIdentifier("detail-summary-not-now")
            } message: {
                Text(summarySetupIssue?.message ?? "")
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
                    regenerate(language: summaryLanguage(summary?.draft.language), recipe: recipe)
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
    private func loadedBody(_ detail: MeetingReviewReadModel) -> some View {
        let transcript = transcriptContent(detail)
        // A fixed-height composition (NOT one big page scroll): header and
        // summary sit at the top, the transcript fills the middle and scrolls
        // in its own viewport, and the player is DOCKED at the bottom — so you
        // never scroll the page to reach the player, and reading the
        // transcript never moves it. The health + chapters rail sits alongside.
        return VStack(alignment: .leading, spacing: 12) {
            headerSection(detail)
            MeetingDetailOperationStatus(
                progress: refining ?? applying,
                error: refineError ?? actionError ?? model.state.lastActionError)
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 10) {
                    summaryOrGenerate(detail)
                    notesSection(detail)
                    MeetingTranscriptSection(
                        values: MeetingTranscriptValues(
                            content: transcript,
                            speakers: detail.speakers,
                            player: player,
                            focusedRowID: transcriptNavigation.focusedRowID,
                            performanceScrollEnabled: sceneValues.performanceProfile
                                .shouldExerciseTranscriptScroll),
                        actions: MeetingTranscriptActions(
                            seekAndPlay: seekAndPlay,
                            renameSpeaker: { speaker in
                                renamingSpeaker = speaker
                                newName = speaker.displayName ?? ""
                            }))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    playerDock
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                detailRail(detail, transcript: transcript)
            }
            .frame(maxHeight: .infinity)
        }
        .padding(16)
        .frame(maxWidth: 1060, maxHeight: .infinity, alignment: .topLeading)
    }

    private func transcriptContent(
        _ detail: MeetingReviewReadModel
    ) -> MeetingTranscriptContent {
        .accepted(
            baseTranscriptRevision: detail.meeting.transcriptRevision,
            segments: detail.segments,
            chapterTitles: model.state.chapterTitles)
    }

    /// The audio player, docked at the bottom of the transcript column so it
    /// stays put while you read.
    @ViewBuilder
    private var playerDock: some View {
        if let player {
            Divider()
            MeetingPlayerBar(
                player: player,
                waveform: waveform,
                exportClip: { range, destination in
                    let effect = await model.send(.exportAudioClip(range, to: destination))
                    guard case .operationFailed(let message) = effect else { return nil }
                    return message
                })
            compressRow
        }
    }

    /// The right rail: processing recovery + privacy receipt + meeting health + ✦ chapters +
    /// the Companion's answers —
    /// the at-a-glance column beside the transcript. Hidden entirely when it
    /// would be empty. SCROLLS on its own so a long Companion list (many
    /// cards) never grows the page and pushes the header or docked player
    /// off-screen — the rail stays within its column, everything else stays put.
    @ViewBuilder
    private func detailRail(
        _ detail: MeetingReviewReadModel,
        transcript: MeetingTranscriptContent
    ) -> some View {
        let hasChapters = !transcript.chapters.isEmpty
        let hasHealth = detail.segments.contains { $0.speakerID != nil }
        let hasProcessingState = detail.meeting.lifecycleState == .needsAttention
            || detail.processingJobs.contains {
                $0.state == .pending || $0.state == .running || $0.state == .failed
            }
        if hasProcessingState || detail.privacyReceipt != nil
            || hasHealth || hasChapters || !companionCards.isEmpty {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if hasProcessingState || detail.privacyReceipt != nil {
                        MeetingDetailTrustSection(
                            values: MeetingDetailTrustValues(
                                lifecycleState: detail.meeting.lifecycleState,
                                processingJobs: detail.processingJobs,
                                hasSavedAudio: detail.meeting.audioDirectory != nil,
                                lastProcessingError: detail.meeting.lastProcessingError,
                                privacyReceipt: detail.privacyReceipt,
                                presentation: presentation),
                            actions: MeetingDetailTrustActions(
                                retryProcessing: {
                                    await model.send(.retryProcessing)
                                },
                                refineSavedAudio: { refine(detail) },
                                openSupportDiagnostics: {
                                    sceneActions.openSettings(.data)
                                }))
                    }
                    if hasHealth {
                        MeetingHealthView(speakers: detail.speakers, segments: detail.segments)
                    }
                    MeetingTranscriptChaptersSection(
                        chapters: transcript.chapters,
                        hasPlayback: player != nil,
                        presentation: presentation,
                        seekAndPlay: seekAndPlay)
                    companionCardsSection
                }
            }
            .frame(width: 260)
            .frame(maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func summaryOrGenerate(_ detail: MeetingReviewReadModel) -> some View {
        if let summary {
            generatedDocumentSection(summary, detail: detail)
        } else if regenerating {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Generating summary…").foregroundStyle(.secondary)
            }
        } else if !detail.segments.isEmpty {
            Button {
                regenerate(language: summaryLanguage())
            } label: {
                Label("Generate summary", systemImage: "sparkles")
            }
            .accessibilityIdentifier("detail-generate-summary")
        }
    }

    @ViewBuilder
    private var compressRow: some View {
        if canCompressAudio
            || model.state.isCompressingAudio
            || model.state.audioCompressionMessage != nil {
            HStack(spacing: 8) {
                Button(action: compressAudio) {
                    if model.state.isCompressingAudio {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Compressing…")
                        }
                    } else {
                        Label("Compress audio (AAC)", systemImage: "arrow.down.circle")
                    }
                }
                .controlSize(.small)
                .accessibilityIdentifier("detail-compress-audio")
                .disabled(!canCompressAudio)
                .help("Converts audio to AAC to save disk space, with no audible loss for speech")
                if let compressMessage = model.state.audioCompressionMessage {
                    Text(compressMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
    }

    /// The .portavoz interchange file (M15 L0): transcript + cast +
    /// latest summary + notes — and optionally the recording itself
    /// (compress first via "Compress audio (AAC)" for a mail-sized file).
    private func exportBundle(_ detail: MeetingReviewReadModel, includeAudio: Bool) async {
        guard let data = try? await sceneActions.exportBundle(includeAudio)
        else {
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
    private func gistConfirmButtons(_ detail: MeetingReviewReadModel) -> some View {
        Button("Publish secret gist") { Task { await publishGist() } }
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
    private func renameSheet(_ detail: MeetingReviewReadModel) -> some View {
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

    private func commitRename(_ detail: MeetingReviewReadModel) {
        let title = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        editingTitle = false
        guard !title.isEmpty else { return }
        Task {
            await model.send(.renameMeeting(detail.meeting, title: title))
        }
    }

    @ViewBuilder
    private var renameSpeakerButtons: some View {
        TextField("Name", text: $newName)
            .accessibilityIdentifier("speaker-name-field")
        Button("Save") {
            // Capture NOW: dismissing the alert nils renamingSpeaker
            // before the task runs, which silently dropped the rename.
            if let speaker = renamingSpeaker {
                let name = newName
                Task { await rename(speaker, to: name) }
            }
        }
        .accessibilityIdentifier("speaker-rename-save")
        Button("Cancel", role: .cancel) {}
    }

    private var refineDraftBinding: Binding<Bool> {
        Binding(
            get: { refineDraft != nil },
            set: { if !$0 { sceneActions.clearRefine() } })
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

    private var summarySetupBinding: Binding<Bool> {
        Binding(
            get: { summarySetupIssue != nil },
            set: { if !$0 { summarySetupIssue = nil } })
    }

    private var renameBinding: Binding<Bool> {
        Binding(
            get: { renamingSpeaker != nil },
            set: { if !$0 { renamingSpeaker = nil } }
        )
    }

    private var personChoiceBinding: Binding<Bool> {
        Binding(
            get: { choosingPerson != nil && !personCandidates.isEmpty },
            set: { presented in
                if !presented {
                    choosingPerson = nil
                    personCandidates = []
                }
            })
    }

    @ViewBuilder
    private var personChoiceButtons: some View {
        if let offer = choosingPerson {
            ForEach(Array(personCandidates.enumerated()), id: \.element.id) { index, person in
                Button(personCandidateLabel(person, index: index)) {
                    Task {
                        await linkPerson(offer, selection: .existing(person.id))
                    }
                }
                .accessibilityIdentifier("person-link-existing-\(index)")
            }
            Button(L10n.text("Create a separate person")) {
                Task { await linkPerson(offer, selection: .createDistinct) }
            }
            .accessibilityIdentifier("person-create-distinct")
        }
        Button(L10n.text("Cancel"), role: .cancel) {}
            .accessibilityIdentifier("person-link-cancel")
    }

    private func personCandidateLabel(_ person: Person, index: Int) -> String {
        if personCandidates.count == 1 {
            return L10n.format("Use %@", person.preferredName)
        }
        return L10n.format(
            "Use %@ (person %d)",
            person.preferredName,
            index + 1)
    }
}

// MARK: - Header, speakers & name suggestions

extension MeetingDetailView {
    private func headerSection(_ detail: MeetingReviewReadModel) -> some View {
        MeetingDetailHeaderSection(
            values: MeetingDetailHeaderValues(
                title: detail.meeting.title,
                date: presentation.meetingDate(detail.meeting.startedAt),
                duration: presentation.meetingDuration(
                    startedAt: detail.meeting.startedAt,
                    endedAt: detail.meeting.endedAt),
                segmentCount: presentation.segmentCount(detail.segments.count),
                titleSuggestion: model.state.suggestedTitle,
                speakers: detail.speakers,
                isSuggestingNames: model.state.isSuggestingNames,
                nameSuggestions: model.state.nameSuggestions,
                voiceSuggestions: model.state.voiceSuggestions,
                personOffer: personOffer.flatMap { offer in
                    offer.speaker.displayName.map {
                        MeetingDetailRememberOffer(name: $0, isBusy: findingPerson)
                    }
                },
                voiceOffer: rememberOffer.flatMap { offer in
                    offer.displayName.map {
                        MeetingDetailRememberOffer(name: $0, isBusy: rememberingVoice)
                    }
                }),
            actions: MeetingDetailHeaderActions(
                renameMeeting: {
                    newTitle = detail.meeting.title
                    editingTitle = true
                },
                acceptTitleSuggestion: { suggestion in
                    Task {
                        await model.send(
                            .renameMeeting(detail.meeting, title: suggestion))
                    }
                },
                dismissTitleSuggestion: model.dismissSuggestedTitle,
                renameSpeaker: { speaker in
                    renamingSpeaker = speaker
                    newName = speaker.displayName ?? ""
                },
                suggestNames: { Task { await suggestNames() } },
                acceptNameSuggestion: { suggestion in
                    Task { await apply(suggestion, in: detail) }
                },
                dismissNameSuggestion: model.dismissNameSuggestion,
                acceptVoiceSuggestion: { suggestion in
                    Task { await apply(suggestion, in: detail) }
                },
                dismissVoiceSuggestion: model.dismissVoiceSuggestion,
                acceptPersonOffer: {
                    guard let offer = personOffer else { return }
                    Task { await findOrCreatePerson(for: offer) }
                },
                dismissPersonOffer: { personOffer = nil },
                acceptVoiceOffer: {
                    guard let offer = rememberOffer else { return }
                    Task { await rememberVoice(of: offer) }
                },
                dismissVoiceOffer: { rememberOffer = nil }),
            actionContent: { actionRow(detail) })
    }

    /// The meeting's actions as a row of round buttons under the title
    /// (design system: refine · export · delete live with the meeting, not
    /// in the window toolbar). Export is tinted the accent; delete is
    /// destructive red.
    private func actionRow(_ detail: MeetingReviewReadModel) -> some View {
        HStack(spacing: 8) {
            refineMenu(detail)

            Menu {
                // First: the thing you actually do after a meeting. The raw
                // formats below are for archiving, not for telling people
                // what happened.
                Button("Share a recap…") { showingRecap = true }
                    .accessibilityIdentifier("detail-share-recap")
                    .disabled(summary == nil)
                Divider()
                Button("Export Markdown…") { export(as: .markdown) }
                Button("Export PDF…") { export(as: .pdf) }
                Button("Export subtitles (SRT)…") { export(as: .srt) }
                .accessibilityIdentifier("detail-export-srt")
                Button("Export subtitles (VTT)…") { export(as: .vtt) }
                .accessibilityIdentifier("detail-export-vtt")
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
            .accessibilityIdentifier("detail-export-menu")
            .help(L10n.text("Export or share this meeting"))

            roundButton(
                systemImage: "trash", tint: .red, role: .destructive,
                help: "Move this meeting to Recently deleted"
            ) {
                Task {
                    if case .meetingDeleted = await model.send(.deleteMeeting) {
                        route = nil
                    }
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

    private func suggestNames() async {
        if case .operationFailed(let message) = await model.send(.loadNameSuggestions) {
            gistError = message
        }
    }

    private func apply(
        _ suggestion: MeetingNameSuggestion,
        in detail: MeetingReviewReadModel
    ) async {
        guard let speaker = detail.speakers.first(where: { $0.label == suggestion.label }) else {
            return
        }
        let effect = await model.send(
            .acceptNameSuggestion(speaker, name: suggestion.name))
        switch effect {
        case .nameSuggestionAccepted(let renamed):
            let source: PersonAliasSource = switch suggestion.evidence {
            case .transcript: .transcriptSuggestion
            case .calendarCandidate: .calendarSuggestion
            }
            offerToRememberPerson(renamed, source: source)
            await offerToRememberVoice(renamed)
        case .operationFailed(let message):
            gistError = message
        default:
            break
        }
    }

    // MARK: Cross-meeting voices (D8/D21)

    private func apply(_ match: MeetingVoiceSuggestion, in detail: MeetingReviewReadModel) async {
        guard let speaker = detail.speakers.first(where: { $0.label == match.speakerLabel }) else {
            return
        }
        let effect = await model.send(
            .acceptVoiceSuggestion(speaker, name: match.name))
        switch effect {
        case .voiceSuggestionAccepted(let renamed):
            offerToRememberPerson(renamed, source: .voiceSuggestion)
        case .operationFailed(let message):
            gistError = message
        default:
            break
        }
    }

    private func offerToRememberPerson(_ speaker: Speaker, source: PersonAliasSource) {
        guard !speaker.isMe,
              speaker.personID == nil,
              let name = speaker.displayName,
              !name.isEmpty
        else {
            personOffer = nil
            return
        }
        personOffer = PersonRememberOffer(speaker: speaker, source: source)
    }

    private func findOrCreatePerson(for offer: PersonRememberOffer) async {
        findingPerson = true
        defer { findingPerson = false }
        let effect = await model.send(
            .findCanonicalPeople(offer.speaker, source: offer.source))
        guard case .canonicalPeopleFound(_, _, let people) = effect else { return }
        if people.isEmpty {
            await linkPerson(offer, selection: .createDistinct)
        } else {
            personCandidates = people
            choosingPerson = offer
        }
    }

    private func linkPerson(
        _ offer: PersonRememberOffer,
        selection: CanonicalPersonSelection
    ) async {
        let effect = await model.send(
            .linkCanonicalPerson(
                offer.speaker,
                source: offer.source,
                selection: selection))
        guard case .canonicalPersonLinked = effect else { return }
        personOffer = nil
        choosingPerson = nil
        personCandidates = []
    }

    /// Offers the remember-this-voice chip after a name was confirmed by a
    /// user gesture. Skipped for "Me" (that's the enrollment in Settings)
    /// and for names already in the gallery (their voice is remembered).
    private func offerToRememberVoice(_ speaker: Speaker) async {
        guard !speaker.isMe, let name = speaker.displayName, !name.isEmpty else {
            rememberOffer = nil
            return
        }
        let effect = await model.send(.checkVoiceMemoryOffer(name: name))
        guard case .voiceMemoryOfferChecked(true) = effect else {
            rememberOffer = nil
            return
        }
        rememberOffer = speaker
    }

    private func rememberVoice(of speaker: Speaker) async {
        guard detail != nil, speaker.displayName?.isEmpty == false else { return }
        rememberingVoice = true
        defer {
            rememberingVoice = false
            rememberOffer = nil
        }
        let effect = await model.send(.rememberVoice(speaker.id))
        switch effect {
        case .voiceMemoryInsufficientAudio:
            gistError = L10n.text(
                "Not enough clear audio from that voice to remember it (about 5 seconds are needed).")
        case .operationFailed(let message):
            gistError = message
        default:
            break
        }
    }

    /// Voice-based name chips, computed once per visit: only when the user
    /// has remembered voices, unnamed speakers exist, and the meeting keeps
    /// its system audio. Uses a throwaway diarizer (~14 MB models; the
    /// heavy recording engines are NOT loaded for this).
    private func loadVoiceSuggestions() async {
        await model.send(.loadVoiceSuggestions)
    }
}

// MARK: - Summary, export & regenerate

extension MeetingDetailView {
    private func generatedDocumentSection(
        _ summary: MeetingReviewSummary,
        detail: MeetingReviewReadModel
    ) -> some View {
        MeetingGeneratedDocumentSection(
            values: MeetingGeneratedDocumentValues(
                summary: summary,
                transcriptRevision: detail.meeting.transcriptRevision,
                segments: detail.segments,
                recipes: CustomRecipeStore.all(),
                summaryLanguage: summaryLanguage(summary.draft.language),
                suggestedRecipe: model.state.suggestedRecipe,
                showThinSuggestion: shouldSuggestThinSummary(summary, detail: detail),
                regenerating: regenerating,
                alternateEngine: alternateEngine.map {
                    MeetingGeneratedDocumentAlternateEngine(
                        engine: $0.engine,
                        label: $0.label)
                },
                presentation: presentation),
            actions: MeetingGeneratedDocumentActions(
                copy: { format in
                    switch format {
                    case .plainText:
                        copySummary(summary.draft, as: .plainText)
                    case .markdown:
                        copySummary(summary.draft, as: .markdown)
                    case .slack:
                        copySummary(summary.draft, as: .slack)
                    }
                },
                regenerate: { language, engine, recipe in
                    regenerate(language: language, engine: engine, recipe: recipe)
                },
                createStructure: { showingNewStructure = true },
                dismissRecipeSuggestion: model.dismissSuggestedRecipe,
                dismissThinSuggestion: {
                    model.dismissThinSummarySuggestion(version: summary.version)
                },
                setActionItem: { item, done in
                    Task {
                        await model.send(.setActionItem(item.id, done: done))
                    }
                },
                focusEvidence: focusEvidence,
                setClaimFeedback: { claimID, feedback in
                    let effect = await model.send(
                        .setSummaryClaimFeedback(claimID, feedback))
                    guard case .summaryClaimFeedbackSaved(let savedID) = effect else {
                        return false
                    }
                    return savedID == claimID
                }))
    }

    private func shouldSuggestThinSummary(
        _ summary: MeetingReviewSummary,
        detail: MeetingReviewReadModel
    ) -> Bool {
        guard !regenerating,
              sceneValues.summaryEngine != .mlx,
              sceneValues.mlxDownloaded,
              model.state.dismissedThinSummaryVersion != summary.version,
              let ended = detail.meeting.endedAt
        else { return false }
        return ThinSummaryPolicy.isThin(
            summaryCharacters: summary.draft.markdown.count,
            actionItems: summary.draft.actionItems.count,
            meetingSeconds: ended.timeIntervalSince(detail.meeting.startedAt))
    }

    private func focusEvidence(_ segment: TranscriptSegment) {
        guard let detail else { return }
        transcriptNavigation.reveal(
            sourceSegmentID: segment.id,
            at: segment.startTime,
            in: transcriptContent(detail))
        applyPendingEvidenceSeekIfPossible()
    }

    private func applyPendingEvidenceSeekIfPossible() {
        guard let player,
              let seconds = transcriptNavigation.consumePendingSeek()
        else { return }
        player.seek(to: seconds)
    }

    private enum ExportFormat { case markdown, pdf, srt, vtt }

    private func export(as format: ExportFormat) {
        Task {
            let documentFormat: MeetingDocumentFormat = switch format {
            case .markdown: .markdown
            case .pdf: .pdf
            case .srt: .srt
            case .vtt: .vtt
            }
            let effect = await model.send(.prepareDocument(documentFormat))
            switch effect {
            case .documentPrepared(let document):
                switch format {
                case .markdown:
                    exportType = .plainText
                case .pdf:
                    exportType = .pdf
                case .srt:
                    exportType = .portavozSRT
                case .vtt:
                    exportType = .portavozVTT
                }
                exportName = document.filename
                exportDocument = ExportDocument(data: document.data)
            case .operationFailed(let message):
                gistError = message
            default:
                break
            }
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
    private var alternateEngine: (engine: SummaryEngine, label: String)? {
        switch sceneValues.summaryEngine {
        case .appleOnDevice:
            if let model = sceneValues.ollamaModel {
                return (.ollama, "Regenerar con Ollama · \(model)")
            }
            return nil
        case .ollama, .mlx:
            if sceneValues.appleSummaryAvailable {
                return (.appleOnDevice, "Regenerar con Apple (on-device)")
            }
            return nil
        }
    }

    private func summaryLanguage(_ stored: String? = nil) -> LanguageCode {
        LanguageCode(stored)
            ?? MeetingLanguagePreferences.resolvedSummaryLanguage(
                spokenLanguage: detail?.meeting.language)
    }

    private func regenerate(
        language: LanguageCode,
        engine: SummaryEngine? = nil,
        recipe: Recipe? = nil,
        segments: [TranscriptSegment]? = nil,
        speakers: [Speaker]? = nil
    ) {
        guard let detail, !regenerating else { return }
        model.dismissSuggestedRecipe()
        let sourceSegments = segments ?? detail.segments
        let sourceSpeakers = speakers ?? detail.speakers
        regenerating = true
        // No explicit recipe keeps whatever structure the summary already
        // has — regenerating in another language must not lose a Standup.
        let activeRecipe =
            recipe ?? summary.flatMap { CustomRecipeStore.byID($0.draft.recipeID) } ?? .general
        Task {
            defer { regenerating = false }
            let request = RegenerateSummaryRequest(
                meetingID: meetingID,
                segments: sourceSegments,
                speakers: sourceSpeakers,
                recipe: activeRecipe,
                targetLanguage: language.identifier,
                providerOverride: engine)
            let result = await sceneActions.regenerateSummary(request)
            switch result {
            case .completed:
                // Keep Spotlight's released broad invalidation until Band 4
                // replaces it with incremental indexing.
                await model.send(.searchableContentChanged)
            case .unchanged(let version):
                summaryNotice =
                    // One-line UI notice.
                    // swiftlint:disable:next line_length
                    L10n.format("Summary v%d already matches this material — there is nothing to regenerate. Change the transcript, notes, or vocabulary to produce a new one.", version)
            case .unavailable(.requiresMacOS26):
                summarySetupIssue = .appleRequiresMacOS26
            case .unavailable(.appleOnDevice(let reason)):
                summarySetupIssue = .appleUnavailable(reason)
            case .unavailable(.ollamaModelNotSelected):
                summarySetupIssue = .ollamaModelNotSelected
            case .unavailable(.mlxModelNotDownloaded):
                summarySetupIssue = .mlxModelNotDownloaded
            case .generationFailed(.localModelNotice):
                summarySetupIssue = .localEngineFailed
            case .generationFailed(.silent):
                break
            }
        }
    }
}

// MARK: - Enhanced notes (NOTES-001/D135)

extension MeetingDetailView {
    /// The user's own notes: the raw timestamped items until enhanced, then
    /// the one regenerable enhanced document. The raw notes are never
    /// modified — the enhanced doc repeats each note verbatim in bold.
    @ViewBuilder
    private func notesSection(_ detail: MeetingReviewReadModel) -> some View {
        let notes = detail.notes
        if !notes.contextItems.isEmpty || notes.enhanced != nil {
            VStack(alignment: .leading, spacing: 8) {
                notesHeader(detail)
                notesContent(notes)
                if let notesNotice {
                    Text(notesNotice).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(14)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private func notesHeader(_ detail: MeetingReviewReadModel) -> some View {
        HStack {
            Text("My notes")
                .font(.headline)
                .accessibilityIdentifier("detail-notes-title")
            Spacer()
            if enhancingNotes {
                ProgressView().controlSize(.small)
            } else if !detail.segments.isEmpty {
                Menu {
                    Button("Enhance in Spanish") { enhanceNotes(language: .spanish) }
                    Button("Enhance in English") { enhanceNotes(language: .english) }
                    if let alt = alternateEngine {
                        Divider()
                        Menu(alt.label) {
                            Button("Español") {
                                enhanceNotes(language: .spanish, engine: alt.engine)
                            }
                            Button("English") {
                                enhanceNotes(language: .english, engine: alt.engine)
                            }
                        }
                    }
                } label: {
                    Label("Enhance", systemImage: "sparkles")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .accessibilityIdentifier("detail-enhance-notes")
                .help("Expand each note with what the transcript shows around its moment")
            }
        }
    }

    @ViewBuilder
    private func notesContent(_ notes: MeetingReviewNotes) -> some View {
        if let enhanced = notes.enhanced {
            ScrollView {
                MarkdownText(text: enhanced.markdown)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 220)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(notes.contextItems) { item in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(presentation.clock(item.timestamp))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.tertiary)
                            Text(item.content)
                                .font(.callout)
                                .textSelection(.enabled)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 140)
        }
    }

    private func enhanceNotes(language: LanguageCode, engine: SummaryEngine? = nil) {
        guard let detail, !enhancingNotes else { return }
        enhancingNotes = true
        notesNotice = nil
        Task {
            defer { enhancingNotes = false }
            let request = EnhanceMeetingNotesRequest(
                meetingID: meetingID,
                segments: detail.segments,
                speakers: detail.speakers,
                targetLanguage: language.identifier,
                providerOverride: engine)
            applyEnhanceNotesResult(await sceneActions.enhanceNotes(request))
        }
    }

    private func applyEnhanceNotesResult(_ result: EnhanceMeetingNotesResult) {
        switch result {
        case .completed(persisted: true):
            break  // The notes observation refreshes the section.
        case .completed(persisted: false):
            notesNotice = L10n.text("The enhanced notes could not be saved. Try again.")
        case .unchanged:
            // swiftlint:disable:next line_length
            notesNotice = L10n.text("Your enhanced notes already match this material — change the transcript or your notes to produce new ones.")
        case .noNotes:
            notesNotice = L10n.text("Add notes during the recording to enhance them here.")
        case .unavailable(.requiresMacOS26):
            summarySetupIssue = .appleRequiresMacOS26
        case .unavailable(.appleOnDevice(let reason)):
            summarySetupIssue = .appleUnavailable(reason)
        case .unavailable(.ollamaModelNotSelected):
            summarySetupIssue = .ollamaModelNotSelected
        case .unavailable(.mlxModelNotDownloaded):
            summarySetupIssue = .mlxModelNotDownloaded
        case .generationFailed(.localModelNotice):
            summarySetupIssue = .localEngineFailed
        case .generationFailed(.silent):
            // Unlike the summary's silent path, this is a click-driven
            // action: an honest one-liner beats a spinner that just stops.
            notesNotice = L10n.text("Enhancing didn't work this time. Try again in a moment.")
        }
    }
}

// MARK: - Share recap (FEATURE-003/D136)

extension MeetingDetailView {
    /// Reachable only with a summary: the recap is summary-derived, so
    /// without one there is nothing honest to draft.
    @ViewBuilder
    private func recapSheet(_ detail: MeetingReviewReadModel) -> some View {
        if let summary {
            MeetingRecapSheet(
                meeting: detail.meeting,
                speakers: detail.speakers,
                summary: summary.draft,
                dismiss: { showingRecap = false })
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
    @ViewBuilder
    private func refineMenu(_ detail: MeetingReviewReadModel) -> some View {
        let isRefining = refining != nil
        let disabled = !isRefining && detail.meeting.audioDirectory == nil
        if isRefining {
            Button(role: .destructive) {
                sceneActions.cancelRefine()
            } label: {
                refineControlLabel(isRefining: true)
            }
            .buttonStyle(.plain)
            .fixedSize()
            .accessibilityIdentifier("detail-refine")
            .accessibilityValue("cancel")
            .help(L10n.text("Cancel refine"))
        } else {
            Menu {
                Button("Re-transcribe in Spanish") {
                    refine(detail, languagePolicy: .fixed(.spanish))
                }
                Button("Re-transcribe in English") {
                    refine(detail, languagePolicy: .fixed(.english))
                }
            } label: {
                refineControlLabel(isRefining: false)
            } primaryAction: {
                refine(detail)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(disabled)
            .accessibilityIdentifier("detail-refine")
            .accessibilityValue("refine")
            .help(L10n.text(
                // swiftlint:disable:next line_length
                "Re-transcribe with Whisper (maximum quality) and present the result as a draft — nothing is applied without your confirmation. Use the menu to force a language."))
        }
    }

    private func refineControlLabel(isRefining: Bool) -> some View {
        Group {
            if isRefining {
                Image(systemName: "xmark").font(.system(size: 13, weight: .semibold))
            } else {
                Image(systemName: "wand.and.stars").font(.system(size: 13))
            }
        }
        .foregroundStyle(.secondary)
        .frame(width: 30, height: 30)
        .background(Circle().fill(.quaternary.opacity(0.5)))
    }

    private func refine(
        _ detail: MeetingReviewReadModel,
        languagePolicy: TranscriptLanguagePolicy? = nil
    ) {
        sceneActions.startRefine(detail, languagePolicy)
    }

    private func applyRefineDraft(_ draft: RefineDraft) {
        sceneActions.clearRefine()
        applying = L10n.text("Applying the refined transcript…")
        Task {
            defer { applying = nil }
            do {
                let result = try await sceneActions.applyRefine(
                    ApplyRefinedMeetingRequest(
                        meetingID: meetingID,
                        draft: draft
                    ) { phase in
                        if phase == .refreshingCompanion {
                            await MainActor.run {
                                applying = L10n.text(
                                    "Re-checking the Apuntador's answers…")
                            }
                        }
                    })
                if result.companion == .persistenceFailed {
                    actionError = L10n.text(
                        "The transcript was refined, but Apuntador cards could not be refreshed.")
                }
                await model.send(.searchableContentChanged)
                regenerate(
                    language: summaryLanguage(summary?.draft.language),
                    segments: draft.segments,
                    speakers: draft.speakers)
            } catch MeetingDetailRefineApplyError.staleDraft {
                actionError = L10n.text(
                    "The transcript changed while you reviewed this draft. Run refine again.")
            } catch {
                actionError = L10n.format("Could not apply refine: %@", UseCaseErrorMessages.describe(error))
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
                Button("Discard", role: .cancel) { sceneActions.clearRefine() }
                Button("Apply") { applyRefineDraft(draft) }
                    .buttonStyle(.borderedProminent)
                    .disabled(draft.segments.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private func minutes(_ seconds: TimeInterval) -> String {
        presentation.refinedDuration(seconds)
    }
}

// MARK: - Gist, rename, playback & lifecycle

extension MeetingDetailView {
    private func publishGist() async {
        switch await model.send(.publishGist) {
        case .gistPublished(let url):
            gistResult = url
        case .operationFailed(let message):
            gistError = message
        default:
            break
        }
    }

    private func rename(_ speaker: Speaker, to name: String) async {
        let effect = await model.send(.renameSpeaker(speaker, name: name))
        if case .speakerRenamed(let renamed) = effect {
            renamingSpeaker = nil
            offerToRememberPerson(renamed, source: .manualName)
            await offerToRememberVoice(renamed)
        }
    }

    // MARK: - Post-meeting mirror (6a-2)

    /// The meeting's duration, preferring wall-clock (start→end) and falling
    /// back to attributed speech when the meeting has no recorded end.
    private func mirrorDuration(_ detail: MeetingReviewReadModel, health: MeetingHealth) -> TimeInterval {
        if let ended = detail.meeting.endedAt {
            return ended.timeIntervalSince(detail.meeting.startedAt)
        }
        return health.totalSpeechSeconds
    }

    /// The user's own stat for this meeting, matched by the `isMe` speaker.
    private func mirrorMyStat(
        _ detail: MeetingReviewReadModel, health: MeetingHealth
    ) -> MeetingHealth.SpeakerStat? {
        guard let me = detail.speakers.first(where: \.isMe) else { return nil }
        return health.stats.first { $0.speakerID == me.id }
    }

    /// The mirror shows once, right after a qualifying recording, and only
    /// when the user opted in. Everything is local and gated on real signal.
    private func mirrorShouldShow(_ detail: MeetingReviewReadModel) -> Bool {
        guard mirrorAfterMeeting, sceneValues.justRecorded == meetingID else { return false }
        let health = MeetingHealth.compute(segments: detail.segments)
        guard mirrorMyStat(detail, health: health) != nil else { return false }
        return MirrorStats.qualifies(
            speakerCount: health.stats.count,
            seconds: mirrorDuration(detail, health: health))
    }

    private func mirrorBinding(_ detail: MeetingReviewReadModel) -> Binding<Bool> {
        Binding(
            get: { mirrorShouldShow(detail) },
            set: { if !$0 { sceneActions.clearJustRecorded() } })
    }

    /// Recompute the comparison average whenever a fresh recording arrives.
    private var mirrorTaskID: MeetingID? { sceneValues.justRecorded }

    private func loadMirrorAverageIfNeeded() async {
        guard mirrorAfterMeeting, sceneValues.justRecorded == meetingID,
            mirrorAverageLoadedFor != meetingID
        else { return }
        mirrorAverageLoadedFor = meetingID
        mirrorAverageShare = await sceneActions.averageMyShare()
    }

    @ViewBuilder
    private func mirrorSheet(_ detail: MeetingReviewReadModel) -> some View {
        let health = MeetingHealth.compute(segments: detail.segments)
        if let mine = mirrorMyStat(detail, health: health) {
            MirrorCard(
                myShare: mine.share,
                myQuestions: mine.questions,
                myInterruptions: mine.interruptionsMade,
                language: presentation.languageIdentifier,
                averageShare: mirrorAverageShare,
                onSeeTrend: {
                    sceneActions.clearJustRecorded()
                    route = .insights
                },
                onDismiss: sceneActions.clearJustRecorded,
                onTurnOff: {
                    mirrorAfterMeeting = false
                    sceneActions.clearJustRecorded()
                })
        }
    }

    private func refreshPresentation() async {
        guard detail != nil else { return }
        consumePendingMeetingSeekIfMatching()
        await model.send(.loadMetadataSuggestions)
        guard !Task.isCancelled else { return }
        await loadVoiceSuggestions()
    }

    /// Consume only requests for this detail. The explicit observation covers
    /// citations that target an already-open meeting, while refresh covers a
    /// newly constructed destination and requests that arrive before loading.
    private func consumePendingMeetingSeekIfMatching() {
        guard let detail,
              let request = sceneActions.consumePendingSeek()
        else { return }
        transcriptNavigation.requestSeek(
            to: request.timestamp,
            in: transcriptContent(detail))
        applyPendingEvidenceSeekIfPossible()
    }

    /// Audio has its own directory-scoped lifetime. Review sections can emit
    /// several initial revisions; keying this work to those revisions would
    /// cancel the only player build while later revisions merely deduplicate.
    private func refreshPlayback() async {
        guard playbackTaskID != nil else { return }
        await model.send(.loadPlayback)
        guard !Task.isCancelled else { return }
        applyPendingEvidenceSeekIfPossible()
        runPerformanceSeekIfRequested()
    }

    private func runPerformanceSeekIfRequested() {
        guard MeetingDetailPerformanceTrace.isEnabled,
              sceneValues.performanceProfile.shouldExercisePlaybackSeek,
              !didRunPerformanceSeek,
              let player
        else { return }
        didRunPerformanceSeek = true
        Task { @MainActor [player] in
            let fractions: [Double] = [0.2, 0.8, 0.4, 0.6, 0.25]
            for fraction in fractions {
                MeetingDetailPerformanceTrace.measurePlaybackSeek {
                    player.seek(to: player.duration * fraction)
                }
                try? await Task.sleep(for: .milliseconds(300))
            }
        }
    }

    /// True when there's lossless audio (CAF/WAV) still worth compressing.
    private var canCompressAudio: Bool {
        !model.state.isCompressingAudio
            && model.state.playback?.canCompressAudio == true
    }

    /// Sends one user intent; ApplicationKit owns channel resolution,
    /// failure-safe batch compression, and playback reconstruction.
    private func compressAudio() {
        Task {
            _ = await model.send(.compressAudio)
            applyPendingEvidenceSeekIfPossible()
        }
    }

    private func timestamp(_ seconds: TimeInterval) -> String {
        presentation.clock(seconds, paddedMinutes: true)
    }

    private func seekAndPlay(_ seconds: TimeInterval) {
        guard let detail, let player else { return }
        transcriptNavigation.requestSeek(
            to: seconds,
            in: transcriptContent(detail))
        guard let timestamp = transcriptNavigation.consumePendingSeek() else { return }
        player.seek(to: timestamp)
        player.play()
    }

    /// The live Companion's answers, kept for review (D26): each card seeks
    /// the player to the moment the question was asked, and can be copied or
    /// removed. Hidden when the meeting had none.
    @ViewBuilder
    private var companionCardsSection: some View {
        if !companionCards.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Label("Apuntador", systemImage: "sparkles")
                    .font(.headline)
                    .foregroundStyle(PVDesign.accent)
                    .accessibilityIdentifier("detail-apuntador")
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
                .accessibilityIdentifier("apuntador-card-\(Int(card.askedAt))")
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
            companionCardEvidence(card)
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
    }

    @ViewBuilder
    private func companionCardEvidence(_ card: CompanionCard) -> some View {
        if let evidence = card.evidence, let detail {
            let question = evidence.resolveQuestion(
                currentTranscriptRevision: detail.meeting.transcriptRevision,
                segments: detail.segments)
            VStack(alignment: .leading, spacing: 5) {
                companionEvidenceRole(
                    L10n.text("Question source"),
                    resolution: question,
                    identifier: "apuntador-card-\(card.id.uuidString)-question")
                if let answer = evidence.resolveAnswer(
                    currentTranscriptRevision: detail.meeting.transcriptRevision,
                    segments: detail.segments) {
                    companionEvidenceRole(
                        L10n.text("Answer sources"),
                        resolution: answer,
                        identifier: "apuntador-card-\(card.id.uuidString)-answer")
                }
            }
        }
    }

    private func companionEvidenceRole(
        _ label: String,
        resolution: TranscriptEvidenceResolution,
        identifier: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            MeetingEvidenceSources(
                resolution: resolution,
                sourceIdentifier: "\(identifier)-evidence",
                staleIdentifier: "\(identifier)-stale",
                unavailableIdentifier: "\(identifier)-unavailable",
                clock: { presentation.clock($0) },
                focus: focusEvidence)
        }
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
        await model.send(.removeCompanionCard(id))
    }
}
