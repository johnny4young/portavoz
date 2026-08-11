import ApplicationKit
import PortavozCore
import SwiftUI

struct MeetingDetailRailValues {
    let trust: MeetingDetailTrustValues?
    let hasHealth: Bool
    let speakers: [Speaker]
    let segments: [TranscriptSegment]
    let chapters: [MeetingTranscriptContent.Chapter]
    let companionCards: [CompanionCard]
    let companionFreshness: [UUID: DerivedArtifactFreshness]
    let transcriptRevision: Int
    let hasPlayback: Bool
    let isRefreshingCompanion: Bool
    let presentation: MeetingDetailPresentation

    var hasContent: Bool {
        trust != nil
            || hasHealth
            || !chapters.isEmpty
            || !companionCards.isEmpty
    }
}

struct MeetingDetailRailActions {
    let retryProcessing: @MainActor @Sendable () async -> Void
    let refineSavedAudio: @MainActor () -> Void
    let openSupportDiagnostics: @MainActor () -> Void
    let seekAndPlay: @MainActor (TimeInterval) -> Void
    let focusEvidence: @MainActor (TranscriptSegment) -> Void
    let copyAnswer: @MainActor (String) -> Void
    let refreshCompanionCards: @MainActor () -> Void
    let removeCompanionCard: @MainActor @Sendable (UUID) async -> Void
}

/// Independently scrolling secondary review surfaces beside the transcript.
///
/// Recovery, privacy, health, chapters, and persisted Apuntador evidence share
/// one explicit rail boundary and cannot reach route or composition owners.
struct MeetingDetailRailSection: View {
    let values: MeetingDetailRailValues
    let actions: MeetingDetailRailActions

    var body: some View {
        Group {
            if values.hasContent {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if let trust = values.trust {
                            MeetingDetailTrustSection(
                                values: trust,
                                actions: MeetingDetailTrustActions(
                                    retryProcessing: actions.retryProcessing,
                                    refineSavedAudio: actions.refineSavedAudio,
                                    openSupportDiagnostics: actions.openSupportDiagnostics))
                        }
                        if values.hasHealth {
                            MeetingHealthView(
                                speakers: values.speakers,
                                segments: values.segments)
                        }
                        MeetingTranscriptChaptersSection(
                            chapters: values.chapters,
                            hasPlayback: values.hasPlayback,
                            presentation: values.presentation,
                            seekAndPlay: actions.seekAndPlay)
                        MeetingDetailCompanionSection(
                            values: MeetingDetailCompanionValues(
                                cards: values.companionCards,
                                freshnessByCardID: values.companionFreshness,
                                transcriptRevision: values.transcriptRevision,
                                segments: values.segments,
                                hasPlayback: values.hasPlayback,
                                isRefreshing: values.isRefreshingCompanion,
                                presentation: values.presentation),
                            actions: MeetingDetailCompanionActions(
                                seekAndPlay: actions.seekAndPlay,
                                focusEvidence: actions.focusEvidence,
                                copyAnswer: actions.copyAnswer,
                                refresh: actions.refreshCompanionCards,
                                removeCard: actions.removeCompanionCard))
                    }
                }
                .frame(width: 260)
                .frame(maxHeight: .infinity)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("detail-secondary-rail")
            }
        }
    }
}

struct MeetingDetailCompanionValues {
    let cards: [CompanionCard]
    let freshnessByCardID: [UUID: DerivedArtifactFreshness]
    let transcriptRevision: Int
    let segments: [TranscriptSegment]
    let hasPlayback: Bool
    let isRefreshing: Bool
    let presentation: MeetingDetailPresentation

    var hasStaleCards: Bool {
        cards.contains { freshnessByCardID[$0.id] == .stale }
    }
}

struct MeetingDetailCompanionActions {
    let seekAndPlay: @MainActor (TimeInterval) -> Void
    let focusEvidence: @MainActor (TranscriptSegment) -> Void
    let copyAnswer: @MainActor (String) -> Void
    let refresh: @MainActor () -> Void
    let removeCard: @MainActor @Sendable (UUID) async -> Void
}

