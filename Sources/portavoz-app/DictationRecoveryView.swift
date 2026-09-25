import SwiftUI
import PortavozCore

/// Presentation only: the controller retains the complete output and owns
/// every effect. The visible excerpt is never the source of a copied paste.
struct DictationRecoveryView: View {
    let controller: DictationController
    let failure: DictationDeliveryOutcome.Refusal

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Text wasn't sent", systemImage: "exclamationmark.bubble")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("dictation-recovery-title")
            Text(message)
                .lineLimit(3)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("dictation-recovery-reason")
            Text(controller.recoveryText)
                .font(.body)
                .lineLimit(4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("dictation-recovery-text")
            Text(copyMessage)
                .lineLimit(2)
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("dictation-recovery-copy-status")
            HStack(spacing: 8) {
                Button("Copy", action: controller.copyUndeliveredText)
                    .accessibilityIdentifier("dictation-recovery-copy")
                    .disabled(controller.isRetryingDelivery)
                Button("Reinsert", action: controller.retryUndeliveredText)
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("dictation-recovery-reinsert")
                    .disabled(!controller.canRetryDelivery || controller.isRetryingDelivery)
                Spacer()
                // This abandons the pending operation, like discarding a Refine
                // draft; it does not delete an already saved library item.
                Button("Discard", role: .cancel, action: controller.cancel)
                    .accessibilityIdentifier("dictation-recovery-discard")
            }
            .controlSize(.large)
            .frame(minHeight: 44)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    private var message: String {
        switch failure {
        case .targetChanged:
            if let name = controller.targetApp {
                return L10n.format("Return to %@ and the original field to reinsert, or copy your text.", name)
            }
            return L10n.text("The destination changed. Copy your text to keep it.")
        case .secureField:
            return L10n.text("Dictation never types into password fields.")
        case .modifiersStillPressed:
            return L10n.text("Release Command, Option, Control, and Shift, then try again.")
        case .focusUnavailable:
            return L10n.text("The original field can't be verified. Your text is still available to copy.")
        case .clipboardUnavailable, .eventUnavailable, .cancelled, .emptyText:
            return L10n.text("Delivery didn't complete. Reinsert into the original field, or copy your text.")
        }
    }

    private var copyMessage: String {
        switch controller.copyStatus {
        case .idle: L10n.text("Kept only in memory. Copy it before quitting Portavoz.")
        case .copied: L10n.text("Copied. You can paste the text yourself.")
        case .failed: L10n.text("Couldn't copy. Your text is still here.")
        }
    }
}
