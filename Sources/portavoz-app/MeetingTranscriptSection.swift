import ApplicationKit
import PortavozCore
import SwiftUI

struct MeetingTranscriptValues {
    let content: MeetingTranscriptContent
    let speakers: [Speaker]
    let voiceCast: VoiceCast
    let correctionContext: @MainActor (
        MeetingTranscriptContent.Row
    ) -> TranscriptCorrectionEditorContext?
    let structureProjection: MeetingTranscriptStructureProjection
    let player: MeetingPlaybackSession?
    let focusedRowID: UUID?
    let revealCount: Int
    let performanceScrollEnabled: Bool
    let translation: MeetingTranscriptTranslationState
    /// Nil when no decision or commitment anchors to a shown line.
    let margin: MeetingMarginNotesContext?
}

struct MeetingTranscriptActions {
    let seekAndPlay: @MainActor (TimeInterval) -> Void
    let renameSpeaker: @MainActor (Speaker) -> Void
    let presentCorrection: @MainActor (MeetingTranscriptContent.Row) -> Void
    let restructure: @MainActor (
        TranscriptStructuralCorrectionOperation
    ) async -> String?
    let translate: @MainActor (String) -> Void
    let cancelTranslation: @MainActor () -> Void
    let openTranslationSettings: @MainActor () -> Void
}

/// The synchronized transcript, read as a section of the meeting page rather
/// than its own viewport. It consumes a neutral reading value, so a later
/// correction composer can replace the accepted projection without
/// introducing correction or evidence policy into SwiftUI.
struct MeetingTranscriptSection: View {
    let values: MeetingTranscriptValues
    let actions: MeetingTranscriptActions
    @State private var showingHiddenLines = false
    /// Nil shows the original; a language shows its stored translation.
    @State private var language: String?
    @State private var requestedLanguage: String?
    @State private var pageWidth: CGFloat = 0
    /// Owned here, not by a lazy row, so scrolling never dismisses the sheet.
    @State private var reviewing: MarginReviewTarget?
    @State private var isSaving = false

    var body: some View {
        // Rows take explicit widths from `pageWidth`, so it comes from the proposal
        // alone: measuring the section would feed their widths back into it.
        ZStack(alignment: .topLeading) {
            Color.clear
                .frame(height: 0)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { pageWidth = $0 }
            transcriptContent
        }
        // Rows fill the page, but an empty transcript must not measure the header's width.
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("detail-transcript-section")
        .onChange(of: values.translation.translations) {
            // A requested translation opens once it is current.
            guard let requested = requestedLanguage, values.translation.isCurrent(requested) else { return }
            language = requested
            requestedLanguage = nil
        }
        .sheet(isPresented: $showingHiddenLines) {
            SuppressedTranscriptCorrectionsSheet(
                contexts: values.structureProjection.suppressedContexts,
                restore: actions.restructure)
        }
    }

    private var transcriptContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            transcriptHeader
                .frame(width: pageWidth > 0 ? MeetingDetailPageMetrics.readingWidth(forPageWidth: pageWidth) : nil)
            transcriptRows
                .sheet(item: $reviewing) { target in
                    MeetingCommitmentConfirmationSheet(
                        candidate: target.candidate,
                        ownerChoices: target.ownerChoices,
                        cancel: { reviewing = nil },
                        confirm: { title, assignee, dueAt in
                            await target.commitments.confirm(target.candidate, title, assignee, dueAt)
                        })
                }
        }
    }

    private var transcriptHeader: some View {
        HStack {
            Text("Transcript")
                .font(.headline)
                .accessibilityIdentifier("detail-transcript-title")
            Spacer()
            if !values.structureProjection.suppressedContexts.isEmpty {
                Button {
                    showingHiddenLines = true
                } label: {
                    Label(
                        L10n.format(
                            "Hidden lines · %d",
                            values.structureProjection.suppressedContexts.count),
                        systemImage: "eye.slash")
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("transcript-hidden-lines")
                .help("Review hidden lines")
            }
            MeetingTranscriptTranslationControls(
                state: values.translation, language: $language,
                translate: { target in
                    requestedLanguage = target
                    actions.translate(target)
                },
                cancel: actions.cancelTranslation, openSettings: actions.openTranslationSettings)
        }
    }

    private var transcriptRows: some View {
        TranscriptSegmentsView(
            content: MeetingTranscriptTranslationState.display(
                values.content, translation: values.translation.translation(language)),
            speakers: values.speakers,
            voiceCast: values.voiceCast,
            player: values.player,
            focusedRowID: values.focusedRowID,
            revealCount: values.revealCount,
            performanceScrollEnabled: values.performanceScrollEnabled,
            onSeek: actions.seekAndPlay,
            onRenameTap: actions.renameSpeaker,
            // Corrections edit the original, so a translated reading is read-only.
            canCorrect: {
                language == nil && (values.correctionContext($0) != nil
                    || values.structureProjection.context(for: $0) != nil)
            },
            onCorrect: actions.presentCorrection,
            pageWidth: pageWidth,
            margin: margin)
    }

    private var margin: MeetingMarginNotesContext? {
        guard var margin = values.margin else { return nil }
        let commitments = margin.commitments
        let ownerChoices = margin.ownerChoices
        margin.review = MeetingMarginReview(
            open: { candidate in
                reviewing = MarginReviewTarget(
                    candidate: candidate, ownerChoices: ownerChoices, commitments: commitments)
            },
            deferCandidate: { candidate, days in
                save { await commitments.deferCandidate(candidate, days: days) }
            },
            dismiss: { candidate in save { await commitments.dismiss(candidate) } },
            isBusy: isSaving)
        return margin
    }

    /// Failures surface through the detail model's action error.
    private func save(_ operation: @escaping @MainActor () async -> Bool) {
        isSaving = true
        Task {
            _ = await operation()
            isSaving = false
        }
    }
}

/// Local chapter navigation derived from the same reading snapshot as the
/// visible rows. It never computes chapters or reaches playback on its own.
struct MeetingTranscriptChaptersSection: View {
    let chapters: [MeetingTranscriptContent.Chapter]
    let hasPlayback: Bool
    let presentation: MeetingDetailPresentation
    let seekAndPlay: @MainActor (TimeInterval) -> Void

    var body: some View {
        if !chapters.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Label("Chapters", systemImage: PVSymbol.generate)
                    .font(.headline)
                    .foregroundStyle(PVDesign.accent)
                ForEach(chapters) { chapter in
                    chapterButton(chapter)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("detail-chapters")
        }
    }

    private func chapterButton(_ chapter: MeetingTranscriptContent.Chapter) -> some View {
        Button {
            seekAndPlay(chapter.startTime)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(presentation.clock(chapter.startTime, paddedMinutes: true))
                    .font(PVFont.timeCode(.caption))
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
        .disabled(!hasPlayback)
        .padding(.vertical, 3)
        .accessibilityIdentifier("chapter-\(Int(chapter.startTime))")
        .help(hasPlayback
            ? L10n.text("Jump to this moment")
            : L10n.text("Jumping needs audio, and this meeting has none"))
    }
}

/// The sheet keeps the flows it opened with, so a refresh that drops the
/// margin never leaves it empty.
private struct MarginReviewTarget: Identifiable {
    let candidate: CommitmentInboxCandidate
    let ownerChoices: [CommitmentOwnerSuggestion]
    let commitments: MeetingCommitmentInboxActions

    var id: CommitmentInboxCandidate.ID { candidate.id }
}