struct MeetingDetailCompanionSection: View {
    let values: MeetingDetailCompanionValues
    let actions: MeetingDetailCompanionActions

    var body: some View {
        Group {
            if !values.cards.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Label("Apuntador", systemImage: "sparkles")
                            .font(.headline)
                            .foregroundStyle(PVDesign.accent)
                            .accessibilityIdentifier("detail-apuntador")
                        Spacer()
                        if values.hasStaleCards {
                            Button(action: actions.refresh) {
                                if values.isRefreshing {
                                    ProgressView()
                                        .controlSize(.small)
                                } else {
                                    Label("Re-check answers", systemImage: "arrow.clockwise")
                                        .labelStyle(.iconOnly)
                                }
                            }
                            .buttonStyle(.plain)
                            .controlSize(.small)
                            .disabled(values.isRefreshing)
                            .accessibilityLabel(L10n.text("Re-check answers"))
                            .accessibilityIdentifier("detail-apuntador-refresh")
                            .help(L10n.text("Re-check answers using the corrected transcript"))
                        }
                    }
                    ForEach(values.cards) { card in
                        cardRow(card)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    .quaternary.opacity(0.4),
                    in: RoundedRectangle(cornerRadius: 10))
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("detail-apuntador-section")
            }
        }
    }

    private func cardRow(_ card: CompanionCard) -> some View {
        let tint: Color = card.directed ? .orange : PVDesign.accent
        return VStack(alignment: .leading, spacing: 5) {
            if values.freshnessByCardID[card.id] == .stale {
                Label(
                    "Transcript changed — this answer may be out of date.",
                    systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("apuntador-card-\(card.id.uuidString)-stale")
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Button { actions.seekAndPlay(card.askedAt) } label: {
                    Text(values.presentation.clock(card.askedAt, paddedMinutes: true))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(tint)
                }
                .buttonStyle(.plain)
                .disabled(!values.hasPlayback)
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
            evidence(card)
            HStack {
                Text(tag(card))
                    .font(.caption2)
                    .foregroundStyle(card.directed ? tint : Color.secondary)
                Spacer()
                if !card.answer.isEmpty {
                    Button { actions.copyAnswer(card.answer) } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.plain)
                    .controlSize(.small)
                    .help(L10n.text("Copy answer"))
                }
                Button {
                    Task { await actions.removeCard(card.id) }
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
            RoundedRectangle(cornerRadius: 8).strokeBorder(tint.opacity(0.25), lineWidth: 1))
    }

    @ViewBuilder
    private func evidence(_ card: CompanionCard) -> some View {
        if let evidence = card.evidence {
            let question = currentResolution(evidence.resolveQuestion(
                currentTranscriptRevision: values.transcriptRevision,
                segments: values.segments), cardID: card.id)
            VStack(alignment: .leading, spacing: 5) {
                evidenceRole(
                    L10n.text("Question source"),
                    resolution: question,
                    identifier: "apuntador-card-\(card.id.uuidString)-question")
                if let resolvedAnswer = evidence.resolveAnswer(
                    currentTranscriptRevision: values.transcriptRevision,
                    segments: values.segments) {
                    let answer = currentResolution(resolvedAnswer, cardID: card.id)
                    evidenceRole(
                        L10n.text("Answer sources"),
                        resolution: answer,
                        identifier: "apuntador-card-\(card.id.uuidString)-answer")
                }
            }
        }
    }

    private func currentResolution(
        _ resolution: TranscriptEvidenceResolution,
        cardID: UUID
    ) -> TranscriptEvidenceResolution {
        values.freshnessByCardID[cardID] == .stale
            ? TranscriptEvidenceResolution(status: .stale)
            : resolution
    }

    private func evidenceRole(
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
                clock: { values.presentation.clock($0) },
                focus: actions.focusEvidence)
        }
    }

    private func tag(_ card: CompanionCard) -> String {
        let base = card.kind == .context
            ? L10n.text("from this meeting")
            : L10n.format("knowledge · %@", card.source)
        if card.directed {
            return card.answer.isEmpty
                ? L10n.text("asked you")
                : "\(L10n.text("asked you")) · \(base)"
        }
        return base
    }
}
