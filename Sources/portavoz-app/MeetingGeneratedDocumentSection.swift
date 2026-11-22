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
    let regenerateDetail: @MainActor (SummaryDetail) -> Void
    let createStructure: @MainActor () -> Void
    let dismissRecipeSuggestion: @MainActor () -> Void
    let dismissThinSuggestion: @MainActor () -> Void
    let setActionItem: @MainActor (ActionItem, Bool) -> Void
    let createGitHubIssue: @MainActor (ActionItem) -> Void
    let focusEvidence: @MainActor (TranscriptSegment) -> Void
    let setClaimFeedback:
        @MainActor (SummaryClaimID, SummaryClaimFeedback?) async -> Bool
    let confirmDecision:
        @MainActor (SummaryDecisionEvidence, _ statement: String) -> Void
    let retractDecisionTopic:
        @MainActor (DecisionObservationConfirmationState.TopicLink) -> Void
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
    @State private var savingClaimFeedback = false
    /// Owned here, not by the gutter menu, so a layout switch never dismisses the sheet.
    @State private var showingCorrection = false
    @State private var isNarrow = false

    private var document: MeetingGeneratedDocumentPresentation {
        MeetingGeneratedDocumentPresentation(
            markdown: values.summary.draft.markdown,
            hasTypedCommitments: !values.summary.draft.actionItems.isEmpty)
    }

    /// The board's left margin: the kicker and counts sit beside the lede,
    /// or above it once the column is too narrow for that margin.
    private static let gutterWidth: CGFloat = 118

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            staleSummaryNotice
            let layout = isNarrow
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
                : AnyLayout(HStackLayout(alignment: .top, spacing: 22))
            layout {
                if isNarrow {
                    gutterRow
                } else {
                    gutter
                        .frame(width: Self.gutterWidth, alignment: .trailing)
                }
                VStack(alignment: .leading, spacing: 12) {
                    documentContent
                    suggestionRow
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
                .padding(.top, 6)
        }
        .onGeometryChange(for: Bool.self) { proxy in
            MeetingDetailPageMetrics.usesInlineGutter(width: proxy.size.width)
        } action: { isNarrow = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("detail-generated-document")
        .onChange(of: values.summary.version) { _, _ in
            tabSelection = 0
        }
        .sheet(isPresented: $showingCorrection) {
            if let claim = overviewClaim {
                SummaryCorrectionSheet(
                    initialText: claim.feedback?.correctionText ?? "",
                    save: saveFeedback(claim))
            }
        }
    }

    @ViewBuilder
    private var staleSummaryNotice: some View {
        if values.freshness == .stale {
            HStack(spacing: 8) {
                Label(
                    "Transcript changed — regenerate this summary to use your corrections.",
                    systemImage: PVSymbol.history)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(PVDesign.caution)
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

    @ViewBuilder
    private var recipeSuggestion: some View {
        if let suggested = values.suggestedRecipe {
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
                "Looks like a \(suggested.localizedDisplayName). Restructure the summary with one click.")
        }
    }

    @ViewBuilder
    private var thinSummarySuggestion: some View {
        if values.showThinSuggestion {
            DismissibleSuggestionChip(
                kind: .ai,
                text: L10n.text("Summary looks thin — make it detailed?"),
                acceptAccessibilityIdentifier: "detail-thin-summary-suggestion",
                dismissAccessibilityIdentifier: "detail-thin-summary-suggestion-dismiss",
                accept: {
                    actions.dismissThinSuggestion()
                    actions.regenerateDetail(.detailed)
                },
                dismiss: actions.dismissThinSuggestion)
            .help(
                // One-line UI help text.
                // swiftlint:disable:next line_length
                "This meeting is long but its summary came out very small. Regenerate a detailed summary — nothing changes unless you click.")
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
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(L10n.text("Copy summary"))
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
                detailMenu
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
                Image(systemName: PVSymbol.retry)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel(L10n.text("Regenerate"))
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

    private var detailMenu: some View {
        Menu("Detail") {
            ForEach(SummaryDetail.allCases, id: \.self) { level in
                Button(level.title) { actions.regenerateDetail(level) }
                    .accessibilityIdentifier("detail-summary-detail-\(level.rawValue)")
            }
        }
        .accessibilityIdentifier("detail-summary-detail-menu")
    }

    private var documentSegments: [PVSegment<Int>] {
        let done = values.summary.draft.actionItems.filter(\.isDone).count
        let total = values.summary.draft.actionItems.count
        var segments = [
            PVSegment(value: 0, title: L10n.text("Summary"), accessibilityIdentifier: "summary-tab-0")
        ]
        for (index, section) in document.sections.enumerated() {
            segments.append(PVSegment(
                value: index + 1,
                title: "\(section.heading) · \(section.bulletCount)",
                accessibilityIdentifier: "summary-tab-\(index + 1)"))
        }
        if total > 0 {
            segments.append(PVSegment(
                value: 1000,
                title: L10n.format("To-dos · %d/%d", done, total),
                accessibilityIdentifier: "summary-tab-todos"))
        }
        return segments
    }

    private var showsOverview: Bool {
        tabSelection != 1000 && !(tabSelection >= 1 && tabSelection - 1 < document.sections.count)
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
                    .pvDisplay(.standfirst)
                    .lineSpacing(4)
                    .accessibilityIdentifier("detail-standfirst")
                overviewEvidence
            }
        }
    }

    private var actionItems: some View {
        MeetingActionItemsView(values: values, actions: actions)
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
            let badgeLabel = Label(badge, systemImage: PVSymbol.success)
                .font(.caption)
                .foregroundStyle(.secondary)
            if confirmed.topicLinks.isEmpty {
                badgeLabel
                    // One element with an explicit label: the badge announces
                    // its full state, and the identifier's element carries the
                    // topic instead of an empty container wrapping unreachable
                    // children.
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(badge)
                    .accessibilityIdentifier("\(identifier)-confirmed")
            } else {
                // The badge doubles as the retraction entry: each active link
                // offers its withdrawal. The decision stays confirmed — only
                // what it is about is taken back (history keeps the event).
                Menu {
                    ForEach(confirmed.topicLinks) { link in
                        Button(L10n.format("Remove topic “%@”", link.label)) {
                            actions.retractDecisionTopic(link)
                        }
                        .accessibilityIdentifier(
                            "\(identifier)-retract-\(link.id.rawValue.uuidString)")
                    }
                } label: {
                    badgeLabel
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel(badge)
                .accessibilityIdentifier("\(identifier)-confirmed")
            }
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
        if let claim = overviewClaim {
            let resolution = currentResolution(claim.resolveEvidence(
                currentTranscriptRevision: values.transcriptRevision,
                segments: values.segments))
            VStack(alignment: .leading, spacing: 8) {
                evidenceSources(
                    resolution,
                    sourceIdentifier: "summary-evidence",
                    staleIdentifier: "summary-evidence-stale",
                    unavailableIdentifier: "summary-evidence-unavailable")
                SummaryClaimFeedbackStatus(
                    claim: claim, saving: $savingClaimFeedback, save: saveFeedback(claim))
            }
        }
    }

    private var overviewClaim: SummaryClaim? {
        values.summary.draft.claims.first { $0.kind == .overview }
    }

    @ViewBuilder
    private var claimReviewMenu: some View {
        // Only beside the overview, where its assessment shows.
        if showsOverview, let claim = overviewClaim {
            SummaryClaimFeedbackMenu(
                claim: claim, saving: $savingClaimFeedback, save: saveFeedback(claim),
                editCorrection: { showingCorrection = true })
        }
    }

    private func saveFeedback(_ claim: SummaryClaim) -> (SummaryClaimFeedback?) async -> Bool {
        { feedback in await actions.setClaimFeedback(claim.id, feedback) }
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
            .font(.caption2)
            .foregroundStyle(PVDesign.ink3)
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

private extension MeetingGeneratedDocumentSection {
    /// "✦ Summary" and one count per section stand in for tabs: each selects
    /// what the lede column shows.
    var gutter: some View {
        VStack(alignment: .trailing, spacing: 3) {
            ForEach(documentSegments) { segment in
                gutterButton(segment)
            }
            // Badge and menus share a line when it fits, so the gutter stays near the lede's height.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) { summaryBadge; documentMenus }
                VStack(alignment: .trailing, spacing: 3) { summaryBadge; documentMenus }
            }
            .padding(.top, 4)
        }
        .padding(.top, 5)
    }

    /// The same gutter on one line above the lede, wrapping its counts onto
    /// a second line before anything truncates.
    var gutterRow: some View {
        let counts = ForEach(documentSegments) { segment in
            gutterButton(segment)
        }
        let trailing = HStack(spacing: 8) {
            summaryBadge
            documentMenus
        }
        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                counts
                Spacer(minLength: 8)
                trailing
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 14) { counts }
                trailing
            }
        }
    }

    var documentMenus: some View {
        HStack(spacing: 2) {
            copyMenu
            claimReviewMenu
            regenerateMenu
        }
        .foregroundStyle(PVDesign.ink3)
    }

    func gutterButton(_ segment: PVSegment<Int>) -> some View {
        let selected = segment.value == tabSelection
        return Button {
            tabSelection = segment.value
        } label: {
            if segment.value == 0 {
                PVCardCaption(
                    text: segment.title,
                    systemImage: ChipLabel.generatedSymbol,
                    tint: selected ? PVDesign.green : PVDesign.ink3)
                    .padding(.bottom, 2)
            } else {
                Text(segment.title)
                    .font(.subheadline.weight(selected ? .semibold : .regular))
                    .foregroundStyle(selected ? PVDesign.ink : PVDesign.ink3)
                    .multilineTextAlignment(.trailing)
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(segment.accessibilityIdentifier)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// Suggestions sit in the flow under the lede and wrap rather than truncate.
    @ViewBuilder
    var suggestionRow: some View {
        if !values.regenerating && (values.suggestedRecipe != nil || values.showThinSuggestion) {
            FlowLayout(spacing: 8, rowSpacing: 6) {
                recipeSuggestion
                thinSummarySuggestion
            }
        }
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
                systemImage: PVSymbol.history)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityIdentifier(staleIdentifier)
        case .unavailable:
            Label(
                "Sources are no longer available.",
                systemImage: PVSymbol.warning)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityIdentifier(unavailableIdentifier)
        }
    }
}
