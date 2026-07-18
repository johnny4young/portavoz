import AppKit
import ApplicationKit
import AudioPlaybackKit
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

private struct PersonRememberOffer {
    let speaker: Speaker
    let source: PersonAliasSource
}

/// Transcript with editable speaker pills (the M3 leftover), the latest
/// summary snapshot, and its checkable action items.
struct MeetingDetailView: View {
    @Environment(AppServices.self) private var services
    @Environment(\.openSettings) private var openSettings
    let meetingID: MeetingID
    @Binding var route: Route?
    @State private var model: MeetingDetailModel

    private var detail: MeetingReviewReadModel? { model.state.readModel }
    /// The live Companion's answer cards, persisted (D26) so the meeting can
    /// be reviewed afterward. Empty hides the rail section.
    private var companionCards: [CompanionCard] { detail?.companionCards ?? [] }
    private var summary: MeetingReviewSummary? { detail?.summary }
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
    @State private var summarySetupIssue: SummarySetupIssue?
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
    /// Applying a draft stays view-local as presentation state while the
    /// atomic mutation and optional Companion refresh cross ApplicationKit.
    @State private var applying: String?
    @State private var actionError: String?
    @State private var retryingProcessing = false
    @State private var editingTitle = false
    @State private var newTitle = ""
    /// Presents the "New structure…" sheet from the Structure menu.
    @State private var showingNewStructure = false
    /// Which summary tab is showing (0 = overview · 1…N = `##` sections ·
    /// 1000 = action items).
    @State private var summaryTabSelection = 0
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
    /// Explicit summary-source navigation. Audio meetings seek the playhead
    /// without surprising playback; text-only meetings use this ID to focus
    /// the cited row.
    @State private var evidenceFocusSegmentID: UUID?
    /// Evidence can be clicked before a long waveform finishes preparing.
    /// Keep the exact seek until the player exists instead of dropping it.
    @State private var pendingEvidenceSeek: TimeInterval?

    init(
        services: AppServices,
        meetingID: MeetingID,
        route: Binding<Route?>
    ) {
        self.meetingID = meetingID
        _route = route
        _model = State(initialValue: services.makeMeetingDetailModel(meetingID))
    }

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
        .task(id: model.state.revision) { await refreshPresentation() }
        .onDisappear { player?.invalidate() }
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
                    services.pendingSettingsCategory = .intelligence
                    openSettings()
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
            Text("Transcript")
                .font(.headline)
                .accessibilityIdentifier("detail-transcript-title")
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
    private func transcriptArea(_ detail: MeetingReviewReadModel) -> some View {
        if player != nil {
            GeometryReader { geometry in
                transcriptLines(detail, carouselHeight: max(180, geometry.size.height))
            }
        } else {
            transcriptLines(detail, carouselHeight: 440)
        }
    }

