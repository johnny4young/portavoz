import ApplicationKit
import PortavozCore
import SwiftUI

struct MeetingCommitmentInboxValues {
    let candidates: [CommitmentInboxCandidate]
    let ownerChoices: [CommitmentOwnerSuggestion]
    let presentation: MeetingDetailPresentation
}

struct MeetingCommitmentInboxActions {
    let focusEvidence: @MainActor (TranscriptSegment) -> Void
    let confirm:
        @MainActor (CommitmentInboxCandidate, String, CommitmentAssignee, Date?) async -> Bool
    let dismiss: @MainActor (CommitmentInboxCandidate) async -> Bool
    let deferUntil: @MainActor (CommitmentInboxCandidate, Date) async -> Bool

    /// Puts the candidate back in review this many days from now.
    @MainActor
    func deferCandidate(_ candidate: CommitmentInboxCandidate, days: Int) async -> Bool {
        guard let revisitAt = Calendar.autoupdatingCurrent.date(byAdding: .day, value: days, to: Date())
        else { return false }
        return await deferUntil(candidate, revisitAt)
    }
}

/// Evidence-first admission surface for generated action items. The section
/// owns only transient editor and progress state; every mutation remains an
/// explicit route action.
struct MeetingCommitmentInboxSection: View {
    let values: MeetingCommitmentInboxValues
    let actions: MeetingCommitmentInboxActions

    @State private var editingCandidate: CommitmentInboxCandidate?
    @State private var processingID: UUID?

    private var pendingCandidates: [CommitmentInboxCandidate] {
        values.candidates.filter {
            if case .pending = $0.status { return true }
            return false
        }
    }

    @ViewBuilder
    var body: some View {
        if !pendingCandidates.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                sectionHeader
                ForEach(pendingCandidates) { candidate in
                    candidateCard(candidate)
                }
            }
            .padding(14)
            .background(PVDesign.ink.opacity(PVDesign.offerTint), in: RoundedRectangle(cornerRadius: 10))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("detail-commitment-inbox")
            .sheet(item: $editingCandidate) { candidate in
                MeetingCommitmentConfirmationSheet(
                    candidate: candidate,
                    ownerChoices: values.ownerChoices,
                    cancel: { editingCandidate = nil },
                    confirm: { title, assignee, dueAt in
                        await actions.confirm(candidate, title, assignee, dueAt)
                    })
            }
        }
    }

    private var sectionHeader: some View {
        Label("Commitments to confirm", systemImage: PVSymbol.success)
            .font(.headline)
            .accessibilityIdentifier("detail-commitment-inbox-title")
    }

    private func candidateCard(_ candidate: CommitmentInboxCandidate) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            PVCardCaption(
                text: caption(candidate),
                systemImage: PVSymbol.commitment,
                tint: PVDesign.ink3)
                .accessibilityIdentifier("commitment-\(candidate.id.uuidString)-caption")
            Text(candidate.actionItem.text)
                .font(.body.weight(.semibold))
                .textSelection(.enabled)
            suggestionSummary(candidate)
            MeetingEvidenceSources(
                resolution: candidate.evidence,
                sourceIdentifier: "commitment-\(candidate.id.uuidString)-evidence",
                staleIdentifier: "commitment-\(candidate.id.uuidString)-stale",
                unavailableIdentifier: "commitment-\(candidate.id.uuidString)-unavailable",
                clock: { values.presentation.clock($0) },
                focus: actions.focusEvidence)
            actionRow(candidate)
        }
        .pvCard(.outlined)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("commitment-candidate-\(candidate.id.uuidString)")
    }

    private func caption(_ candidate: CommitmentInboxCandidate) -> String {
        guard let dueAt = candidate.suggestedDueAt else { return L10n.text("Commitment") }
        return L10n.format("Commitment · suggested due %@", values.presentation.shortDate(dueAt))
    }

    private func suggestionSummary(_ candidate: CommitmentInboxCandidate) -> some View {
        HStack(spacing: 12) {
            if let owner = candidate.suggestedOwner {
                Label(
                    L10n.format("Suggested owner: %@", owner.displayName),
                    systemImage: "person.crop.circle.badge.checkmark")
                    .accessibilityIdentifier(
                        "commitment-\(candidate.id.uuidString)-owner-suggestion")
            } else {
                Label("No owner suggested", systemImage: "person.crop.circle.badge.questionmark")
            }
            if candidate.suggestedDueAt == nil {
                Label("No deadline suggested", systemImage: "calendar.badge.questionmark")
            }
        }
        .font(.caption)
        .foregroundStyle(.ink3)
    }

    private func actionRow(_ candidate: CommitmentInboxCandidate) -> some View {
        HStack(spacing: 8) {
            Button("Dismiss", role: .destructive) {
                perform(candidate) { await actions.dismiss(candidate) }
            }
            .controlSize(.small)
            .accessibilityIdentifier("commitment-\(candidate.id.uuidString)-dismiss")

            Menu("Review later") {
                Button("Tomorrow") {
                    deferCandidate(candidate, days: 1)
                }
                .accessibilityIdentifier("commitment-\(candidate.id.uuidString)-defer-tomorrow")
                Button("Next week") {
                    deferCandidate(candidate, days: 7)
                }
                .accessibilityIdentifier("commitment-\(candidate.id.uuidString)-defer-week")
            }
            .controlSize(.small)
            .accessibilityIdentifier("commitment-\(candidate.id.uuidString)-defer")

            Spacer()

            Button("Review and confirm…") {
                editingCandidate = candidate
            }
            .buttonStyle(.pvPrimary)
            .controlSize(.small)
            .disabled(!hasCurrentEvidence(candidate) || processingID != nil)
            .help(confirmHelp(candidate))
            .accessibilityIdentifier("commitment-\(candidate.id.uuidString)-review")
        }
        .disabled(processingID == candidate.id)
    }

    private func deferCandidate(_ candidate: CommitmentInboxCandidate, days: Int) {
        perform(candidate) { await actions.deferCandidate(candidate, days: days) }
    }

    private func perform(
        _ candidate: CommitmentInboxCandidate,
        operation: @escaping @MainActor () async -> Bool
    ) {
        processingID = candidate.id
        Task {
            _ = await operation()
            processingID = nil
        }
    }

    private func hasCurrentEvidence(_ candidate: CommitmentInboxCandidate) -> Bool {
        candidate.evidence.status == .current && !candidate.evidence.segments.isEmpty
    }

    private func confirmHelp(_ candidate: CommitmentInboxCandidate) -> String {
        hasCurrentEvidence(candidate)
            ? L10n.text("Review the wording, owner, deadline, and source before confirming.")
            : L10n.text("Regenerate the summary before confirming this stale source.")
    }
}

