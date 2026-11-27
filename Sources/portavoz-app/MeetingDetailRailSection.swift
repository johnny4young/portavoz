import ApplicationKit
import PortavozCore
import SwiftUI

/// The margin's three lenses beside the transcript.
enum MeetingDetailRailTab: String, CaseIterable, Identifiable {
    case marginalia
    case apuntador
    case people

    var id: String { rawValue }

    var title: String {
        switch self {
        case .marginalia: L10n.text("Marginalia")
        case .apuntador: L10n.text("Apuntador")
        case .people: L10n.text("People")
        }
    }
}

struct MeetingDetailRailValues {
    let trust: MeetingDetailTrustValues?
    let notes: MeetingDetailNotesValues
    let segments: [TranscriptSegment]
    let chapters: [MeetingTranscriptContent.Chapter]
    let companionCards: [CompanionCard]
    let companionFreshness: [UUID: DerivedArtifactFreshness]
    let people: MeetingDetailPeopleValues
    let transcriptRevision: Int
    let hasPlayback: Bool
    let isRefreshingCompanion: Bool
    let selectedTab: MeetingDetailRailTab
    let presentation: MeetingDetailPresentation
}

struct MeetingDetailRailActions {
    let retryProcessing: @MainActor @Sendable () async -> Void
    let refineSavedAudio: @MainActor () -> Void
    let openSupportDiagnostics: @MainActor () -> Void
    let notes: MeetingDetailNotesActions
    let people: MeetingDetailPeopleActions
    let seekAndPlay: @MainActor (TimeInterval) -> Void
    let focusEvidence: @MainActor (TranscriptSegment) -> Void
    let copyAnswer: @MainActor (String) -> Void
    let refreshCompanionCards: @MainActor () -> Void
    let removeCompanionCard: @MainActor @Sendable (UUID) async -> Void
    let selectTab: @MainActor (MeetingDetailRailTab) -> Void
}

/// The margin beside the summary and transcript, or above the transcript when
/// the page reads as one column.
///
/// One of three lenses grows with the page instead of scrolling on its own:
/// Marginalia (processing that needs attention, chapters and your notes, whose
/// cards sit beside their lines), Apuntador, and People (names and voices still
/// to confirm). Selection is owned by the composition, not by this view.
struct MeetingDetailRailSection: View {
    let values: MeetingDetailRailValues
    let actions: MeetingDetailRailActions

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            tabBar
            lens
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("detail-secondary-rail")
    }

    private var tabBar: some View {
        HStack(spacing: 14) {
            ForEach(MeetingDetailRailTab.allCases) { tab in
                tabButton(tab)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("detail-rail-tabs")
    }

    /// Text tabs; the chosen one is ink with a hairline under it.
    private func tabButton(_ tab: MeetingDetailRailTab) -> some View {
        let selected = tab == values.selectedTab
        let count = tab == .people ? values.people.count : 0
        return Button {
            actions.selectTab(tab)
        } label: {
            HStack(spacing: 4) {
                Text(tab.title)
                if count > 0 {
                    Text(count, format: .number)
                        .monospacedDigit()
                        .foregroundStyle(PVDesign.ink2)
                }
            }
            .font(.subheadline.weight(.semibold))
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(selected ? PVDesign.ink : PVDesign.ink3)
            .padding(.bottom, 4)
            .overlay(alignment: .bottom) {
                if selected {
                    Rectangle().fill(PVDesign.ink).frame(height: 1.5)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tab.title)
        .accessibilityValue(count > 0 ? Text(count, format: .number) : Text(verbatim: ""))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("detail-rail-tab-\(tab.rawValue)")
    }

    @ViewBuilder
    private var lens: some View {
        switch values.selectedTab {
        case .marginalia:
            marginalia
        case .apuntador:
            if values.companionCards.isEmpty {
                emptyLens(
                    "Apuntador answers from this meeting appear here.",
                    id: "detail-rail-empty-apuntador")
            } else {
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
        case .people:
            if values.people.isEmpty {
                emptyLens("Suggested names and voices appear here.", id: "detail-rail-empty-people")
            } else {
                MeetingDetailPeopleSection(values: values.people, actions: actions.people)
            }
        }
    }

    @ViewBuilder
    private var marginalia: some View {
        if values.trust == nil, values.chapters.isEmpty, !values.notes.hasContent {
            emptyLens(
                "Commitments, decisions and your notes sit beside the line that produced them.",
                id: "detail-rail-empty-marginalia")
        } else {
            VStack(alignment: .leading, spacing: 14) {
                if let trust = values.trust {
                    MeetingDetailTrustSection(
                        values: trust,
                        actions: MeetingDetailTrustActions(
                            retryProcessing: actions.retryProcessing,
                            refineSavedAudio: actions.refineSavedAudio,
                            openSupportDiagnostics: actions.openSupportDiagnostics))
                }
                MeetingTranscriptChaptersSection(
                    chapters: values.chapters,
                    hasPlayback: values.hasPlayback,
                    presentation: values.presentation,
                    seekAndPlay: actions.seekAndPlay)
                MeetingDetailNotesSection(values: values.notes, actions: actions.notes)
            }
            // No accessibility container: with one child SwiftUI merges it and the child's identifier is lost.
        }
    }

    private func emptyLens(_ text: LocalizedStringKey, id: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.ink3)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier(id)
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
                        Label("Apuntador", systemImage: PVSymbol.apuntador)
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
                                    Label("Re-check answers", systemImage: PVSymbol.retry)
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
        let tint: Color = card.directed ? PVDesign.youInk : PVDesign.accent
        return VStack(alignment: .leading, spacing: 5) {
            if values.freshnessByCardID[card.id] == .stale {
                Label(
                    "Transcript changed — this answer may be out of date.",
                    systemImage: PVSymbol.history)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(PVDesign.caution)
                    .accessibilityIdentifier("apuntador-card-\(card.id.uuidString)-stale")
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Button { actions.seekAndPlay(card.askedAt) } label: {
                    Text(values.presentation.clock(card.askedAt, paddedMinutes: true))
                        .font(PVFont.timeCode(.caption))
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
                    .foregroundStyle(card.directed ? tint : PVDesign.ink3)
                Spacer()
                if !card.answer.isEmpty {
                    Button { actions.copyAnswer(card.answer) } label: { Image(systemName: "doc.on.doc") }
                        .buttonStyle(.plain)
                        .controlSize(.small)
                        .help(L10n.text("Copy answer"))
                        .accessibilityLabel(L10n.text("Copy answer"))
                        .accessibilityIdentifier("apuntador-card-copy-\(Int(card.askedAt))")
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
                .foregroundStyle(.ink3)
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
        if card.answer.isEmpty { return L10n.text("question detected") }
        return base
    }
}
