import PortavozCore
import SwiftUI

/// The summary margin's review menu for one generated claim. Feedback is
/// explicit and reversible; it never changes the generated summary in place.
struct SummaryClaimFeedbackMenu: View {
    let claim: SummaryClaim
    /// Shared with the status's Clear, so only one save runs at a time.
    @Binding var saving: Bool
    let save: (SummaryClaimFeedback?) async -> Bool
    let editCorrection: () -> Void

    var body: some View {
        Menu {
            Button(L10n.text(
                claim.feedback?.kind == .correction ? "Edit correction…" : "Add correction…"),
                action: editCorrection)
            .accessibilityIdentifier("summary-feedback-correction")
            Toggle(L10n.text("Mark unsupported"), isOn: Binding(
                get: { claim.feedback?.kind == .unsupported },
                set: { persist($0 ? .unsupported : nil) }))
                .accessibilityIdentifier("summary-feedback-unsupported")
            if claim.feedback != nil {
                Divider()
                Button("Clear") { persist(nil) }
                    .accessibilityIdentifier("summary-feedback-clear-menu")
            }
        } label: {
            Image(systemName: "checkmark.bubble")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(saving)
        .help(Self.privacyNote)
        .accessibilityLabel(L10n.text("Review"))
        .accessibilityIdentifier("summary-feedback-menu")
    }

    static var privacyNote: String {
        L10n.text("Stays on this Mac. Included only when you export a .portavoz file.")
    }

    private func persist(_ feedback: SummaryClaimFeedback?) {
        Self.persist(feedback, saving: $saving, save: save)
    }

    @MainActor
    static func persist(
        _ feedback: SummaryClaimFeedback?,
        saving: Binding<Bool>,
        save: @escaping (SummaryClaimFeedback?) async -> Bool
    ) {
        guard !saving.wrappedValue else { return }
        saving.wrappedValue = true
        Task {
            _ = await save(feedback)
            saving.wrappedValue = false
        }
    }
}

/// The user's assessment under the standfirst, shown only once one is set.
struct SummaryClaimFeedbackStatus: View {
    let claim: SummaryClaim
    @Binding var saving: Bool
    let save: (SummaryClaimFeedback?) async -> Bool

    var body: some View {
        if let kind = claim.feedback?.kind {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                status(kind)
                Button("Clear") {
                    SummaryClaimFeedbackMenu.persist(nil, saving: $saving, save: save)
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .fixedSize()
                .disabled(saving)
                .help(SummaryClaimFeedbackMenu.privacyNote)
                .accessibilityIdentifier("summary-feedback-clear")
            }
        }
    }

    @ViewBuilder
    private func status(_ kind: SummaryClaimFeedbackKind) -> some View {
        switch kind {
        case .correction:
            VStack(alignment: .leading, spacing: 3) {
                Label("Your correction", systemImage: PVSymbol.correction)
                    .font(.caption.weight(.semibold))
                    .accessibilityIdentifier("summary-feedback-status")
                Text(claim.feedback?.correctionText ?? "")
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("summary-feedback-correction-value")
            }
        case .unsupported:
            Label("Marked as unsupported", systemImage: "exclamationmark.bubble")
                .font(.caption.weight(.semibold))
                .foregroundStyle(PVDesign.caution)
                .accessibilityIdentifier("summary-feedback-status")
        }
    }
}

struct SummaryCorrectionSheet: View {
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
                    Text(errorMessage).font(.caption).cautionText()
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
