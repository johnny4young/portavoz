import ApplicationKit
import PortavozCore
import SwiftUI

struct MeetingTranscriptValues {
    let content: MeetingTranscriptContent
    let speakers: [Speaker]
    let correctionContext: @MainActor (
        MeetingTranscriptContent.Row
    ) -> TranscriptCorrectionEditorContext?
    let structureProjection: MeetingTranscriptStructureProjection
    let player: MeetingPlaybackSession?
    let focusedRowID: UUID?
    let performanceScrollEnabled: Bool
    let translation: MeetingTranscriptTranslationState
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

/// The synchronized transcript reading surface. It consumes a neutral reading
/// value, so a later correction composer can replace the accepted projection
/// without introducing correction or evidence policy into SwiftUI.
struct MeetingTranscriptSection: View {
    let values: MeetingTranscriptValues
    let actions: MeetingTranscriptActions
    @State private var showingHiddenLines = false
    /// Nil shows the original; a language shows its stored translation.
    @State private var language: String?
    @State private var requestedLanguage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            transcriptHeader
            transcriptArea
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .clipped()
        }
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
            if values.player != nil {
                Text("Click a line to jump there")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder
    private var transcriptArea: some View {
        if values.player != nil {
            GeometryReader { geometry in
                transcriptViewport(carouselHeight: max(1, geometry.size.height))
            }
        } else {
            transcriptViewport(carouselHeight: 440)
        }
    }

    private func transcriptViewport(carouselHeight: CGFloat) -> some View {
        TranscriptSegmentsView(
            content: MeetingTranscriptTranslationState.display(
                values.content, translation: values.translation.translation(language)),
            speakers: values.speakers,
            player: values.player,
            focusedRowID: values.focusedRowID,
            performanceScrollEnabled: values.performanceScrollEnabled,
            onSeek: actions.seekAndPlay,
            onRenameTap: actions.renameSpeaker,
            // Corrections edit the original, so a translated reading is read-only.
            canCorrect: {
                language == nil && (values.correctionContext($0) != nil
                    || values.structureProjection.context(for: $0) != nil)
            },
            onCorrect: actions.presentCorrection,
            carouselHeight: carouselHeight)
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
        .disabled(!hasPlayback)
        .padding(.vertical, 3)
        .accessibilityIdentifier("chapter-\(Int(chapter.startTime))")
        .help(hasPlayback
            ? L10n.text("Jump to this moment")
            : L10n.text("Jumping needs audio, and this meeting has none"))
    }
}
