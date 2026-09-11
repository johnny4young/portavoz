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
}

struct MeetingTranscriptActions {
    let seekAndPlay: @MainActor (TimeInterval) -> Void
    let renameSpeaker: @MainActor (Speaker) -> Void
    let presentCorrection: @MainActor (MeetingTranscriptContent.Row) -> Void
    let restructure: @MainActor (
        TranscriptStructuralCorrectionOperation
    ) async -> String?
}

/// The synchronized transcript reading surface. It consumes a neutral reading
/// value, so a later correction composer can replace the accepted projection
/// without introducing correction or evidence policy into SwiftUI.
struct MeetingTranscriptSection: View {
    let values: MeetingTranscriptValues
    let actions: MeetingTranscriptActions
    @State private var showingHiddenLines = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            transcriptHeader
            transcriptArea
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .clipped()
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("detail-transcript-section")
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
                .help("Review hidden transcript evidence")
            }
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
            content: values.content,
            speakers: values.speakers,
            player: values.player,
            focusedRowID: values.focusedRowID,
            performanceScrollEnabled: values.performanceScrollEnabled,
            onSeek: actions.seekAndPlay,
            onRenameTap: actions.renameSpeaker,
            canCorrect: {
                values.correctionContext($0) != nil
                    || values.structureProjection.context(for: $0) != nil
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
                Label("Chapters", systemImage: "sparkles")
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
            : L10n.text("Chapters jump the player — this meeting has no audio."))
    }
}