    private func transcriptLines(_ detail: MeetingReviewReadModel, carouselHeight: CGFloat) -> some View {
        // Own View struct so only it re-renders as the playhead moves — the
        // header and summary above stay put.
        TranscriptSegmentsView(
            segments: detail.segments,
            speakers: detail.speakers,
            player: player,
            focusedSegmentID: evidenceFocusSegmentID,
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

    /// The right rail: processing recovery + privacy receipt + meeting health + ✦ chapters +
    /// the Companion's answers —
    /// the at-a-glance column beside the transcript. Hidden entirely when it
    /// would be empty. SCROLLS on its own so a long Companion list (many
    /// cards) never grows the page and pushes the header or docked player
    /// off-screen — the rail stays within its column, everything else stays put.
    @ViewBuilder
    private func detailRail(_ detail: MeetingReviewReadModel) -> some View {
        let hasChapters = !ChapterExtractor.chapters(from: detail.segments).isEmpty
        let hasHealth = detail.segments.contains { $0.speakerID != nil }
        let hasProcessingState = detail.meeting.lifecycleState == .needsAttention
            || detail.processingJobs.contains {
                $0.state == .pending || $0.state == .running || $0.state == .failed
            }
        if hasProcessingState || detail.privacyReceipt != nil
            || hasHealth || hasChapters || !companionCards.isEmpty {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    processingStatusSection(detail)
                    privacyReceiptSection(detail.privacyReceipt)
                    if hasHealth {
                        MeetingHealthView(speakers: detail.speakers, segments: detail.segments)
                    }
                    chaptersSection(detail)
                    companionCardsSection
                }
            }
            .frame(width: 260)
            .frame(maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func processingStatusSection(_ detail: MeetingReviewReadModel) -> some View {
        let failed = detail.processingJobs.filter { $0.state == .failed }
        let active = detail.processingJobs.filter {
            $0.state == .pending || $0.state == .running
        }
        if !failed.isEmpty {
            failedProcessingCard(failed)
        } else if !active.isEmpty {
            activeProcessingCard(active)
        } else if detail.meeting.lifecycleState == .needsAttention {
            recordingRecoveryCard(detail)
        }
    }

    private func failedProcessingCard(_ jobs: [ProcessingJob]) -> some View {
        processingCard(tint: .orange) {
            Label(
                "Processing needs attention",
                systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                .font(.headline)
                .foregroundStyle(.orange)
                .accessibilityIdentifier("detail-processing-status")
            Text(failedProcessingExplanation(jobs))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            retryProcessingButton
        }
    }

    private var retryProcessingButton: some View {
        Button {
            retryingProcessing = true
            Task {
                await model.send(.retryProcessing)
                retryingProcessing = false
            }
        } label: {
            if retryingProcessing {
                ProgressView().controlSize(.small)
            } else {
                Label("Retry processing", systemImage: "arrow.clockwise")
            }
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
        .disabled(retryingProcessing)
        .accessibilityIdentifier("detail-retry-processing")
    }

    private func activeProcessingCard(_ jobs: [ProcessingJob]) -> some View {
        processingCard(tint: PVDesign.accent) {
            Label("Processing on this Mac", systemImage: "gearshape.2")
                .font(.headline)
                .foregroundStyle(PVDesign.accent)
                .accessibilityIdentifier("detail-processing-status")
            Text(activeProcessingExplanation(jobs))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Keep Portavoz open; recovery continues automatically.")
                .font(.caption.weight(.semibold))
        }
    }

    @ViewBuilder
    private func recordingRecoveryCard(_ detail: MeetingReviewReadModel) -> some View {
        processingCard(tint: .orange) {
            Label(
                "Recording needs recovery",
                systemImage: "waveform.badge.exclamationmark")
                .font(.headline)
                .foregroundStyle(.orange)
                .accessibilityIdentifier("detail-processing-status")
            Text(recoveryExplanation(detail.meeting.lastProcessingError))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            processingRecoveryAction(detail)
        }
    }

    @ViewBuilder
    private func processingRecoveryAction(_ detail: MeetingReviewReadModel) -> some View {
        if detail.meeting.audioDirectory != nil {
            Button("Refine transcript") { refine(detail) }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .accessibilityIdentifier("detail-recover-with-refine")
        } else {
            Button("Open support diagnostics") {
                services.pendingSettingsCategory = .data
                openSettings()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .accessibilityIdentifier("detail-open-support-diagnostics")
        }
    }

    private func processingCard<Content: View>(
        tint: Color,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8, content: content)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(tint.opacity(0.2), lineWidth: 1))
    }

    private func failedProcessingExplanation(_ jobs: [ProcessingJob]) -> String {
        let kinds = Set(jobs.map(\.kind))
        if kinds.contains(.transcription) {
            // swiftlint:disable:next line_length
            return L10n.text("Transcript recovery stopped after repeated attempts. Your audio and current transcript are still saved.")
        }
        if kinds.contains(.diarization) {
            return L10n.text(
                "Speaker recovery stopped after repeated attempts. Your audio and transcript are still saved.")
        }
        return L10n.text(
            "Background processing stopped after repeated attempts. Your meeting is still saved.")
    }

    private func activeProcessingExplanation(_ jobs: [ProcessingJob]) -> String {
        if jobs.contains(where: { $0.kind == .transcription }) {
            return L10n.text("Recovering the complete transcript from finalized audio.")
        }
        if jobs.contains(where: { $0.kind == .diarization }) {
            return L10n.text("Recovering speaker attribution from finalized audio.")
        }
        return L10n.text("Finishing local background processing for this meeting.")
    }

    private func recoveryExplanation(_ code: String?) -> String {
        switch code {
        case "transcription.empty":
            L10n.text("No reliable speech was found. Run Refine to review the saved audio again.")
        case "capture.publication.failed":
            L10n.text("Portavoz preserved recovery evidence but could not finalize the recording.")
        default:
            L10n.text("Portavoz preserved the meeting, but automatic recovery could not finish.")
        }
    }

    @ViewBuilder
    private func privacyReceiptSection(_ receipt: PrivacyReceipt?) -> some View {
        if let receipt {
            let tint = privacyReceiptTint(receipt.status)
            VStack(alignment: .leading, spacing: 8) {
                Label("Privacy receipt", systemImage: privacyReceiptIcon(receipt.status))
                    .font(.headline)
                    .foregroundStyle(tint)
                    .accessibilityIdentifier("detail-privacy-receipt")
                Text(privacyReceiptHeadline(receipt.status))
                    .font(.callout.weight(.semibold))
                Text(privacyReceiptExplanation(receipt))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                ForEach(Array(receipt.remoteEvents.enumerated()), id: \.element.id) { index, event in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(privacyReceiptOperation(event.operation))
                            .font(.caption.weight(.semibold))
                        Text(event.destinationHost)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                        Text(event.attemptedAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("privacy-remote-event-\(index)")
                }

                if !receipt.generation.isEmpty || !receipt.localDeviceEvents.isEmpty {
                    Text(L10n.format(
                        "Model activity: %d · Local transfers: %d",
                        receipt.generation.count,
                        receipt.localDeviceEvents.count))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(tint.opacity(0.2), lineWidth: 1)
            )
        }
    }

    private func privacyReceiptTint(_ status: PrivacyReceiptStatus) -> Color {
        switch status {
        case .allContentStayedOnDevice: .green
        case .noRemoteTransferRecorded: .orange
        case .remoteTransferAttempted: .orange
        }
    }

    private func privacyReceiptIcon(_ status: PrivacyReceiptStatus) -> String {
        switch status {
        case .allContentStayedOnDevice: "lock.shield.fill"
        case .noRemoteTransferRecorded: "clock.badge.questionmark"
        case .remoteTransferAttempted: "arrow.up.right.square.fill"
        }
    }

    private func privacyReceiptHeadline(_ status: PrivacyReceiptStatus) -> String {
        switch status {
        case .allContentStayedOnDevice:
            L10n.text("No remote service used")
        case .noRemoteTransferRecorded:
            L10n.text("No remote transfer recorded")
        case .remoteTransferAttempted:
            L10n.text("Remote transfer attempted")
        }
    }

    private func privacyReceiptExplanation(_ receipt: PrivacyReceipt) -> String {
        switch receipt.status {
        case .allContentStayedOnDevice:
            return L10n.text("All tracked meeting processing stayed on this Mac.")
        case .noRemoteTransferRecorded:
            return L10n.format(
                "Tracking began %@; earlier activity is not covered.",
                receipt.trackingStartedAt.formatted(date: .abbreviated, time: .shortened))
        case .remoteTransferAttempted:
            if receipt.remoteEvents.count == 1 {
                return L10n.text(
                    "1 remote transfer attempt was recorded. Content may have left this Mac.")
            }
            return L10n.format(
                "%d remote transfer attempts were recorded. Content may have left this Mac.",
                receipt.remoteEvents.count)
        }
    }

    private func privacyReceiptOperation(_ operation: DataEgressOperation) -> String {
        switch operation {
        case .companionKnowledgeAnswer: L10n.text("Companion question only")
        case .summaryGeneration: L10n.text("Summary material")
        case .publishGitHubGist: L10n.text("Meeting export")
        case .createGitHubIssue: L10n.text("GitHub action item")
        case .createLinearIssue: L10n.text("Linear action item")
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
        if let message = refineError ?? actionError ?? model.state.lastActionError {
            Text(message).font(.caption).foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private func summaryOrGenerate(_ detail: MeetingReviewReadModel) -> some View {
        if let summary {
            summarySection(summary)
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

    /// The .portavoz interchange file (M15 L0): transcript + cast +
    /// latest summary + notes — and optionally the recording itself
    /// (compress first via "Compress audio (AAC)" for a mail-sized file).
    private func exportBundle(_ detail: MeetingReviewReadModel, includeAudio: Bool) async {
        guard let data = try? await services.exportMeetingBundle(
            meetingID: detail.meeting.id,
            includeAudio: includeAudio)
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
    private func header(_ detail: MeetingReviewReadModel) -> some View {
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
                if let suggestion = model.state.suggestedTitle {
                    Button {
                        Task {
                            await model.send(
                                .renameMeeting(detail.meeting, title: suggestion))
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
    private func actionRow(_ detail: MeetingReviewReadModel) -> some View {
        HStack(spacing: 8) {
            refineMenu(detail)

            Menu {
                Button("Export Markdown…") { export(as: .markdown) }
                Button("Export PDF…") { export(as: .pdf) }
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

    /// The meeting's cast, with the M6 "1-tap speaker→name" flow: ✦
    /// proposes names the transcript proves; one click applies them.
    @ViewBuilder
    private func speakersRow(_ detail: MeetingReviewReadModel) -> some View {
        let unnamed = detail.speakers.filter { !$0.isMe && $0.displayName == nil }
        HStack(spacing: 8) {
            ForEach(detail.speakers) { speaker in
                SpeakerPill(
                    speaker: speaker,
                    cast: detail.speakers,
                    accessibilityIdentifier: "cast-speaker-\(speaker.label)"
                ) { speaker in
                    renamingSpeaker = speaker
                    newName = speaker.displayName ?? ""
                }
            }
            if !unnamed.isEmpty {
                if model.state.isSuggestingNames {
                    ProgressView().controlSize(.small)
                } else if model.state.nameSuggestions.isEmpty {
                    Button {
                        Task { await suggestNames() }
                    } label: {
                        Label("Suggest names", systemImage: "sparkles")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(PVDesign.accent)
                    .accessibilityIdentifier("detail-suggest-names")
                }
            }
            ForEach(model.state.nameSuggestions, id: \.label) { suggestion in
                Button {
                    Task { await apply(suggestion, in: detail) }
                } label: {
                    ChipLabel(kind: .ai, text: "\(suggestion.label) → \(suggestion.name)?")
                }
                .buttonStyle(.plain)
                .help(nameSuggestionHelp(suggestion))
                .accessibilityIdentifier("detail-name-suggestion-\(suggestion.label)")
            }
            // Cross-meeting voice matches: same chip contract, waveform icon
            // marks the evidence as "their voice", not the transcript.
            ForEach(model.state.voiceSuggestions, id: \.speakerLabel) { match in
                Button {
                    Task { await apply(match, in: detail) }
                } label: {
                    ChipLabel(kind: .voice, text: "\(match.speakerLabel) → \(match.name)?")
                }
                .buttonStyle(.plain)
                .help(L10n.format(
                    "Voice match: sounds like “%@” from your remembered voices.", match.name))
            }
            personOfferChip
            rememberOfferChip
        }
    }

    /// The explicit canonical-person boundary (D86). One press creates a
    /// distinct person only when there are no exact alias candidates; any
    /// candidate requires a second, visible choice.
    @ViewBuilder
    private var personOfferChip: some View {
        if let offer = personOffer, let name = offer.speaker.displayName {
            if findingPerson {
                ProgressView().controlSize(.small)
            } else {
                HStack(spacing: 6) {
                    Label(
                        L10n.format("Remember %@ as a person?", name),
                        systemImage: "person.crop.circle.badge.plus")
                    .font(.caption)
                    .foregroundStyle(PVDesign.chipOfferInk)
                    Button(L10n.text("Remember")) {
                        Task { await findOrCreatePerson(for: offer) }
                    }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(PVDesign.accent)
                    .accessibilityIdentifier("person-remember-offer")
                    Button {
                        personOffer = nil
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption2)
                            .foregroundStyle(PVDesign.chipOfferInk)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L10n.text("Dismiss person offer"))
                    .accessibilityIdentifier("person-dismiss-offer")
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(PVDesign.chipOfferBg, in: Capsule())
                .help(L10n.text(
                    "Links this meeting speaker to local, user-confirmed person memory."))
            }
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

    private func nameSuggestionHelp(_ suggestion: MeetingNameSuggestion) -> String {
        switch suggestion.evidence {
        case .transcript(let quote):
            L10n.format("Transcript: “%@”", quote)
        case .calendarCandidate(let candidate):
            L10n.format("Calendar candidate: %@", candidate)
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
    private func summarySection(_ summary: MeetingReviewSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Summary")
                    .font(.headline)
                summaryBadgeText(summary)
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
                        Button("Regenerate in Spanish") { regenerate(language: .spanish) }
                        Button("Regenerate in English") { regenerate(language: .english) }
                        Menu("Structure") {
                            ForEach(CustomRecipeStore.all()) { recipe in
                                Button(recipe.displayName) {
                                    regenerate(
                                        language: summaryLanguage(summary.draft.language),
                                        recipe: recipe)
                                }
                            }
                            Divider()
                            Button("New structure…") { showingNewStructure = true }
                        }
                        if let alt = alternateEngine {
                            Divider()
                            Menu(alt.label) {
                                Button("Español") {
                                    regenerate(language: .spanish, engine: alt.engine)
                                }
                                Button("English") {
                                    regenerate(language: .english, engine: alt.engine)
                                }
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
    private func summaryTabs(_ summary: MeetingReviewSummary) -> some View {
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
    private func summaryTabContent(_ summary: MeetingReviewSummary) -> some View {
        let parsed = SummarySections.parse(summary.draft.markdown)
        if summaryTabSelection == 1000 {
            let evidenceByItem = summary.draft.actionItemEvidence.reduce(
                into: [UUID: SummaryActionItemEvidence]()
            ) { result, evidence in
                if result[evidence.actionItemID] == nil {
                    result[evidence.actionItemID] = evidence
                }
            }
            ForEach(summary.draft.actionItems) { item in
                VStack(alignment: .leading, spacing: 6) {
                    Toggle(isOn: actionBinding(item)) {
                        Text(item.text).strikethrough(item.isDone)
                    }
                    .toggleStyle(.checkbox)
                    .accessibilityIdentifier("action-item-\(item.id.uuidString)")
                    if let evidence = evidenceByItem[item.id], let detail {
                        let resolution = evidence.resolveEvidence(
                            currentTranscriptRevision: detail.meeting.transcriptRevision,
                            segments: detail.segments)
                        summaryEvidenceSources(
                            resolution,
                            sourceIdentifier:
                                "summary-action-item-\(item.id.uuidString)-evidence",
                            staleIdentifier:
                                "summary-action-item-\(item.id.uuidString)-stale",
                            unavailableIdentifier:
                                "summary-action-item-\(item.id.uuidString)-unavailable")
                    }
                }
            }
        } else if summaryTabSelection >= 1, summaryTabSelection - 1 < parsed.sections.count {
            let sectionOrdinal = summaryTabSelection - 1
            summaryDecisionSection(
                parsed.sections[sectionOrdinal],
                sectionOrdinal: sectionOrdinal,
                draft: summary.draft)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                MarkdownText(text: parsed.intro.isEmpty ? summary.draft.markdown : parsed.intro)
                summaryEvidence(summary.draft)
            }
        }
    }

    @ViewBuilder
    private func summaryDecisionSection(
        _ section: SummarySections.Section,
        sectionOrdinal: Int,
        draft: SummaryDraft
    ) -> some View {
        let evidenceByBullet = draft.decisionEvidence
            .filter { $0.sectionOrdinal == sectionOrdinal }
            .reduce(into: [Int: SummaryDecisionEvidence]()) { result, evidence in
                if result[evidence.bulletOrdinal] == nil {
                    result[evidence.bulletOrdinal] = evidence
                }
            }
        if evidenceByBullet.isEmpty {
            MarkdownText(text: section.body)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(section.bulletLines.enumerated()), id: \.offset) { index, bullet in
                    VStack(alignment: .leading, spacing: 6) {
                        MarkdownText(text: bullet)
                        if let evidence = evidenceByBullet[index], let detail {
                            let resolution = evidence.resolveEvidence(
                                currentTranscriptRevision: detail.meeting.transcriptRevision,
                                segments: detail.segments)
                            summaryEvidenceSources(
                                resolution,
                                sourceIdentifier: "summary-decision-\(sectionOrdinal)-\(index)-evidence",
                                staleIdentifier: "summary-decision-\(sectionOrdinal)-\(index)-stale",
                                unavailableIdentifier:
                                    "summary-decision-\(sectionOrdinal)-\(index)-unavailable")
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func summaryEvidence(_ draft: SummaryDraft) -> some View {
        if let detail,
           let claim = draft.claims.first(where: { $0.kind == .overview }) {
            let resolution = claim.resolveEvidence(
                currentTranscriptRevision: detail.meeting.transcriptRevision,
                segments: detail.segments)
            VStack(alignment: .leading, spacing: 8) {
                summaryEvidenceSources(
                    resolution,
                    sourceIdentifier: "summary-evidence",
                    staleIdentifier: "summary-evidence-stale",
                    unavailableIdentifier: "summary-evidence-unavailable")
                SummaryClaimFeedbackView(claim: claim) { feedback in
                    let effect = await model.send(
                        .setSummaryClaimFeedback(claim.id, feedback))
                    guard case .summaryClaimFeedbackSaved(let savedID) = effect else {
                        return false
                    }
                    return savedID == claim.id
                }
            }
        }
    }

    @ViewBuilder
    private func summaryEvidenceSources(
        _ resolution: SummaryClaimEvidenceResolution,
        sourceIdentifier: String,
        staleIdentifier: String,
        unavailableIdentifier: String
    ) -> some View {
        switch resolution.status {
        case .current:
            HStack(spacing: 6) {
                Label("Sources", systemImage: "quote.bubble")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(
                    Array(resolution.segments.enumerated()),
                    id: \.element.id
                ) { index, segment in
                    Button(evidenceClock(segment.startTime)) {
                        focusEvidence(segment)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .help(segment.text)
                    .accessibilityIdentifier("\(sourceIdentifier)-\(index)")
                    .accessibilityValue(segment.text)
                }
            }
        case .stale:
            Label(
                "Sources are out of date after transcript changes.",
                systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityIdentifier(staleIdentifier)
        case .unavailable:
            Label(
                "Sources are no longer available.",
                systemImage: "exclamationmark.triangle")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityIdentifier(unavailableIdentifier)
        }
    }

    private func focusEvidence(_ segment: TranscriptSegment) {
        evidenceFocusSegmentID = segment.id
        pendingEvidenceSeek = segment.startTime
        applyPendingEvidenceSeekIfPossible()
    }

    private func applyPendingEvidenceSeekIfPossible() {
        guard let seconds = pendingEvidenceSeek, let player else { return }
        player.seek(to: seconds)
        pendingEvidenceSeek = nil
    }

    private func evidenceClock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private enum ExportFormat { case markdown, pdf }

    private func export(as format: ExportFormat) {
        Task {
            let effect = await model.send(.prepareDocument(
                format == .markdown ? .markdown : .pdf))
            switch effect {
            case .documentPrepared(let document):
                switch format {
                case .markdown:
                    exportType = .plainText
                case .pdf:
                    exportType = .pdf
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
            let result = await services.regenerateSummary.execute(request)
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
                services.refines.cancel(meetingID)
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
        services.refines.start(
            meetingID: meetingID,
            meeting: detail.meeting,
            speakers: detail.speakers,
            segments: detail.segments,
            useCase: services.refineMeeting.draft,
            languagePolicy: languagePolicy)
    }

    private func applyRefineDraft(_ draft: RefineDraft) {
        services.refines.clear(meetingID)
        applying = L10n.text("Applying the refined transcript…")
        Task {
            defer { applying = nil }
            do {
                let result = try await services.applyMeetingDetailRefine(
                    ApplyRefinedMeetingRequest(
                        meetingID: meetingID,
                        draft: draft
                    ) { phase in
                        if phase == .refreshingCompanion {
                            await MainActor.run {
                                applying = L10n.text(
                                    "Re-checking the Companion's answers…")
                            }
                        }
                    })
                if result.companion == .persistenceFailed {
                    actionError = L10n.text(
                        "The transcript was refined, but Companion cards could not be refreshed.")
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

    private func actionBinding(_ item: ActionItem) -> Binding<Bool> {
        Binding(
            get: { item.isDone },
            set: { done in
                Task {
                    await model.send(.setActionItem(item.id, done: done))
                }
            }
        )
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
        guard mirrorAfterMeeting, services.justRecorded == meetingID else { return false }
        let health = MeetingHealth.compute(segments: detail.segments)
        guard mirrorMyStat(detail, health: health) != nil else { return false }
        return MirrorStats.qualifies(
            speakerCount: health.stats.count,
            seconds: mirrorDuration(detail, health: health))
    }

    private func mirrorBinding(_ detail: MeetingReviewReadModel) -> Binding<Bool> {
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
    private func mirrorSheet(_ detail: MeetingReviewReadModel) -> some View {
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

    private func refreshPresentation() async {
        guard detail != nil else { return }
        await loadPlayerIfNeeded()
        guard !Task.isCancelled else { return }
        // A palette citation navigated here: jump to the cited moment.
        if let seek = services.pendingSeek {
            services.pendingSeek = nil
            player?.seek(to: seek)
        }
        await model.send(.loadMetadataSuggestions)
        guard !Task.isCancelled else { return }
        await loadVoiceSuggestions()
    }

    /// "Summarize as Standup?" — the typed-recipe suggestion (M13b). One
    /// click regenerates with that structure; dismissable by regenerating
    /// any other way. Never applied on its own.
    @ViewBuilder
    private func recipeSuggestionChip(
        _ summary: MeetingReviewSummary
    ) -> some View {
        if let suggested = model.state.suggestedRecipe, !regenerating {
            Button {
                regenerate(
                    language: summaryLanguage(summary.draft.language),
                    recipe: suggested)
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
        _ summary: MeetingReviewSummary
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
                regenerate(language: summaryLanguage(summary.draft.language), engine: .mlx)
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
    private func summaryBadgeText(
        _ summary: MeetingReviewSummary
    ) -> some View {
        let badge = summaryBadge(summary)
        return Text(badge)
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityLabel(badge)
            .accessibilityValue(badge)
            .accessibilityIdentifier("summary-badge")
    }

    private func summaryBadge(_ summary: MeetingReviewSummary) -> String {
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
        guard player == nil, let loadedDetail = detail,
            let relative = loadedDetail.meeting.audioDirectory
        else { return }
        let base = RecordingsLocation.shared.resolve(relative)
        let system = MeetingAudioLayout.channelFile(named: "system", in: base)
        let mic = MeetingAudioLayout.channelFile(named: "microphone", in: base)
        let files = [system, mic].compactMap { $0 }
        guard !files.isEmpty else { return }
        let loadedPlayer = await MeetingPlayer.make(channelFiles: files)
        guard !Task.isCancelled else {
            loadedPlayer?.invalidate()
            return
        }
        // Off the main actor: a long meeting reads a lot of frames.
        let loadedWaveform = await Task.detached {
            Waveform.generate(micFile: mic, systemFile: system, buckets: 600)
        }.value
        guard !Task.isCancelled else {
            loadedPlayer?.invalidate()
            return
        }
        channelURLs = files
        player = loadedPlayer
        applyPendingEvidenceSeekIfPossible()
        waveform = loadedWaveform
        loadedPlayer?.setSilentRanges(
            Waveform.silentRanges(loadedWaveform, duration: loadedPlayer?.duration ?? 0))
        // "Solo mi voz": skip everything that isn't the user's mic turns.
        if let loadedPlayer {
            let voiceRanges = loadedDetail.segments
                .filter { $0.channel == .microphone && $0.endTime > $0.startTime }
                .map { $0.startTime...$0.endTime }
            loadedPlayer.setNonVoiceRanges(
                PlaybackRanges.complement(of: voiceRanges, within: loadedPlayer.duration))
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
    private func chaptersSection(_ detail: MeetingReviewReadModel) -> some View {
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
                            Text(model.state.chapterTitles[chapter.startTime] ?? chapter.title)
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
                .accessibilityIdentifier("companion-card-\(Int(card.askedAt))")
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
                    identifier: "companion-card-\(card.id.uuidString)-question")
                if let answer = evidence.resolveAnswer(
                    currentTranscriptRevision: detail.meeting.transcriptRevision,
                    segments: detail.segments) {
                    companionEvidenceRole(
                        L10n.text("Answer sources"),
                        resolution: answer,
                        identifier: "companion-card-\(card.id.uuidString)-answer")
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
            summaryEvidenceSources(
                resolution,
                sourceIdentifier: "\(identifier)-evidence",
                staleIdentifier: "\(identifier)-stale",
                unavailableIdentifier: "\(identifier)-unavailable")
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
