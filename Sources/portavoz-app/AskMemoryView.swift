import ApplicationKit
import PortavozCore
import SwiftUI

/// Explicit confirmed-memory query UI. The user chooses one canonical person;
/// no free-form question, model, or alias guess can create graph authority.
struct AskMemoryView: View {
    let model: AskMemoryModel
    let onOpenCitation: (AskCitation) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                header
                personSearch
                if let selected = model.state.selectedPerson {
                    selectedPerson(selected)
                    outcome
                } else {
                    peopleResults
                }
            }
            .padding(18)
            .frame(maxWidth: 720, alignment: .leading)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Current commitments", systemImage: "person.text.rectangle")
                .font(.title2.bold())
                .accessibilityIdentifier("ask-memory-title")
            // One localized explanatory sentence is clearer as one catalog key.
            Text(
                // swiftlint:disable:next line_length
                "Choose one confirmed person. Portavoz uses the exact identity you select and never guesses from question text.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var personSearch: some View {
        TextField(
            "Find a confirmed person…",
            text: Binding(
                get: { model.state.personQuery },
                set: { model.updatePersonQuery($0) }))
            .textFieldStyle(.roundedBorder)
            .disabled(model.state.selectedPerson != nil)
            .accessibilityIdentifier("ask-memory-person-search")
    }

    @ViewBuilder
    private var peopleResults: some View {
        switch model.state.peoplePhase {
        case .idle:
            EmptyView()
        case .loading:
            statusRow(
                "Searching confirmed people…",
                systemImage: nil,
                showsProgress: true)
        case .empty:
            statusRow(
                "No confirmed people match this search.",
                systemImage: "person.crop.circle.badge.questionmark")
        case .unavailable:
            VStack(alignment: .leading, spacing: 8) {
                statusRow(
                    "Could not search confirmed people.",
                    systemImage: "exclamationmark.triangle")
                Button("Try again") { model.retryPeopleSearch() }
                    .accessibilityIdentifier("ask-memory-person-retry")
            }
        case .ready:
            VStack(alignment: .leading, spacing: 8) {
                ForEach(model.state.people) { person in
                    Button {
                        model.selectPerson(person.id)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "person.crop.circle")
                            Text(person.name)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, 5)
                    .accessibilityIdentifier(
                        "ask-memory-person-\(person.id.rawValue.uuidString)")
                }
                if model.state.peopleHasMore {
                    Label(
                        "More people match. Refine the name to choose the right one.",
                        systemImage: "magnifyingglass")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("ask-memory-person-overflow")
                }
            }
        }
    }

    private func selectedPerson(_ person: AskMemoryPerson) -> some View {
        HStack(spacing: 10) {
            Label(person.name, systemImage: "person.crop.circle.fill")
                .font(.headline)
                .accessibilityIdentifier("ask-memory-selected-person")
            Spacer()
            Button("Change") { model.clearPersonSelection() }
                .accessibilityIdentifier("ask-memory-change-person")
            Button("Show current commitments") {
                model.loadSelectedPersonCommitments()
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.state.outcome == .loading)
            .accessibilityIdentifier("ask-memory-load")
        }
        .padding(12)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private var outcome: some View {
        switch model.state.outcome {
        case .idle:
            EmptyView()
        case .loading:
            statusRow(
                "Loading confirmed commitments…",
                systemImage: nil,
                showsProgress: true)
        case .facts(let commitments, let disclosure):
            VStack(alignment: .leading, spacing: 12) {
                ForEach(commitments) { commitment in
                    commitmentCard(commitment)
                }
                disclosureView(disclosure)
            }
        case .abstained(let reason):
            memoryFailure(
                message: abstentionMessage(reason),
                identifier: "ask-memory-abstained")
        case .invalidEvidence:
            memoryFailure(
                message: "Portavoz could not verify the returned evidence.",
                identifier: "ask-memory-invalid-evidence")
        case .unavailable:
            memoryFailure(
                message: "Could not load confirmed memory.",
                identifier: "ask-memory-unavailable")
        }
    }

    private func commitmentCard(_ commitment: AskMemoryCommitment) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(commitment.title, systemImage: "checkmark.circle.fill")
                .font(.headline)
                .accessibilityIdentifier(
                    "ask-memory-commitment-\(commitment.id.rawValue.uuidString)")
            Text(L10n.format("Confirmed for %@", commitment.personName))
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(commitment.occurredAt.formatted(date: .abbreviated, time: .shortened))
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Divider()
            Text("Evidence")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(Array(orderedCitations(commitment).enumerated()), id: \.offset) { index, citation in
                Button {
                    onOpenCitation(citation)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.turn.down.right")
                        Text(
                            "\(citation.meetingTitle) · \(AskMarkdown.clock(citation.timestamp))")
                            .lineLimit(1)
                    }
                    .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(PVDesign.accent)
                .help(citation.text)
                .accessibilityIdentifier(
                    "ask-memory-evidence-\(commitment.id.rawValue.uuidString)-\(index)")
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private func disclosureView(_ disclosure: AskMemoryDisclosure) -> some View {
        if disclosure.hasMore {
            Label(
                "More than 100 current commitments exist; this view shows the newest verified results.",
                systemImage: "ellipsis.circle")
                .accessibilityIdentifier("ask-memory-more-commitments")
        }
        if disclosure.omittedStaleCount > 0 {
            Label(
                "Some commitments with outdated evidence were omitted.",
                systemImage: "clock")
                .accessibilityIdentifier("ask-memory-omitted-stale")
        }
        if disclosure.omittedUnavailableCount > 0 {
            Label(
                "Some commitments without available evidence were omitted.",
                systemImage: "exclamationmark.shield")
                .accessibilityIdentifier("ask-memory-omitted-unavailable")
        }
    }

    private func memoryFailure(message: String, identifier: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            statusRow(
                message,
                systemImage: "exclamationmark.triangle",
                identifier: identifier)
            Button("Try again") { model.loadSelectedPersonCommitments() }
                .accessibilityIdentifier("ask-memory-load-retry")
        }
    }

    private func statusRow(
        _ message: String,
        systemImage: String?,
        showsProgress: Bool = false,
        identifier: String = "ask-memory-status"
    ) -> some View {
        HStack(spacing: 8) {
            if showsProgress {
                ProgressView().controlSize(.small)
            } else if let systemImage {
                Image(systemName: systemImage)
            }
            Text(L10n.text(message))
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(identifier)
    }

    private func orderedCitations(
        _ commitment: AskMemoryCommitment
    ) -> [AskCitation] {
        [commitment.primaryCitation] + commitment.citations.filter {
            $0.segmentID != commitment.primaryCitation.segmentID
        }
    }

    private func abstentionMessage(
        _ reason: MeetingMemoryGraphQueryAbstention
    ) -> String {
        switch reason {
        case .noActiveCommitments, .noMatchingFacts:
            "No current confirmed commitments for this person."
        case .projectionNotReady:
            "Confirmed memory is still preparing. Try again shortly."
        case .personUnavailable:
            "This confirmed person is no longer available."
        case .staleEvidenceOnly, .evidenceUnavailable:
            "The matching commitments need current transcript evidence before Portavoz can show them."
        case .projectionInconsistent:
            "Confirmed memory could not verify a complete projection yet."
        case .candidateBudgetExceeded:
            "The result is too large to verify safely."
        case .invalidQuery, .ambiguousPerson, .ambiguousTopic,
             .commitmentUnavailable, .topicUnavailable,
             .unsupportedCausalLink, .unsupportedConflict,
             .missingTemporalBaseline, .insufficientConfirmedDecision:
            "The memory request was not specific enough to answer safely."
        }
    }
}
