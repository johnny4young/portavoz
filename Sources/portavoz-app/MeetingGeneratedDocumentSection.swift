import ApplicationKit
import IntelligenceKit
import PortavozCore
import SwiftUI

enum MeetingGeneratedDocumentCopyFormat {
    case plainText
    case markdown
    case slack
}

struct MeetingGeneratedDocumentAlternateEngine {
    let engine: SummaryEngine
    let label: String
}

struct MeetingGeneratedDocumentValues {
    let summary: MeetingReviewSummary
    let transcriptRevision: Int
    let segments: [TranscriptSegment]
    let recipes: [Recipe]
    let summaryLanguage: LanguageCode
    let suggestedRecipe: Recipe?
    let showThinSuggestion: Bool
    let regenerating: Bool
    let alternateEngine: MeetingGeneratedDocumentAlternateEngine?
    let presentation: MeetingDetailPresentation
    let freshness: DerivedArtifactFreshness
    let decisionConfirmations:
        [SummaryDecisionID: DecisionObservationConfirmationState]
}

struct MeetingGeneratedDocumentActions {
    let copy: @MainActor (MeetingGeneratedDocumentCopyFormat) -> Void
    let regenerate: @MainActor (LanguageCode, SummaryEngine?, Recipe?) -> Void
    let createStructure: @MainActor () -> Void
    let dismissRecipeSuggestion: @MainActor () -> Void
    let dismissThinSuggestion: @MainActor () -> Void
    let setActionItem: @MainActor (ActionItem, Bool) -> Void
    let focusEvidence: @MainActor (TranscriptSegment) -> Void
    let setClaimFeedback:
        @MainActor (SummaryClaimID, SummaryClaimFeedback?) async -> Bool
    let confirmDecision:
        @MainActor (SummaryDecisionEvidence, _ statement: String) -> Void
    let decisionsDidAppear: @MainActor () -> Void
}

/// The generated meeting document: overview, typed sections, commitments,
/// open questions, action items, and claim-adjacent evidence.
///
/// This view owns only the selected tab. Generation and content mutations are
/// explicit route actions; no model, provider, or storage adapter enters it.
struct MeetingGeneratedDocumentSection: View {
    let values: MeetingGeneratedDocumentValues
    let actions: MeetingGeneratedDocumentActions

    @State private var tabSelection = 0