struct MeetingCommitmentConfirmationSheet: View {
    let ownerChoices: [CommitmentOwnerSuggestion]
    let isBlocked: Bool
    let cancel: @MainActor () -> Void
    let confirm: @MainActor (String, CommitmentAssignee, Date?) async -> Bool

    @State private var title: String
    @State private var assignee: CommitmentAssignee
    @State private var includesDueDate: Bool
    @State private var dueAt: Date
    @State private var isSaving = false

    init(
        candidate: CommitmentInboxCandidate,
        ownerChoices: [CommitmentOwnerSuggestion],
        cancel: @escaping @MainActor () -> Void,
        confirm: @escaping @MainActor (String, CommitmentAssignee, Date?) async -> Bool
    ) {
        self.init(
            text: candidate.actionItem.text,
            suggestedOwner: candidate.suggestedOwner,
            suggestedDueAt: candidate.suggestedDueAt,
            ownerChoices: ownerChoices,
            cancel: cancel,
            confirm: confirm)
    }

    init(
        text: String,
        suggestedOwner: CommitmentOwnerSuggestion?,
        suggestedDueAt: Date? = nil,
        ownerChoices: [CommitmentOwnerSuggestion],
        isBlocked: Bool = false,
        cancel: @escaping @MainActor () -> Void,
        confirm: @escaping @MainActor (String, CommitmentAssignee, Date?) async -> Bool
    ) {
        self.ownerChoices = ownerChoices
        self.isBlocked = isBlocked
        self.cancel = cancel
        self.confirm = confirm
        _title = State(initialValue: text)
        _assignee = State(initialValue: suggestedOwner.map {
            CommitmentAssignee.person($0.personID)
        } ?? .unassigned)
        _includesDueDate = State(initialValue: suggestedDueAt != nil)
        _dueAt = State(initialValue: suggestedDueAt
            ?? Date().addingTimeInterval(24 * 60 * 60))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Confirm commitment")
                .font(.title3.weight(.semibold))
            Text("Edit the proposed wording and add only the owner and deadline you know are true.")
                .font(.callout)
                .foregroundStyle(.ink3)

            TextField("Commitment", text: $title)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("commitment-editor-title")

            Picker("Owner", selection: $assignee) {
                Text("Me")
                    .tag(CommitmentAssignee.me)
                    .accessibilityIdentifier("commitment-owner-me")
                Text("Unassigned")
                    .tag(CommitmentAssignee.unassigned)
                    .accessibilityIdentifier("commitment-owner-unassigned")
                ForEach(ownerChoices, id: \.personID) { owner in
                    Text(owner.displayName)
                        .tag(CommitmentAssignee.person(owner.personID))
                        .accessibilityIdentifier(
                            "commitment-owner-person-\(owner.personID.rawValue.uuidString)")
                }
            }
            .accessibilityIdentifier("commitment-editor-owner")

            Toggle("Add due date", isOn: $includesDueDate)
                .accessibilityIdentifier("commitment-editor-due-toggle")
            if includesDueDate {
                DatePicker(
                    "Due date",
                    selection: $dueAt,
                    displayedComponents: [.date])
                    .accessibilityIdentifier("commitment-editor-due-date")
            }

            HStack {
                Spacer()
                Button("Cancel") { cancel() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("commitment-editor-cancel")
                Button("Confirm") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.pvPrimary)
                    .disabled(isSaving || isBlocked || normalizedTitle.isEmpty)
                    .accessibilityIdentifier("commitment-editor-confirm")
            }
        }
        .padding(20)
        .frame(width: 460)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("commitment-editor")
    }

    private var normalizedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func save() {
        isSaving = true
        Task {
            let saved = await confirm(
                normalizedTitle,
                assignee,
                includesDueDate ? dueAt : nil)
            if saved {
                cancel()
            } else {
                isSaving = false
            }
        }
    }
}
