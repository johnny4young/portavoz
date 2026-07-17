import PortavozCore
import SwiftUI

/// Explicit, local review controls for one generated claim. Feedback is
/// visible and reversible; it never changes the generated summary in place.
struct SummaryClaimFeedbackView: View {
    let claim: SummaryClaim
    let save: (SummaryClaimFeedback?) async -> Bool

    @State private var showingCorrection = false
    @State private var saving = false

    private var isUnsupported: Bool {
        claim.feedback?.kind == .unsupported
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Label("Review", systemImage: "checkmark.bubble")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Button(L10n.text(
                    claim.feedback?.kind == .correction
                        ? "Edit correction…"
                        : "Add correction…")) {
                    showingCorrection = true
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .accessibilityIdentifier("summary-feedback-correction")
                Button(L10n.text(isUnsupported ? "Unsupported" : "Mark unsupported")) {
                    persist(.unsupported)
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .tint(isUnsupported ? .orange : nil)
                .accessibilityAddTraits(isUnsupported ? .isSelected : [])
                .accessibilityIdentifier("summary-feedback-unsupported")
                if claim.feedback != nil {
                    Button("Clear") { persist(nil) }
                        .buttonStyle(.borderless)
                        .controlSize(.mini)
                        .accessibilityIdentifier("summary-feedback-clear")
                }
                if saving { ProgressView().controlSize(.mini) }
            }
            feedbackStatus
            Text("Stays on this Mac. Included only when you export a .portavoz file.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .disabled(saving)
        .sheet(isPresented: $showingCorrection) {
            SummaryCorrectionSheet(
                initialText: claim.feedback?.correctionText ?? "",
                save: save)
        }
    }

    @ViewBuilder
    private var feedbackStatus: some View {
        switch claim.feedback?.kind {
        case .correction:
            VStack(alignment: .leading, spacing: 3) {
                Label("Your correction", systemImage: "text.bubble")
                    .font(.caption.weight(.semibold))
                    .accessibilityIdentifier("summary-feedback-status")
                Text(claim.feedback?.correctionText ?? "")
                    .font(.caption)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("summary-feedback-correction-value")
            }
        case .unsupported:
            Label("Marked as unsupported", systemImage: "exclamationmark.bubble")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)
                .accessibilityIdentifier("summary-feedback-status")
        case nil:
            EmptyView()
        }
    }

    private func persist(_ feedback: SummaryClaimFeedback?) {
        guard !saving else { return }
        saving = true
        Task {
            _ = await save(feedback)
            saving = false
        }
    }
}

private struct SummaryCorrectionSheet: View {
    @Environment(\.dismiss) private var dismiss
    let save: (SummaryClaimFeedback?) async -> Bool

    @State private var text: String
    @State private var saving = false
    @State private var errorMessage: String?

    init(
        initialText: String,
        save: @escaping (SummaryClaimFeedback?) async -> Bool
    ) {
        self.save = save
        _text = State(initialValue: initialText)
    }

    private var feedback: SummaryClaimFeedback? {
        SummaryClaimFeedback.correction(text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Correct the summary")
                .font(.title2.weight(.semibold))
            Text(L10n.text(
                "Your correction stays separate, on this Mac, and only in explicit .portavoz exports."))
                .foregroundStyle(.secondary)
            TextEditor(text: $text)
                .font(.body)
                .frame(minHeight: 120)
                .padding(6)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
                .accessibilityIdentifier("summary-feedback-correction-text")
                .onChange(of: text) { _, value in
                    let limit = SummaryClaimFeedback.maximumCorrectionLength
                    if value.unicodeScalars.count > limit {
                        text = String(value.unicodeScalars.prefix(limit))
                    }
                }
            HStack {
                Text(
                    "\(text.unicodeScalars.count)/"
                        + "\(SummaryClaimFeedback.maximumCorrectionLength)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                if let errorMessage {
                    Text(errorMessage).font(.caption).foregroundStyle(.red)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save correction") { persist() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(feedback == nil || saving)
                    .accessibilityIdentifier("summary-feedback-save")
            }
        }
        .padding(22)
        .frame(width: 520)
    }

    private func persist() {
        guard let feedback, !saving else { return }
        saving = true
        errorMessage = nil
        Task {
            if await save(feedback) {
                dismiss()
            } else {
                errorMessage = L10n.text("Could not save this correction. Try again.")
                saving = false
            }
        }
    }
}