    private var document: MeetingGeneratedDocumentPresentation {
        MeetingGeneratedDocumentPresentation(
            markdown: values.summary.draft.markdown,
            hasTypedCommitments: !values.summary.draft.actionItems.isEmpty)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            documentHeader
            staleSummaryNotice
            documentTabs
            documentContent
        }
        .padding(14)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("detail-generated-document")
        .onChange(of: values.summary.version) { _, _ in
            tabSelection = 0
        }
    }

    @ViewBuilder
    private var staleSummaryNotice: some View {
        if values.freshness == .stale {
            HStack(spacing: 8) {
                Label(
                    "Transcript changed — regenerate this summary to use your corrections.",
                    systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("detail-stale-summary")
                Spacer()
                Button("Regenerate") {
                    actions.regenerate(values.summaryLanguage, nil, nil)
                }
                .controlSize(.small)
                .disabled(values.regenerating)
                .accessibilityIdentifier("detail-stale-summary-regenerate")
            }
        }
    }

    private var documentHeader: some View {
        HStack {
            Text("Summary")
                .font(.headline)
            summaryBadge
            Spacer()
            recipeSuggestion
            thinSummarySuggestion
            copyMenu
            regenerateMenu
        }
    }

    @ViewBuilder
    private var recipeSuggestion: some View {
        if let suggested = values.suggestedRecipe, !values.regenerating {
            DismissibleSuggestionChip(
                kind: .ai,
                text: L10n.format(
                    "Summarize as %@?",
                    suggested.localizedDisplayName),
                acceptAccessibilityIdentifier: "detail-recipe-suggestion",
                dismissAccessibilityIdentifier: "detail-recipe-suggestion-dismiss",
                accept: {
                    actions.regenerate(values.summaryLanguage, nil, suggested)
                },
                dismiss: actions.dismissRecipeSuggestion)
            .help(
                "This meeting looks like a \(suggested.localizedDisplayName) — restructure the summary with one click. Nothing changes unless you accept.")
        }
    }

    @ViewBuilder
    private var thinSummarySuggestion: some View {
        if values.showThinSuggestion, !values.regenerating {
            DismissibleSuggestionChip(
                kind: .ai,
                text: L10n.text("Summary looks thin — retry with Built-in?"),
                acceptAccessibilityIdentifier: "detail-thin-summary-suggestion",
                dismissAccessibilityIdentifier: "detail-thin-summary-suggestion-dismiss",
                accept: {
                    actions.regenerate(values.summaryLanguage, .mlx, nil)
                },
                dismiss: actions.dismissThinSuggestion)
            .help(
                // One-line UI help text.
                // swiftlint:disable:next line_length
                "This meeting is long but its summary came out very small. Regenerate with the embedded model — nothing changes unless you click.")
        }
    }

    private var copyMenu: some View {
        Menu {
            Button("Copy as plain text") { actions.copy(.plainText) }
            Button("Copy as Markdown") { actions.copy(.markdown) }
            Button("Copy for Slack") { actions.copy(.slack) }
        } label: {
            Image(systemName: "doc.on.doc")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Copy the summary to the clipboard")
    }

    @ViewBuilder
    private var regenerateMenu: some View {
        if values.regenerating {
            ProgressView().controlSize(.small)
        } else {
            Menu {
                Button("Regenerate in Spanish") {
                    actions.regenerate(.spanish, nil, nil)
                }
                Button("Regenerate in English") {
                    actions.regenerate(.english, nil, nil)
                }
                structureMenu
                if let alternate = values.alternateEngine {
                    Divider()
                    Menu(alternate.label) {
                        Button("Español") {
                            actions.regenerate(.spanish, alternate.engine, nil)
                        }
                        Button("English") {
                            actions.regenerate(.english, alternate.engine, nil)
                        }
                    }
                }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityIdentifier("detail-regenerate-menu")
        }
    }

    private var structureMenu: some View {
        Menu("Structure") {
            ForEach(values.recipes) { recipe in
                Button {
                    actions.regenerate(values.summaryLanguage, nil, recipe)
                } label: {
                    Text(recipe.localizedDisplayName)
                    Text(recipe.localizedSectionSummary)
                }
                .accessibilityIdentifier("detail-structure-\(recipe.id)")
            }
            Divider()
            Button("New structure…", action: actions.createStructure)
        }
        .accessibilityIdentifier("detail-structure-menu")
    }

    private var documentTabs: some View {
        let done = values.summary.draft.actionItems.filter(\.isDone).count
        let total = values.summary.draft.actionItems.count
        return HStack(spacing: 6) {
            documentTab(L10n.text("Summary"), tag: 0)
            ForEach(Array(document.sections.enumerated()), id: \.element.id) { index, section in
                documentTab("\(section.heading) · \(section.bulletCount)", tag: index + 1)
            }
            if total > 0 {
                documentTab(L10n.format("To-dos · %d/%d", done, total), tag: 1000)
            }
        }
    }

    private func documentTab(_ label: String, tag: Int) -> some View {
        let selected = tabSelection == tag
        return Button {
            tabSelection = tag
        } label: {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(selected ? Color.white : .secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background {
                    if selected {
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
    private var documentContent: some View {
        if tabSelection == 1000 {
            actionItems
        } else if tabSelection >= 1, tabSelection - 1 < document.sections.count {
            let section = document.sections[tabSelection - 1]
            generatedSection(
                section,
                draft: values.summary.draft)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                MarkdownText(text: document.overviewMarkdown)
                overviewEvidence
            }
        }
    }

    private var actionItems: some View {
        let evidenceByItem = values.summary.draft.actionItemEvidence.reduce(
            into: [UUID: SummaryActionItemEvidence]()
        ) { result, evidence in
            if result[evidence.actionItemID] == nil {
                result[evidence.actionItemID] = evidence
            }
        }
        return ForEach(values.summary.draft.actionItems) { item in
            VStack(alignment: .leading, spacing: 6) {
                Toggle(isOn: actionItemBinding(item)) {
                    Text(item.text).strikethrough(item.isDone)
                }
                .toggleStyle(.checkbox)
                .accessibilityIdentifier("action-item-\(item.id.uuidString)")
                if let evidence = evidenceByItem[item.id] {
                    let resolution = currentResolution(evidence.resolveEvidence(
                        currentTranscriptRevision: values.transcriptRevision,
                        segments: values.segments))
                    evidenceSources(
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
    }

    private func actionItemBinding(_ item: ActionItem) -> Binding<Bool> {
        Binding(
            get: { item.isDone },
            set: { actions.setActionItem(item, $0) })
    }

    @ViewBuilder
    private func generatedSection(
        _ section: MeetingGeneratedDocumentPresentation.Section,
        draft: SummaryDraft
    ) -> some View {
        let evidenceByBullet = draft.decisionEvidence
            .filter { $0.sectionOrdinal == section.sourceOrdinal }
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
                        if let evidence = evidenceByBullet[index] {
                            let resolution = currentResolution(evidence.resolveEvidence(
                                currentTranscriptRevision: values.transcriptRevision,
                                segments: values.segments))
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                evidenceSources(
                                    resolution,
                                    sourceIdentifier:
                                        "summary-decision-\(section.sourceOrdinal)-\(index)-evidence",
                                    staleIdentifier:
                                        "summary-decision-\(section.sourceOrdinal)-\(index)-stale",
                                    unavailableIdentifier:
                                        "summary-decision-\(section.sourceOrdinal)-\(index)-unavailable")
                                decisionConfirmation(
                                    evidence,
                                    bullet: bullet,
                                    resolution: resolution,
                                    identifier:
                                        "summary-decision-\(section.sourceOrdinal)-\(index)")
                            }
                        }
                    }
                }
            }
            .onAppear { actions.decisionsDidAppear() }
        }
    }

    /// The gesture entry, or the durable state it produced. Confirmation only
    /// offers itself over current evidence — stale or purged evidence keeps
    /// the existing honest badges and nothing else.
    @ViewBuilder
    private func decisionConfirmation(
        _ evidence: SummaryDecisionEvidence,
        bullet: String,
        resolution: TranscriptEvidenceResolution,
        identifier: String
    ) -> some View {
        if let confirmed = values.decisionConfirmations[evidence.id] {
            let badge = confirmed.topicLabels.isEmpty
                ? L10n.text("Confirmed")
                : L10n.format(
                    "Confirmed · %@",
                    confirmed.topicLabels.joined(separator: ", "))
            Label(badge, systemImage: "checkmark.seal.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
                // One element with an explicit label: the badge announces its
                // full state, and the identifier's element carries the topic
                // instead of an empty container wrapping unreachable children.
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(badge)
                .accessibilityIdentifier("\(identifier)-confirmed")
        } else if resolution.status == .current {
            Button {
                actions.confirmDecision(evidence, bullet)
            } label: {
                Text("Confirm…")
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(.tint)
            .accessibilityIdentifier("\(identifier)-confirm")
        }
    }

    @ViewBuilder
    private var overviewEvidence: some View {
        if let claim = values.summary.draft.claims.first(where: { $0.kind == .overview }) {
            let resolution = currentResolution(claim.resolveEvidence(
                currentTranscriptRevision: values.transcriptRevision,
                segments: values.segments))
            VStack(alignment: .leading, spacing: 8) {
                evidenceSources(
                    resolution,
                    sourceIdentifier: "summary-evidence",
                    staleIdentifier: "summary-evidence-stale",
                    unavailableIdentifier: "summary-evidence-unavailable")
                SummaryClaimFeedbackView(claim: claim) { feedback in
                    await actions.setClaimFeedback(claim.id, feedback)
                }
            }
        }
    }

    @ViewBuilder
    private func evidenceSources(
        _ resolution: SummaryClaimEvidenceResolution,
        sourceIdentifier: String,
        staleIdentifier: String,
        unavailableIdentifier: String
    ) -> some View {
        MeetingEvidenceSources(
            resolution: resolution,
            sourceIdentifier: sourceIdentifier,
            staleIdentifier: staleIdentifier,
            unavailableIdentifier: unavailableIdentifier,
            clock: { values.presentation.clock($0) },
            focus: actions.focusEvidence)
    }

    private func currentResolution(
        _ resolution: TranscriptEvidenceResolution
    ) -> TranscriptEvidenceResolution {
        values.freshness == .current
            ? resolution
            : TranscriptEvidenceResolution(status: .stale)
    }

    private var summaryBadge: some View {
        let badge = summaryBadgeText
        return Text(badge)
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityLabel(badge)
            .accessibilityValue(badge)
            .accessibilityIdentifier("summary-badge")
    }

    private var summaryBadgeText: String {
        var badge = "v\(values.summary.version) · \(values.summary.draft.language)"
        if values.summary.draft.recipeID != Recipe.general.id,
           let recipe = values.recipes.first(where: {
               $0.id == values.summary.draft.recipeID
           }) {
            badge += " · \(recipe.displayName)"
        }
        return badge
    }
}

/// One shared, content-free proof surface for generated claims and Apuntador.
/// The caller supplies formatting and navigation; this view cannot seek,
/// mutate a meeting, or inspect application state on its own.
struct MeetingEvidenceSources: View {
    let resolution: TranscriptEvidenceResolution
    let sourceIdentifier: String
    let staleIdentifier: String
    let unavailableIdentifier: String
    let clock: @MainActor (TimeInterval) -> String
    let focus: @MainActor (TranscriptSegment) -> Void

    @ViewBuilder
    var body: some View {
        switch resolution.status {
        case .current:
            HStack(spacing: 6) {
                Label("Sources", systemImage: "quote.bubble")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(Array(resolution.segments.enumerated()), id: \.element.id) { index, segment in
                    Button(clock(segment.startTime)) {
                        focus(segment)
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
}
